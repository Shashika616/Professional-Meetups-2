package analytics

import (
	"context"
	"log/slog"
	"time"

	"professional-meetups-monolith/backend/internal/modules/analytics/registry"
	"professional-meetups-monolith/backend/internal/modules/analytics/repository"
	"professional-meetups-monolith/backend/internal/platform/metrics"
)

// Buffer defaults (plan 29 §4.3).
const (
	DefaultBufferCapacity = 10_000
	DefaultFlushEvery     = 2 * time.Second
	DefaultFlushSize      = 500
	// flushTimeout bounds one write, so a stuck database cannot hold the
	// flusher forever; the buffer fills and drops meanwhile, which is the
	// best-effort contract.
	flushTimeout = 10 * time.Second
	// shutdownTimeout bounds the final flush on SIGTERM.
	shutdownTimeout = 5 * time.Second
)

// Writer stores a batch. *repository.Store is the real one.
type Writer interface {
	Write(ctx context.Context, events []repository.Event) (repository.WriteResult, error)
}

// Buffer is the bounded, in-process queue between the ingest and Postgres.
//
// Offer never blocks: when the queue is full the event is dropped and
// counted (analytics is best effort; billing is exactly once). One flusher
// goroutine drains it every FlushEvery, or as soon as FlushSize events are
// waiting, and once more on shutdown. A slow or failing database therefore
// costs dropped events, never a slow user request.
type Buffer struct {
	queue      chan repository.Event
	sync       chan chan struct{}
	writer     Writer
	flushEvery time.Duration
	flushSize  int
	logger     *slog.Logger
	// written is called after each successful write with the events
	// written (the OTel log records).
	written func(context.Context, []repository.Event)
	done    chan struct{}
}

// NewBuffer constructs a Buffer. Zero values take the defaults.
func NewBuffer(w Writer, capacity int, flushEvery time.Duration, flushSize int, logger *slog.Logger) *Buffer {
	if capacity <= 0 {
		capacity = DefaultBufferCapacity
	}
	if flushEvery <= 0 {
		flushEvery = DefaultFlushEvery
	}
	if flushSize <= 0 {
		flushSize = DefaultFlushSize
	}
	if logger == nil {
		logger = slog.Default()
	}
	return &Buffer{
		queue:      make(chan repository.Event, capacity),
		sync:       make(chan chan struct{}),
		writer:     w,
		flushEvery: flushEvery,
		flushSize:  flushSize,
		logger:     logger,
		done:       make(chan struct{}),
	}
}

// Offer queues one event and reports whether it fit. Never blocks.
func (b *Buffer) Offer(e repository.Event) bool {
	select {
	case b.queue <- e:
		metrics.Default.AnalyticsBufferDepth.Set(float64(len(b.queue)))
		return true
	default:
		metrics.Default.AnalyticsEventsDropped.WithLabelValues(registry.DropBufferFull).Inc()
		return false
	}
}

// Depth is how many events are waiting.
func (b *Buffer) Depth() int { return len(b.queue) }

// Done is closed when Run has returned, after the final flush.
func (b *Buffer) Done() <-chan struct{} { return b.done }

// Sync asks the flusher to write everything queued so far and waits for it,
// or for ctx. Used before an account's data is deleted, so nothing of
// theirs still queued lands after the delete.
func (b *Buffer) Sync(ctx context.Context) {
	ack := make(chan struct{})
	select {
	case b.sync <- ack:
	case <-b.done:
		return
	case <-ctx.Done():
		return
	}
	select {
	case <-ack:
	case <-ctx.Done():
	}
}

// Run is the flusher. It returns when ctx is cancelled, after writing what
// is still queued (within shutdownTimeout).
func (b *Buffer) Run(ctx context.Context) {
	defer close(b.done)
	ticker := time.NewTicker(b.flushEvery)
	defer ticker.Stop()
	batch := make([]repository.Event, 0, b.flushSize)
	flush := func(ctx context.Context) {
		if len(batch) > 0 {
			b.write(ctx, batch)
			batch = batch[:0]
		}
		metrics.Default.AnalyticsBufferDepth.Set(float64(len(b.queue)))
	}
	// drain takes what is queued right now (not what keeps arriving, so a
	// steady producer cannot hold it), flushing every full batch, then the
	// remainder.
	drain := func(ctx context.Context) {
		for n := len(b.queue); n > 0; n-- {
			select {
			case e := <-b.queue:
				batch = append(batch, e)
				if len(batch) >= b.flushSize {
					flush(ctx)
				}
			default:
				n = 1
			}
		}
		flush(ctx)
	}
	for {
		select {
		case <-ctx.Done():
			final, cancel := context.WithTimeout(context.WithoutCancel(ctx), shutdownTimeout)
			drain(final)
			cancel()
			return
		case e := <-b.queue:
			batch = append(batch, e)
			if len(batch) >= b.flushSize {
				flush(ctx)
			}
		case ack := <-b.sync:
			drain(ctx)
			close(ack)
		case <-ticker.C:
			flush(ctx)
		}
	}
}

func (b *Buffer) write(ctx context.Context, batch []repository.Event) {
	ctx, cancel := context.WithTimeout(ctx, flushTimeout)
	defer cancel()
	res, err := b.writer.Write(ctx, batch)
	if err != nil {
		// Dropped, not retried: a retry would hold the flusher on a
		// failing database while the buffer overflows anyway.
		metrics.Default.AnalyticsFlushFailures.Inc()
		metrics.Default.AnalyticsEventsDropped.WithLabelValues("flush_failed").Add(float64(len(batch)))
		b.logger.Warn("analytics: flush failed, events dropped", "events", len(batch), "error", err)
		return
	}
	metrics.Default.AnalyticsFlushedBatches.Inc()
	if res.OptedOut > 0 {
		metrics.Default.AnalyticsEventsDropped.WithLabelValues(registry.DropOptedOut).Add(float64(res.OptedOut))
	}
	if res.Duplicates > 0 {
		metrics.Default.AnalyticsEventsDropped.WithLabelValues(registry.DropDuplicate).Add(float64(res.Duplicates))
	}
	if b.written != nil {
		b.written(ctx, batch)
	}
}
