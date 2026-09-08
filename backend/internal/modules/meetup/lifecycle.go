package meetup

import (
	"context"
	"log/slog"
	"time"
)

// pollInterval is how often the lifecycle sweeps run. Deliberately coarse:
// this poller isn't draining a queue that needs near-real-time delivery,
// it's noticing that a meetup has crossed a time threshold, which only needs
// to happen within roughly a minute.
const pollInterval = 60 * time.Second

// sweeper is the subset of Service the poller needs — narrow on purpose, so
// a test can drive it without constructing the whole module.
type sweeper interface {
	NotifyStartingSoonSweep(ctx context.Context) (int, error)
	AutoCloseSweep(ctx context.Context) (int, error)
}

// Poller runs the two lifecycle sweeps on a fixed interval. Started with
// `go poller.Run(ctx)` from cmd/monolith, and stops when that context is
// cancelled — the same shape the source's own poller has.
//
// SAFE UNDER MORE THAN ONE INSTANCE, as of the hardening pass
// (docs/plans/03-hardening-pass.md §C2). Both sweeps claim their rows with a
// single `UPDATE ... WHERE id IN (SELECT ... FOR UPDATE SKIP LOCKED)
// RETURNING`, so two pollers ticking at the same moment take disjoint sets
// rather than both acting on the same meetups. See ClaimMeetupsStartingSoon
// and ClaimMeetupsToAutoClose in repository/queries/meetups.sql.
//
// This comment previously said the opposite — that a single-process
// assumption was fine because each sweep's write was already an atomic
// conditional UPDATE a concurrent action could not double-apply. That
// reasoning was true but answered the wrong question. The atomic UPDATE did
// prevent double-CLOSING; it did nothing about duplicate NOTIFICATION,
// because both pollers read the same candidates and notified everyone before
// either write landed. Only one of them then lost the race on an UPDATE it
// had already sent pushes for. A control test measures the old behaviour
// under a forced overlap at 24 notifications for 12 meetups, and it was
// invisible precisely because the meetup state stayed correct throughout.
type Poller struct {
	svc    sweeper
	logger *slog.Logger
}

// NewPoller constructs a Poller over svc.
func NewPoller(svc sweeper, logger *slog.Logger) *Poller {
	if logger == nil {
		logger = slog.Default()
	}
	return &Poller{svc: svc, logger: logger}
}

// Run polls until ctx is cancelled.
func (p *Poller) Run(ctx context.Context) {
	ticker := time.NewTicker(pollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			p.Tick(ctx)
		}
	}
}

// Tick runs both sweeps once. Exported so a test can drive one iteration
// deterministically instead of waiting on the ticker.
func (p *Poller) Tick(ctx context.Context) {
	if notified, err := p.svc.NotifyStartingSoonSweep(ctx); err != nil {
		p.logger.Error("lifecycle poller: starting-soon sweep", "error", err)
	} else if notified > 0 {
		p.logger.Info("lifecycle poller: starting-soon sweep", "notified", notified)
	}

	if closed, err := p.svc.AutoCloseSweep(ctx); err != nil {
		p.logger.Error("lifecycle poller: auto-close sweep", "error", err)
	} else if closed > 0 {
		p.logger.Info("lifecycle poller: auto-close sweep", "closed", closed)
	}
}
