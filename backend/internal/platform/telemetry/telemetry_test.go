package telemetry

import (
	"context"
	"testing"

	"go.opentelemetry.io/otel"
)

func env(m map[string]string) func(string) string { return func(k string) string { return m[k] } }

func TestConfigFromEnv(t *testing.T) {
	cfg, err := ConfigFromEnv("gateway", "", env(nil))
	if err != nil || cfg.Exporter != ExporterNone || cfg.Environment != "local" || cfg.Version != "dev" {
		t.Fatalf("defaults = %+v, %v", cfg, err)
	}
	cfg, err = ConfigFromEnv("gateway", "r40", env(map[string]string{"K_SERVICE": "x", "OTEL_EXPORTER": "OTLP"}))
	if err != nil || cfg.Exporter != ExporterOTLP || cfg.Environment != "production" {
		t.Fatalf("cloud run = %+v, %v", cfg, err)
	}
	if _, err := ConfigFromEnv("gateway", "", env(map[string]string{"OTEL_EXPORTER": "jaeger"})); err == nil {
		t.Fatal("an unknown exporter was accepted")
	}
}

// With no exporter, spans still get ids (they are what ties a request
// together in the logs) and shutdown is clean.
func TestSetupNoneStillTraces(t *testing.T) {
	p, err := Setup(context.Background(), Config{ServiceName: "test", Version: "v", Environment: "local", Exporter: ExporterNone})
	if err != nil {
		t.Fatal(err)
	}
	_, span := otel.Tracer("t").Start(context.Background(), "op")
	if !span.SpanContext().TraceID().IsValid() {
		t.Fatal("no trace id with the none exporter")
	}
	span.End()
	if err := p.Shutdown(context.Background()); err != nil {
		t.Fatal(err)
	}
}

func TestDescribeSQLKeepsNoArguments(t *testing.T) {
	for sql, want := range map[string][2]string{
		"-- name: GetWallet :one\nSELECT * FROM billing.wallets WHERE user_id = $1": {"GetWallet", "SELECT"},
		"insert into analytics.events values ($1)":                                  {"INSERT", "INSERT"},
		"-- a comment\nUPDATE x SET y = 1":                                          {"UPDATE", "UPDATE"},
		"":                                                                          {"", ""},
	} {
		name, op := describeSQL(sql)
		if name != want[0] || op != want[1] {
			t.Errorf("describeSQL(%q) = %q, %q; want %q, %q", sql, name, op, want[0], want[1])
		}
	}
}
