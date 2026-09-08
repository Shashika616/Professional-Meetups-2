// Package metrics is this backend's one Prometheus surface, shared by both
// binaries (docs/plans/03-hardening-pass.md §D3). Before it, the entire
// stack's only health signal was Postgres's own pg_isready, used purely for
// Compose dependency ordering and never exposed to anything that could
// alert on it.
//
// Deliberately small. The point is not day-one comprehensiveness — it is
// that a metrics surface EXISTS, so a counter can be added to code someone
// is already editing, instead of every future instrumentation task starting
// with "first, introduce Prometheus." Retrofitting instrumentation into a
// codebase with none is the expensive part; adding the seventh counter to
// one that already has six is not.
//
// One package-level registry rather than a threaded-through *Registry:
// counters get incremented from event-bus handlers, HTTP middleware, gRPC
// interceptors and background pollers, and threading a registry into all of
// those would be a lot of plumbing for a process that will only ever have
// one. Tests that need isolation use NewCollectors against their own
// registry instead of the package-level one.
package metrics

import (
	"net/http"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Collectors is every metric this backend records. Grouped in one struct so
// a test can construct an isolated set against its own registry and assert
// on it without the package-level singleton's cross-test bleed.
type Collectors struct {
	// EventHandlerFailures counts swallowed event-bus handler failures —
	// both returned errors and recovered panics (§A1). This is the metric
	// that makes the bus's deliberately-silent failure posture observable:
	// a handler error is logged and dropped by design, so without a counter
	// there is nothing distinguishing "this happened once six weeks ago"
	// from "this happens on every single event."
	EventHandlerFailures *prometheus.CounterVec

	// HTTPRequests and HTTPDuration are the gateway's per-route request
	// counts and latencies. Labelled by ROUTE PATTERN, never the raw path:
	// /v1/meetups/{id} is one label value, not one per meetup id, which is
	// the standard cardinality-explosion mistake.
	HTTPRequests *prometheus.CounterVec
	HTTPDuration *prometheus.HistogramVec

	// GRPCRequests and GRPCDuration are the monolith's equivalents, labelled
	// by full method name (already a bounded set).
	GRPCRequests *prometheus.CounterVec
	GRPCDuration *prometheus.HistogramVec

	// Outbox instrumentation (§F). Delivery is a background loop nobody
	// watches, so "quietly stopped delivering" has to be visible as numbers.
	OutboxDelivered    prometheus.Counter
	OutboxFailed       prometheus.Counter
	OutboxDeadLettered prometheus.Counter
	OutboxPending      prometheus.Gauge
}

// NewCollectors registers a fresh set of metrics on reg.
func NewCollectors(reg prometheus.Registerer) *Collectors {
	factory := promauto(reg)
	return &Collectors{
		EventHandlerFailures: factory.counterVec(prometheus.CounterOpts{
			Name: "event_handler_failure_total",
			Help: "Event-bus handler failures swallowed by Publish, by topic and failure kind.",
		}, []string{"topic", "kind"}),

		HTTPRequests: factory.counterVec(prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "HTTP requests handled by the gateway, by route pattern, method and status class.",
		}, []string{"route", "method", "status"}),
		HTTPDuration: factory.histogramVec(prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "HTTP request latency by route pattern.",
			Buckets: prometheus.DefBuckets,
		}, []string{"route", "method"}),

		GRPCRequests: factory.counterVec(prometheus.CounterOpts{
			Name: "grpc_requests_total",
			Help: "gRPC requests handled by the monolith, by method and status code.",
		}, []string{"method", "code"}),
		GRPCDuration: factory.histogramVec(prometheus.HistogramOpts{
			Name:    "grpc_request_duration_seconds",
			Help:    "gRPC handler latency by method.",
			Buckets: prometheus.DefBuckets,
		}, []string{"method"}),

		OutboxDelivered: factory.counter(prometheus.CounterOpts{
			Name: "notification_outbox_delivered_total",
			Help: "Notification outbox rows successfully delivered.",
		}),
		OutboxFailed: factory.counter(prometheus.CounterOpts{
			Name: "notification_outbox_failed_total",
			Help: "Notification outbox delivery attempts that failed and will be retried.",
		}),
		OutboxDeadLettered: factory.counter(prometheus.CounterOpts{
			Name: "notification_outbox_dead_lettered_total",
			Help: "Notification outbox rows abandoned after exhausting their retry ceiling.",
		}),
		OutboxPending: factory.gauge(prometheus.GaugeOpts{
			Name: "notification_outbox_pending",
			Help: "Rows claimed in the most recent outbox poll — a persistently non-zero value means delivery is not keeping up.",
		}),
	}
}

// registry is the process-wide registry. Go runtime and process collectors
// are registered alongside this backend's own: goroutine count and RSS are
// the first two things anyone actually looks at when a process misbehaves,
// and they cost nothing to expose.
var registry = func() *prometheus.Registry {
	r := prometheus.NewRegistry()
	r.MustRegister(collectors.NewGoCollector())
	r.MustRegister(collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}))
	return r
}()

// Default is the process-wide metric set, the one every non-test caller
// uses.
var Default = NewCollectors(registry)

// Handler serves the process-wide registry in Prometheus text format. Mount
// it at /metrics.
func Handler() http.Handler {
	return promhttp.HandlerFor(registry, promhttp.HandlerOpts{})
}

// ObserveHTTP records one completed HTTP request. status is bucketed to its
// class ("2xx", "4xx", ...) rather than recorded exactly, keeping the label
// set small — the exact code is in the access log, which is where you look
// once a metric tells you which route to look at.
func (c *Collectors) ObserveHTTP(route, method string, status int, elapsed time.Duration) {
	c.HTTPRequests.WithLabelValues(route, method, statusClass(status)).Inc()
	c.HTTPDuration.WithLabelValues(route, method).Observe(elapsed.Seconds())
}

// ObserveGRPC records one completed gRPC call.
func (c *Collectors) ObserveGRPC(method, code string, elapsed time.Duration) {
	c.GRPCRequests.WithLabelValues(method, code).Inc()
	c.GRPCDuration.WithLabelValues(method).Observe(elapsed.Seconds())
}

func statusClass(status int) string {
	switch {
	case status >= 500:
		return "5xx"
	case status >= 400:
		return "4xx"
	case status >= 300:
		return "3xx"
	case status >= 200:
		return "2xx"
	default:
		return "1xx"
	}
}

// StatusClass is exported for callers that already have a status code and
// want the same bucketing without recording a metric.
func StatusClass(status int) string { return statusClass(status) }

// Code renders an integer status for a label without pulling strconv into
// every call site.
func Code(i int) string { return strconv.Itoa(i) }

// factory is a tiny local stand-in for the upstream promauto package —
// same "construct and register in one call, panic on duplicate" behavior,
// without the extra import for four helper methods.
type factory struct{ reg prometheus.Registerer }

func promauto(reg prometheus.Registerer) factory { return factory{reg: reg} }

func (r factory) counter(opts prometheus.CounterOpts) prometheus.Counter {
	c := prometheus.NewCounter(opts)
	r.reg.MustRegister(c)
	return c
}

func (r factory) gauge(opts prometheus.GaugeOpts) prometheus.Gauge {
	g := prometheus.NewGauge(opts)
	r.reg.MustRegister(g)
	return g
}

func (r factory) counterVec(opts prometheus.CounterOpts, labels []string) *prometheus.CounterVec {
	c := prometheus.NewCounterVec(opts, labels)
	r.reg.MustRegister(c)
	return c
}

func (r factory) histogramVec(opts prometheus.HistogramOpts, labels []string) *prometheus.HistogramVec {
	h := prometheus.NewHistogramVec(opts, labels)
	r.reg.MustRegister(h)
	return h
}
