// Package analytics is the user-activity analytics module (plan 29 §4,
// ADR-011): app and server events, validated against the registry, buffered
// in process and flushed into the day-partitioned analytics.events table,
// archived to Cloud Storage and aggregated daily.
//
// It owns the `analytics` schema and nothing else. Other modules reach it
// through the outbox adapters in cmd/monolith; it never reads their tables
// and they never wait on it.
//
// # BEST EFFORT, BY DESIGN
//
// Nothing here can fail or slow a user request, or a billing delivery. The
// ingest returns as soon as events are queued; a full queue drops and
// counts. Server events are recorded with a call that has no error to
// return. Billing correctness never depends on any of it.
//
// # PRIVACY
//
// The only account identifier stored is user_key, an HMAC-SHA256 of the
// user id under ANALYTICS_USER_KEY_SECRET. Attributes are typed and
// allowlisted by the registry; context fields are checked against fixed
// patterns. Nothing from the request that is not one of those is kept, and
// the client's IP address never reaches this module.
package analytics

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"regexp"
	"strings"
	"time"

	"github.com/google/uuid"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	otellog "go.opentelemetry.io/otel/log"

	"professional-meetups-monolith/backend/internal/eventbus"
	"professional-meetups-monolith/backend/internal/modules/analytics/config"
	"professional-meetups-monolith/backend/internal/modules/analytics/registry"
	"professional-meetups-monolith/backend/internal/modules/analytics/report"
	"professional-meetups-monolith/backend/internal/modules/analytics/repository"
	"professional-meetups-monolith/backend/internal/platform/apperror"
	"professional-meetups-monolith/backend/internal/platform/flags"
	"professional-meetups-monolith/backend/internal/platform/metrics"
)

// FlagEnabled is the kill switch the ingest respects (seeded on, D8).
const FlagEnabled = "analytics.enabled"

// MaxBatchEvents is the most events one batch may carry (plan 29 §4.3).
const MaxBatchEvents = 50

// FlagEvaluator is the slice of the flags service analytics needs.
type FlagEvaluator interface {
	Enabled(ctx context.Context, key string, subject flags.Subject) (bool, error)
}

// Deps groups the module's dependencies.
type Deps struct {
	Store    *repository.Store
	Config   config.Config
	Flags    FlagEvaluator
	Registry *registry.Registry
	// Archive uploads a finished partition and the daily report. Nil skips
	// both uploads.
	Archive Uploader
	// Mailer emails the daily report. Nil with recipients configured is a
	// delivery failure, logged and retried.
	Mailer ReportMailer
	// Reconciliation reads billing's daily check for the report. Nil
	// leaves it out.
	Reconciliation report.ReconciliationSource
	// Writer overrides the buffer's writer (tests). Nil uses Store.
	Writer Writer
	// Buffer sizing; zero takes the defaults.
	BufferCapacity int
	FlushEvery     time.Duration
	FlushSize      int
	Now            func() time.Time
	Logger         *slog.Logger
}

// Service is the analytics module.
type Service struct {
	store    *repository.Store
	cfg      config.Config
	flags    FlagEvaluator
	registry *registry.Registry
	archive  Uploader
	mailer   ReportMailer
	// reconciliation is billing's daily check, for the report.
	reconciliation report.ReconciliationSource
	buffer         *Buffer
	otel           otellog.Logger
	now            func() time.Time
	logger         *slog.Logger
}

// New constructs the Service. Call Run to start the flusher.
func New(d Deps) *Service {
	now := d.Now
	if now == nil {
		now = time.Now
	}
	logger := d.Logger
	if logger == nil {
		logger = slog.Default()
	}
	reg := d.Registry
	if reg == nil {
		reg = registry.Default()
	}
	var w Writer = d.Store
	if d.Writer != nil {
		w = d.Writer
	}
	s := &Service{
		store:          d.Store,
		cfg:            d.Config,
		flags:          d.Flags,
		registry:       reg,
		archive:        d.Archive,
		mailer:         d.Mailer,
		reconciliation: d.Reconciliation,
		otel:           otel.GetLoggerProvider().Logger("analytics"),
		now:            now,
		logger:         logger,
	}
	s.buffer = NewBuffer(w, d.BufferCapacity, d.FlushEvery, d.FlushSize, logger)
	s.buffer.written = s.emitLogRecords
	return s
}

// Run starts the flusher and blocks until ctx is cancelled and the final
// flush is done.
func (s *Service) Run(ctx context.Context) { s.buffer.Run(ctx) }

// Done is closed once Run has returned.
func (s *Service) Done() <-chan struct{} { return s.buffer.Done() }

// Disabled reports whether the module collects nothing (no secret in
// production).
func (s *Service) Disabled() bool { return s.cfg.Disabled }

// UserKey is the pseudonymous key for a user id: hex HMAC-SHA256 under the
// analytics secret. "" for no user.
func (s *Service) UserKey(userID string) string {
	if userID == "" || s.cfg.Disabled {
		return ""
	}
	return userKey(s.cfg.UserKeySecret, userID)
}

func userKey(secret []byte, userID string) string {
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(strings.ToLower(userID)))
	return hex.EncodeToString(mac.Sum(nil))
}

// enabled evaluates the kill switch. A flag that cannot be read counts as
// off: when in doubt, collect nothing.
func (s *Service) enabled(ctx context.Context, userID, appVersion string) bool {
	if s.cfg.Disabled {
		return false
	}
	if s.flags == nil {
		return true
	}
	on, err := s.flags.Enabled(ctx, FlagEnabled, flags.Subject{UserID: userID, AppVersion: appVersion})
	if err != nil {
		s.logger.Warn("analytics: flag unreadable, dropping", "error", err)
		return false
	}
	return on
}

// --- ingest ---

// Context is the batch-level context from the device. Every field is
// coarse and checked; anything that does not match is cleared rather than
// stored.
type Context struct {
	InstallID   string
	AppVersion  string
	OSName      string
	OSVersion   string
	DeviceClass string
	Locale      string
}

// Batch is one POST /v1/analytics/events.
type Batch struct {
	// UserID is from the verified token; "" when signed out.
	UserID  string
	Context Context
	Events  []registry.Input
}

// IngestResult is what the ingest did with a batch.
type IngestResult struct {
	Accepted int
	Dropped  int
}

var (
	appVersionPattern = regexp.MustCompile(`^\d{1,4}\.\d{1,4}\.\d{1,4}(\+\d{1,6})?$`)
	osVersionPattern  = regexp.MustCompile(`^\d{1,4}(\.\d{1,4}){0,3}$`)
	localePattern     = regexp.MustCompile(`^[a-z]{2,3}([-_][A-Za-z]{2,4})?$`)
	osNames           = map[string]bool{"ios": true, "android": true, "other": true}
	deviceClasses     = map[string]bool{"phone": true, "tablet": true, "other": true}
)

// ErrInvalidBatch is a batch refused as a whole.
var ErrInvalidBatch = fmt.Errorf("analytics: invalid batch: %w", apperror.ErrInvalidInput)

func (c Context) clean() (Context, error) {
	id, err := uuid.Parse(c.InstallID)
	if err != nil || id == uuid.Nil || len(c.InstallID) != 36 {
		return Context{}, fmt.Errorf("%w: install_id must be a UUID", ErrInvalidBatch)
	}
	out := Context{InstallID: strings.ToLower(c.InstallID)}
	if appVersionPattern.MatchString(c.AppVersion) {
		out.AppVersion = c.AppVersion
	}
	if osNames[c.OSName] {
		out.OSName = c.OSName
	}
	if osVersionPattern.MatchString(c.OSVersion) {
		out.OSVersion = c.OSVersion
	}
	if deviceClasses[c.DeviceClass] {
		out.DeviceClass = c.DeviceClass
	}
	if localePattern.MatchString(c.Locale) {
		out.Locale = c.Locale
	}
	return out, nil
}

// Ingest validates a batch and queues what passes. It never waits on the
// database: the only error is a malformed batch.
func (s *Service) Ingest(ctx context.Context, b Batch) (IngestResult, error) {
	if len(b.Events) > MaxBatchEvents {
		return IngestResult{}, fmt.Errorf("%w: more than %d events", ErrInvalidBatch, MaxBatchEvents)
	}
	c, err := b.Context.clean()
	if err != nil {
		return IngestResult{}, err
	}
	if !s.enabled(ctx, b.UserID, c.AppVersion) {
		metrics.Default.AnalyticsEventsDropped.WithLabelValues(registry.DropDisabled).Add(float64(len(b.Events)))
		return IngestResult{Dropped: len(b.Events)}, nil
	}
	now := s.now()
	key := s.UserKey(b.UserID)
	var res IngestResult
	for _, in := range b.Events {
		v := s.registry.Validate(in, registry.SourceApp, now)
		for _, d := range v.AttributeDrops {
			metrics.Default.AnalyticsEventsDropped.WithLabelValues(d).Inc()
		}
		if v.Dropped != "" {
			metrics.Default.AnalyticsEventsDropped.WithLabelValues(v.Dropped).Inc()
			res.Dropped++
			continue
		}
		e := v.Event
		if !s.buffer.Offer(repository.Event{
			ReceivedAt: now, EventID: e.EventID, Name: e.Name, SchemaVersion: e.SchemaVersion,
			Source: registry.SourceApp, OccurredAt: e.OccurredAt, UserKey: key, InstallID: c.InstallID,
			SessionID: e.SessionID, AppVersion: c.AppVersion, OSName: c.OSName, OSVersion: c.OSVersion,
			DeviceClass: c.DeviceClass, Locale: c.Locale, Screen: e.Screen, FlowID: e.FlowID,
			FlowStep: e.FlowStep, Attributes: e.Attributes,
		}) {
			res.Dropped++
			continue
		}
		metrics.Default.AnalyticsEventsIngested.WithLabelValues(e.Family).Inc()
		res.Accepted++
	}
	return res, nil
}

// --- server events ---

// serverNamespace derives server event ids from their source (an outbox
// row), so a redelivered row produces the same id and is stored once.
var serverNamespace = uuid.MustParse("6f1b8c3e-2d4a-5e7f-9a0b-1c2d3e4f5a6b")

// ServerEvent is a domain event from another module's outbox.
type ServerEvent struct {
	// Source identifies the fact uniquely and stably, e.g.
	// "billing_outbox:<row id>:credits_spent:capture". The event id is
	// derived from it.
	Source string
	Name   string
	// UserID is the account it is about, or "" (counted, not attributed).
	UserID     string
	OccurredAt time.Time
	Attributes map[string]any
}

// EventIDFor is the id a server event with this source gets.
func EventIDFor(source string) uuid.UUID { return uuid.NewSHA1(serverNamespace, []byte(source)) }

// Record queues a server event. It has no error to return on purpose: a
// consumer that calls it can never fail, or slow, the outbox it sits on.
// An event the registry refuses is dropped, counted and logged.
func (s *Service) Record(ctx context.Context, e ServerEvent) {
	if !s.enabled(ctx, e.UserID, "") {
		metrics.Default.AnalyticsEventsDropped.WithLabelValues(registry.DropDisabled).Inc()
		return
	}
	now := s.now()
	occurred := e.OccurredAt
	if occurred.IsZero() {
		occurred = now
	}
	attrs, err := marshalAttributes(e.Attributes)
	if err != nil {
		s.logger.Warn("analytics: server event attributes", "event", e.Name, "error", err)
		return
	}
	v := s.registry.Validate(registry.Input{
		EventID: EventIDFor(e.Source).String(), Name: e.Name, SchemaVersion: 1,
		OccurredAt: occurred.UTC().Format(time.RFC3339Nano), Attributes: attrs,
	}, registry.SourceServer, now)
	for _, d := range v.AttributeDrops {
		metrics.Default.AnalyticsEventsDropped.WithLabelValues(d).Inc()
	}
	if v.Dropped != "" {
		metrics.Default.AnalyticsEventsDropped.WithLabelValues(v.Dropped).Inc()
		s.logger.Warn("analytics: server event refused by the registry", "event", e.Name, "reason", v.Dropped)
		return
	}
	if len(v.AttributeDrops) > 0 {
		s.logger.Warn("analytics: server event attributes refused by the registry", "event", e.Name, "reasons", v.AttributeDrops)
	}
	if s.buffer.Offer(repository.Event{
		ReceivedAt: now, EventID: v.Event.EventID, Name: v.Event.Name, SchemaVersion: v.Event.SchemaVersion,
		Source: registry.SourceServer, OccurredAt: v.Event.OccurredAt, UserKey: s.UserKey(e.UserID),
		Attributes: v.Event.Attributes,
	}) {
		metrics.Default.AnalyticsEventsIngested.WithLabelValues(v.Event.Family).Inc()
	}
}

// --- consent and deletion ---

// SetConsent records a signed-in user's choice server side (PUT
// /v1/analytics/consent). Opting out also deletes what was already stored
// for the account, so "off" means none of it is kept.
func (s *Service) SetConsent(ctx context.Context, userID string, optedOut bool) error {
	if userID == "" {
		return fmt.Errorf("analytics: consent needs a signed-in user: %w", apperror.ErrUnauthorized)
	}
	if s.cfg.Disabled {
		return nil
	}
	key := s.UserKey(userID)
	if !optedOut {
		if err := s.store.Q.DeleteOptOut(ctx, key); err != nil {
			return fmt.Errorf("analytics: consent: %w: %w", apperror.ErrInternal, err)
		}
		return nil
	}
	if err := s.store.Q.InsertOptOut(ctx, key); err != nil {
		return fmt.Errorf("analytics: consent: %w: %w", apperror.ErrInternal, err)
	}
	s.buffer.Sync(ctx)
	if _, err := s.store.Q.DeleteEventsByUserKey(ctx, textKey(key)); err != nil {
		return fmt.Errorf("analytics: consent: delete events: %w: %w", apperror.ErrInternal, err)
	}
	if err := s.store.Q.DeleteFirstSeen(ctx, key); err != nil {
		return fmt.Errorf("analytics: consent: %w: %w", apperror.ErrInternal, err)
	}
	if err := s.store.Q.DeleteActivityByUserKey(ctx, key); err != nil {
		return fmt.Errorf("analytics: consent: %w: %w", apperror.ErrInternal, err)
	}
	return nil
}

// HandleUserDeleted removes everything stored for a deleted account: raw
// events, the cohort row and any opt-out. A consumer of the user-deleted
// outbox, so a failure is retried. Queued events are flushed first so none
// of the account's land after the delete.
func (s *Service) HandleUserDeleted(ctx context.Context, p eventbus.UserDeletedPayload) error {
	if p.UserID == "" {
		return errors.New("analytics: user-deleted payload has no user id")
	}
	if s.cfg.Disabled {
		return nil
	}
	s.buffer.Sync(ctx)
	n, err := s.store.DeleteUser(ctx, s.UserKey(p.UserID))
	if err != nil {
		return err
	}
	s.logger.Info("analytics: deleted a removed account's events", "events", n)
	return nil
}

// --- OTel log records ---

// emitLogRecords sends each written event as an OTel log record (plan 29
// §4.4), on the flusher goroutine, never on a request. With the default
// exporter (none) the SDK discards them.
func (s *Service) emitLogRecords(ctx context.Context, events []repository.Event) {
	for _, e := range events {
		var r otellog.Record
		r.SetEventName(e.Name)
		r.SetTimestamp(e.OccurredAt)
		r.SetObservedTimestamp(e.ReceivedAt)
		r.SetSeverity(otellog.SeverityInfo)
		r.SetBody(attribute.StringValue(e.Name))
		r.AddAttributes(
			attribute.String("event.name", e.Name),
			attribute.String("event.id", e.EventID.String()),
			attribute.String("event.source", e.Source),
		)
		if e.Screen != "" {
			r.AddAttributes(attribute.String("app.screen.name", e.Screen))
		}
		if e.FlowID != "" {
			r.AddAttributes(attribute.String("app.flow.id", e.FlowID))
		}
		s.otel.Emit(ctx, r)
	}
}
