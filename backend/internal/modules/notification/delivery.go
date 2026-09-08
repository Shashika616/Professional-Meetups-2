package notification

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"professional-meetups-monolith/backend/internal/platform/breaker"
	"professional-meetups-monolith/backend/internal/platform/outbox"
)

// Circuit-breaker parameters for FCM (§E2b).
//
// Started from the SOS-alert breaker's own values (5 consecutive failures,
// 30s reset) rather than inventing new ones — that breaker protects the same
// kind of thing (a synchronous call to a third party that can be slow or
// down) and its numbers have already been reasoned about here. Nothing about
// FCM's behaviour under load argued for different values, so they are the
// same on purpose; if real production behaviour ever justifies changing
// them, change them here and say why.
//
// WHAT THE BREAKER IS FOR, precisely: a degraded FCM should cost one fast
// rejection per attempt, not a full 5-second timeout on every send in every
// claimed batch. Without it, an FCM outage turns the poller into a loop that
// spends all its time waiting on a service already known to be down, while
// the pending set grows behind it.
const (
	fcmBreakerFailureThreshold = 5
	fcmBreakerResetTimeout     = 30 * time.Second
)

// DeviceTokenCleaner deletes device tokens FCM has reported as permanently
// dead. Satisfied by the meetup module's DeviceTokenRepository — declared as
// its own narrow interface here so this module depends on the one capability
// it needs rather than on meetup's whole repository surface.
type DeviceTokenCleaner interface {
	DeleteToken(ctx context.Context, fcmToken string) error
}

// detailedSender is the optional richer interface FCMPushSender satisfies.
// LoggingPushSender does not, and does not need to: it has no per-token
// outcomes to report.
type detailedSender interface {
	SendToTokensDetailed(ctx context.Context, tokens []string, title, body string, data map[string]string) (SendResult, error)
}

// Delivery is the outbox poller's process function: everything that happens
// to one claimed notification row (§F4).
type Delivery struct {
	sender  Sender
	tokens  DeviceTokenCleaner
	breaker *breaker.Breaker
	logger  *slog.Logger
}

// NewDelivery constructs the process function's owner. tokens may be nil,
// which disables dead-token cleanup (used by tests that aren't exercising it).
func NewDelivery(sender Sender, tokens DeviceTokenCleaner, logger *slog.Logger) *Delivery {
	if logger == nil {
		logger = slog.Default()
	}
	return &Delivery{
		sender:  sender,
		tokens:  tokens,
		breaker: breaker.New(fcmBreakerFailureThreshold, fcmBreakerResetTimeout),
		logger:  logger,
	}
}

// Payload is the decoded shape of an outbox row. It mirrors the meetup
// module's repository.NotificationPayload — the two are wire-compatible by
// their JSON tags rather than by a shared Go type, because neither module
// imports the other (ADR-001 §2).
type Payload struct {
	FCMTokens []string          `json:"fcm_tokens"`
	Title     string            `json:"title"`
	Body      string            `json:"body"`
	Data      map[string]string `json:"data"`
}

// Process delivers one claimed outbox row. Wired as the process function
// passed to outbox.New.
//
// Return contract, which the generic poller acts on:
//   - nil            → the row is marked processed.
//   - ErrPermanent   → dead-lettered immediately, no further attempts.
//   - anything else  → retried with backoff, until the attempt ceiling.
func (d *Delivery) Process(ctx context.Context, row outbox.Row) error {
	var payload Payload
	if err := json.Unmarshal(row.Payload, &payload); err != nil {
		// A row whose payload will not decode cannot be delivered on any
		// future attempt either, so retrying it ten times is pure waste.
		// Straight to the dead-letter state, where it stays visible.
		return fmt.Errorf("%w: decode payload: %v", outbox.ErrPermanent, err)
	}
	if len(payload.FCMTokens) == 0 {
		// Nothing to send to. Succeeding (rather than failing) is correct:
		// there is no delivery to retry, and leaving the row pending forever
		// would just grow the claimable set.
		return nil
	}

	// The breaker wraps the whole batch send rather than each token: the
	// thing being protected is "FCM as a dependency", and its state should
	// be driven by whether calls to FCM are working, not by how many devices
	// happened to be in one row.
	var result SendResult
	sendErr := d.breaker.Execute(func() error {
		var err error
		result, err = d.send(ctx, payload)
		if err != nil {
			return err
		}
		// A batch in which every token failed transiently counts as a
		// failure for the breaker's purposes — that is what "FCM is not
		// working" looks like from here. A batch with any success does not,
		// even if some tokens failed, because the dependency is evidently up.
		if result.Delivered == 0 && result.LastErr != nil {
			return result.LastErr
		}
		return nil
	})

	// Dead-token cleanup runs regardless of the batch's overall outcome
	// (§E2c). An UNREGISTERED verdict is information FCM has already given
	// us, and it stays true whether or not the other tokens in the same row
	// succeeded — discarding it because a sibling token timed out would mean
	// re-attempting a known-dead device on every future notification,
	// forever.
	d.deleteDeadTokens(ctx, result.Unregistered)

	if errors.Is(sendErr, breaker.ErrOpen) {
		// Not attempted at all. Retryable by definition — the breaker will
		// half-open on its own, and the row's backoff is the right place to
		// wait it out.
		return fmt.Errorf("notification: fcm circuit breaker is open, delivery not attempted: %w", sendErr)
	}
	if sendErr != nil {
		return sendErr
	}

	// PARTIAL SUCCESS IS SUCCESS. If at least one device received it, or the
	// only failures were permanently-dead tokens now deleted, the row is
	// done. Retrying it would re-deliver to the devices that already got it
	// — a guaranteed duplicate in exchange for nothing, since the dead
	// tokens will never succeed no matter how many times they are tried.
	if result.Delivered == 0 && result.LastErr != nil {
		return result.LastErr
	}
	return nil
}

// send calls the sender, using the richer per-token interface when the
// sender supports it.
func (d *Delivery) send(ctx context.Context, payload Payload) (SendResult, error) {
	if detailed, ok := d.sender.(detailedSender); ok {
		return detailed.SendToTokensDetailed(ctx, payload.FCMTokens, payload.Title, payload.Body, payload.Data)
	}

	// A plain Sender (LoggingPushSender, or a test fake) reports only
	// all-or-nothing.
	if err := d.sender.SendToTokens(ctx, payload.FCMTokens, payload.Title, payload.Body, payload.Data); err != nil {
		return SendResult{LastErr: err}, nil
	}
	return SendResult{Delivered: len(payload.FCMTokens)}, nil
}

// deleteDeadTokens removes device tokens FCM reported as permanently
// unregistered.
//
// Failures here are logged, never propagated: the notification itself may
// well have been delivered to this user's other devices, and turning a
// housekeeping failure into a redelivery would produce a duplicate push to
// fix a stale row. The token simply gets deleted on the next notification
// that reaches it.
func (d *Delivery) deleteDeadTokens(ctx context.Context, tokens []string) {
	if d.tokens == nil || len(tokens) == 0 {
		return
	}
	for _, token := range tokens {
		if err := d.tokens.DeleteToken(ctx, token); err != nil {
			// The token is never logged — only that one was removed. See
			// LoggingPushSender's doc comment for why.
			d.logger.Error("notification: failed to delete unregistered device token", "error", err)
			continue
		}
		d.logger.Info("notification: deleted permanently unregistered device token")
	}
}
