// Package telemetry sets up OpenTelemetry for both binaries (plan 29 §4.4,
// ADR-011): traces, metrics and log records, sent wherever configuration
// says.
//
// # EXPORTERS ARE CONFIGURATION
//
// OTEL_EXPORTER picks one: none (the default, and the free tier's), stdout,
// or otlp to an OpenTelemetry Collector. The standard OTEL_* variables are
// honoured by the OTLP exporters (OTEL_EXPORTER_OTLP_ENDPOINT,
// OTEL_EXPORTER_OTLP_HEADERS, OTEL_EXPORTER_OTLP_PROTOCOL, ...), and
// OTEL_SERVICE_NAME / OTEL_RESOURCE_ATTRIBUTES add to the resource. Pointing
// the collector at Elasticsearch, Prometheus or Grafana is the collector's
// configuration, never a change here (docs/observability.md).
//
// With none, spans are still created and sampled: the trace id is what ties
// a gateway request to its monolith call in the logs (it replaced the
// request id that used to be lost between them). They are simply not sent
// anywhere.
package telemetry

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploghttp"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/exporters/stdout/stdoutlog"
	"go.opentelemetry.io/otel/exporters/stdout/stdoutmetric"
	"go.opentelemetry.io/otel/exporters/stdout/stdouttrace"
	"go.opentelemetry.io/otel/propagation"
	sdklog "go.opentelemetry.io/otel/sdk/log"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.43.0"
)

// Exporters.
const (
	ExporterNone   = "none"
	ExporterStdout = "stdout"
	ExporterOTLP   = "otlp"
)

// Config is what Setup needs.
type Config struct {
	ServiceName string
	Version     string
	// Environment is deployment.environment: production on Cloud Run,
	// local otherwise, unless DEPLOYMENT_ENVIRONMENT says.
	Environment string
	Exporter    string
}

// ConfigFromEnv reads OTEL_EXPORTER and DEPLOYMENT_ENVIRONMENT. An unknown
// exporter is an error: a typo must not silently mean "no telemetry".
func ConfigFromEnv(serviceName, version string, getenv func(string) string) (Config, error) {
	cfg := Config{ServiceName: serviceName, Version: version, Exporter: strings.ToLower(getenv("OTEL_EXPORTER"))}
	if cfg.Exporter == "" {
		cfg.Exporter = ExporterNone
	}
	switch cfg.Exporter {
	case ExporterNone, ExporterStdout, ExporterOTLP:
	default:
		return Config{}, fmt.Errorf("telemetry: OTEL_EXPORTER %q is not none, stdout or otlp", cfg.Exporter)
	}
	cfg.Environment = getenv("DEPLOYMENT_ENVIRONMENT")
	if cfg.Environment == "" {
		cfg.Environment = "local"
		if getenv("K_SERVICE") != "" {
			cfg.Environment = "production"
		}
	}
	if cfg.Version == "" {
		cfg.Version = "dev"
	}
	return cfg, nil
}

// Providers is what Setup installed. Shutdown flushes everything still
// buffered; call it on the way out.
type Providers struct {
	Tracer *sdktrace.TracerProvider
	Meter  *sdkmetric.MeterProvider
	Logger *sdklog.LoggerProvider
}

// Shutdown flushes and stops all three providers within ctx.
func (p *Providers) Shutdown(ctx context.Context) error {
	return errors.Join(p.Tracer.Shutdown(ctx), p.Meter.Shutdown(ctx), p.Logger.Shutdown(ctx))
}

// Setup builds the providers for cfg and installs them, with the W3C trace
// context and baggage propagators, as the global ones.
func Setup(ctx context.Context, cfg Config) (*Providers, error) {
	res, err := resource.Merge(resource.Default(), resource.NewWithAttributes(semconv.SchemaURL,
		semconv.ServiceName(cfg.ServiceName),
		semconv.ServiceVersion(cfg.Version),
		// The current semantic convention name, and the older one many
		// backends (and plan 29 §4.4) still key on.
		semconv.DeploymentEnvironmentNameKey.String(cfg.Environment),
		attribute.String("deployment.environment", cfg.Environment),
	))
	if err != nil {
		return nil, fmt.Errorf("telemetry: resource: %w", err)
	}
	// OTEL_SERVICE_NAME and OTEL_RESOURCE_ATTRIBUTES win over the defaults.
	if fromEnv, err := resource.New(ctx, resource.WithFromEnv()); err == nil {
		if merged, err := resource.Merge(res, fromEnv); err == nil {
			res = merged
		}
	}

	traceOpts := []sdktrace.TracerProviderOption{
		sdktrace.WithResource(res),
		sdktrace.WithSampler(sdktrace.ParentBased(sdktrace.AlwaysSample())),
	}
	meterOpts := []sdkmetric.Option{sdkmetric.WithResource(res)}
	logOpts := []sdklog.LoggerProviderOption{sdklog.WithResource(res)}

	switch cfg.Exporter {
	case ExporterStdout:
		te, err := stdouttrace.New(stdouttrace.WithWriter(os.Stderr))
		if err != nil {
			return nil, err
		}
		me, err := stdoutmetric.New(stdoutmetric.WithWriter(os.Stderr))
		if err != nil {
			return nil, err
		}
		le, err := stdoutlog.New(stdoutlog.WithWriter(os.Stderr))
		if err != nil {
			return nil, err
		}
		traceOpts = append(traceOpts, sdktrace.WithBatcher(te))
		meterOpts = append(meterOpts, sdkmetric.WithReader(sdkmetric.NewPeriodicReader(me, sdkmetric.WithInterval(time.Minute))))
		logOpts = append(logOpts, sdklog.WithProcessor(sdklog.NewBatchProcessor(le)))
	case ExporterOTLP:
		te, err := otlptracehttp.New(ctx)
		if err != nil {
			return nil, err
		}
		me, err := otlpmetrichttp.New(ctx)
		if err != nil {
			return nil, err
		}
		le, err := otlploghttp.New(ctx)
		if err != nil {
			return nil, err
		}
		traceOpts = append(traceOpts, sdktrace.WithBatcher(te))
		meterOpts = append(meterOpts, sdkmetric.WithReader(sdkmetric.NewPeriodicReader(me)))
		logOpts = append(logOpts, sdklog.WithProcessor(sdklog.NewBatchProcessor(le)))
	}

	p := &Providers{
		Tracer: sdktrace.NewTracerProvider(traceOpts...),
		Meter:  sdkmetric.NewMeterProvider(meterOpts...),
		Logger: sdklog.NewLoggerProvider(logOpts...),
	}
	otel.SetTracerProvider(p.Tracer)
	otel.SetMeterProvider(p.Meter)
	otel.SetLoggerProvider(p.Logger)
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(propagation.TraceContext{}, propagation.Baggage{}))
	return p, nil
}
