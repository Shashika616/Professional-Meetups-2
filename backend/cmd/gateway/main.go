// Command gateway wires up and runs the gateway's HTTP server. This file is
// wiring only: load config, construct dependencies, start serving, handle
// SIGTERM gracefully. Route logic lives in internal/gateway/handlers.
//
// Ported from ../Professional-Meetups/backend/services/gateway/cmd/server.
// Three differences, all from ADR-001: one gRPC client instead of three (§1),
// no Redis client at all (§5), and a jwt.Signer alongside the jwt.Verifier
// (§6) — this process now issues the tokens it also verifies.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"professional-meetups-monolith/backend/internal/gateway/config"
	"professional-meetups-monolith/backend/internal/gateway/handlers"
	"professional-meetups-monolith/backend/internal/gateway/middleware"
	"professional-meetups-monolith/backend/internal/gateway/monolithclient"
	"professional-meetups-monolith/backend/internal/platform/jwt"
	"professional-meetups-monolith/backend/internal/platform/logging"
	"professional-meetups-monolith/backend/internal/platform/ratelimit"
)

// shutdownTimeout bounds how long graceful shutdown waits for in-flight
// requests to finish before forcing a close.
const shutdownTimeout = 10 * time.Second

func main() {
	logger := logging.New()
	slog.SetDefault(logger)

	if err := run(logger); err != nil {
		logger.Error("gateway exited with error", "error", err)
		os.Exit(1)
	}
}

func run(logger *slog.Logger) error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	cfg, err := config.Load()
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}

	monolith, err := monolithclient.New(cfg.MonolithAddr)
	if err != nil {
		return fmt.Errorf("connect to monolith: %w", err)
	}
	defer func() {
		if err := monolith.Close(); err != nil {
			logger.Error("closing monolith client", "error", err)
		}
	}()

	// Both halves of the keypair now (ADR-001 §6). Either failing to load is
	// a startup crash, not a first-request surprise — the same discipline
	// every other required config value gets.
	signer, err := jwt.NewSigner(cfg.JWTPrivateKeyPath)
	if err != nil {
		return fmt.Errorf("load jwt signing key: %w", err)
	}
	verifier, err := jwt.NewVerifier(cfg.JWTPublicKeyPath)
	if err != nil {
		return fmt.Errorf("load jwt public key: %w", err)
	}

	// One limiter for the whole process, shared by the blanket IP+path
	// middleware and the per-user SOS limit. In-memory (ADR-001 §5) — see
	// internal/platform/ratelimit for the single-gateway-instance
	// trade-off this accepts.
	limiter := ratelimit.New()
	defer limiter.Close()

	mux := http.NewServeMux()
	handlers.New(monolith, signer, verifier,
		handlers.WithRateLimiter(limiter),
		handlers.WithLogger(logger),
	).Register(mux)

	// middleware.RateLimit keys its fixed window on (IP, route path), so
	// wrapping the whole mux gives every route its own independent
	// 20-req/min-per-IP limit, not one shared budget across all of them.
	//
	// Chain order is load-bearing and matches the source exactly: Recover
	// outermost (so it catches panics from everything beneath it), then
	// request-ID propagation, then request logging (which needs that ID),
	// then rate limiting, then the body cap.
	var handler http.Handler = mux
	handler = middleware.MaxBytes(handler)
	handler = middleware.RateLimit(limiter)(handler)
	handler = middleware.RequestLogging(logger)(handler)
	handler = logging.HTTPMiddleware(handler)
	handler = middleware.Recover(logger)(handler)

	// Go's http.Server defaults to no timeouts at all on any of these, so a
	// deliberately slow client (slow headers, slow body, slow read of the
	// response, or one that just opens a keep-alive connection and never
	// closes it) could hold a connection — and its goroutine — open
	// indefinitely. The MaxBytes body cap bounds size, not time; this is the
	// complementary fix. This gateway is REST-to-gRPC translation only, with
	// no streaming/SSE/upload endpoint, so none of these needs to be
	// unusually generous.
	server := &http.Server{
		Addr:              ":" + cfg.Port,
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	serveErrCh := make(chan error, 1)
	go func() {
		logger.Info("gateway listening", "port", cfg.Port)
		serveErrCh <- server.ListenAndServe()
	}()

	select {
	case err := <-serveErrCh:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			return fmt.Errorf("http server: %w", err)
		}
		return nil
	case <-ctx.Done():
		logger.Info("shutting down gateway")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
		defer cancel()
		if err := server.Shutdown(shutdownCtx); err != nil {
			return fmt.Errorf("graceful shutdown: %w", err)
		}
		return nil
	}
}
