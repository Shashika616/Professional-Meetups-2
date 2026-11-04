package middleware

import (
	"context"
	"net/http"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel/trace"
)

// EdgeOption configures EdgeTrace.
type EdgeOption func(*edgeConfig)

type edgeConfig struct{ tp trace.TracerProvider }

// WithEdgeTracerProvider sets the tracer provider (tests); the default is
// the global one.
func WithEdgeTracerProvider(tp trace.TracerProvider) EdgeOption {
	return func(c *edgeConfig) { c.tp = tp }
}

type hiddenQueryKey struct{}

type hiddenQuery struct{ raw, requestURI string }

// EdgeTrace is the gateway's server span, set up for a public edge (plan
// 30B, #119 and 3.3):
//
//   - A caller's traceparent does not make our span its child: the span is
//     a new root, linked to the caller's context (otelhttp's public
//     endpoint mode), so a client cannot choose our trace ids or force
//     sampling.
//   - Inbound baggage is dropped before anything reads it, so a client
//     cannot inject attributes into our telemetry.
//   - The span never sees the query string. Browse requests carry the
//     viewer's coordinates there, and an exported trace is the last place
//     they should be copied to. The handler still gets the whole request.
//
// Health probes are not traced.
func EdgeTrace(next http.Handler, opts ...EdgeOption) http.Handler {
	var cfg edgeConfig
	for _, o := range opts {
		o(&cfg)
	}
	restore := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if h, ok := r.Context().Value(hiddenQueryKey{}).(hiddenQuery); ok {
			u := *r.URL
			u.RawQuery = h.raw
			r = r.WithContext(r.Context())
			r.URL, r.RequestURI = &u, h.requestURI
		}
		next.ServeHTTP(w, r)
	})
	otelOpts := []otelhttp.Option{
		otelhttp.WithPublicEndpointFn(func(*http.Request) bool { return true }),
		otelhttp.WithFilter(func(r *http.Request) bool {
			return r.URL.Path != "/healthz" && r.URL.Path != "/readyz"
		}),
		otelhttp.WithSpanNameFormatter(func(_ string, r *http.Request) string { return r.Method }),
	}
	if cfg.tp != nil {
		otelOpts = append(otelOpts, otelhttp.WithTracerProvider(cfg.tp))
	}
	traced := otelhttp.NewHandler(restore, "gateway", otelOpts...)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.Header.Del("Baggage")
		if r.URL.RawQuery != "" {
			hidden := hiddenQuery{raw: r.URL.RawQuery, requestURI: r.RequestURI}
			u := *r.URL
			u.RawQuery = ""
			r = r.WithContext(context.WithValue(r.Context(), hiddenQueryKey{}, hidden))
			r.URL, r.RequestURI = &u, u.RequestURI()
		}
		traced.ServeHTTP(w, r)
	})
}
