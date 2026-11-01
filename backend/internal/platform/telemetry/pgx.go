package telemetry

import (
	"context"
	"strings"

	"github.com/jackc/pgx/v5"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"
)

// PgxTracer is a pgx QueryTracer that opens one client span per query.
//
// The span carries the operation (SELECT, INSERT, ...) and, when the
// statement is a sqlc query, its name ("-- name: GetWallet :one"). Never
// the arguments, and never the full statement: arguments are user data,
// and a span leaves the process (plan 29 §4.2: nothing personal).
type PgxTracer struct{}

var _ pgx.QueryTracer = PgxTracer{}

type spanKey struct{}

func (PgxTracer) TraceQueryStart(ctx context.Context, _ *pgx.Conn, data pgx.TraceQueryStartData) context.Context {
	name, op := describeSQL(data.SQL)
	ctx, span := otel.Tracer("pgx").Start(ctx, "db "+name,
		trace.WithSpanKind(trace.SpanKindClient),
		trace.WithAttributes(
			attribute.String("db.system.name", "postgresql"),
			attribute.String("db.operation.name", op),
		),
	)
	return context.WithValue(ctx, spanKey{}, span)
}

func (PgxTracer) TraceQueryEnd(ctx context.Context, _ *pgx.Conn, data pgx.TraceQueryEndData) {
	span, ok := ctx.Value(spanKey{}).(trace.Span)
	if !ok {
		return
	}
	if data.Err != nil {
		// The error class, not its text: a constraint message can quote a
		// value.
		span.SetStatus(codes.Error, "query failed")
	}
	span.End()
}

// describeSQL returns the sqlc query name (or the operation when there is
// none) and the operation keyword.
func describeSQL(sql string) (name, op string) {
	s := strings.TrimSpace(sql)
	if rest, ok := strings.CutPrefix(s, "-- name: "); ok {
		if i := strings.IndexAny(rest, " \n"); i > 0 {
			name = rest[:i]
		}
		if nl := strings.IndexByte(s, '\n'); nl >= 0 {
			s = strings.TrimSpace(s[nl+1:])
		}
	}
	for strings.HasPrefix(s, "--") {
		nl := strings.IndexByte(s, '\n')
		if nl < 0 {
			s = ""
			break
		}
		s = strings.TrimSpace(s[nl+1:])
	}
	op = strings.ToUpper(firstWord(s))
	if name == "" {
		name = op
	}
	return name, op
}

func firstWord(s string) string {
	if i := strings.IndexAny(s, " \n\t("); i > 0 {
		return s[:i]
	}
	return s
}
