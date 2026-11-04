package middleware

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/propagation"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
)

// Plan 30B (#119, 3.3): the gateway is the edge. A caller does not get to
// choose its trace or sampling (inbound traceparent starts a new root,
// linked rather than parented) or inject baggage, and a span never records
// the query string, which carries browse coordinates.
func TestEdgeTraceStartsARootSpanDropsBaggageAndRecordsNoQuery(t *testing.T) {
	rec := tracetest.NewSpanRecorder()
	tp := sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(rec))
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(propagation.TraceContext{}, propagation.Baggage{}))

	var sawQuery, sawBaggage string
	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sawQuery = r.URL.RawQuery
		sawBaggage = r.Header.Get("Baggage")
		w.WriteHeader(http.StatusOK)
	})
	h := EdgeTrace(inner, WithEdgeTracerProvider(tp))

	r := httptest.NewRequest(http.MethodGet, "/v1/meetups?viewer_lat=6.927123&viewer_lng=79.861234", nil)
	r.Header.Set("Traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")
	r.Header.Set("Baggage", "user=someone-else")
	h.ServeHTTP(httptest.NewRecorder(), r)

	if sawQuery != "viewer_lat=6.927123&viewer_lng=79.861234" {
		t.Errorf("the handler saw query %q; it must still get the whole request", sawQuery)
	}
	if sawBaggage != "" {
		t.Errorf("inbound baggage reached the handler: %q", sawBaggage)
	}
	spans := rec.Ended()
	if len(spans) != 1 {
		t.Fatalf("%d spans, want 1", len(spans))
	}
	s := spans[0]
	if s.Parent().IsValid() {
		t.Error("the server span is a child of the caller's trace; it must be a new root")
	}
	if s.SpanContext().TraceID().String() == "4bf92f3577b34da6a3ce929d0e0e4736" {
		t.Error("the caller chose the trace id")
	}
	for _, kv := range s.Attributes() {
		if v := kv.Value.String(); strings.Contains(v, "6.927") || strings.Contains(v, "viewer_lat") {
			t.Errorf("span attribute %s = %q carries the query", kv.Key, v)
		}
	}
}
