// Command analyticsload drives the analytics ingest at a fixed rate and
// reports latency and drops (plan 29D). It calls the monolith's
// AnalyticsService.Ingest directly, the way the gateway does, so the
// gateway's per-IP limit does not cap the run. Run it through
// scripts/analytics-load.sh, which starts a working-tree monolith against
// the local test database; never point it at production.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	"professional-meetups-monolith/backend/internal/platform/internalauth"
	analyticsv1 "professional-meetups-monolith/backend/internal/proto/analytics/v1"
)

func main() {
	addr := flag.String("addr", "localhost:9191", "the monolith's gRPC address")
	rate := flag.Int("rate", 200, "batches per second")
	duration := flag.Duration("duration", 60*time.Second, "how long to send")
	events := flag.Int("events", 10, "events per batch (at most 50)")
	workers := flag.Int("workers", 128, "concurrent requests")
	flag.Parse()

	secret := os.Getenv("INTERNAL_GRPC_SHARED_SECRET")
	if secret == "" {
		log.Fatal("analyticsload: INTERNAL_GRPC_SHARED_SECRET is not set")
	}
	conn, err := grpc.NewClient(*addr,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithChainUnaryInterceptor(internalauth.UnaryClientInterceptor(secret)))
	if err != nil {
		log.Fatalf("analyticsload: %v", err)
	}
	defer func() { _ = conn.Close() }()
	client := analyticsv1.NewAnalyticsServiceClient(conn)

	var (
		mu                      sync.Mutex
		latencies               []time.Duration
		accepted, dropped, errs atomic.Int64
		skipped                 atomic.Int64
	)
	jobs := make(chan struct{}, *workers)
	var wg sync.WaitGroup
	for i := 0; i < *workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			// Each worker is one install, signed in as one of a few
			// synthetic users, so the user_key path is exercised too.
			install := uuid.NewString()
			user := ""
			if i%2 == 0 {
				user = uuid.NewString()
			}
			for range jobs {
				req := batch(install, user, *events)
				ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				start := time.Now()
				resp, err := client.Ingest(ctx, req)
				d := time.Since(start)
				cancel()
				if err != nil {
					errs.Add(1)
					continue
				}
				accepted.Add(int64(resp.GetAccepted()))
				dropped.Add(int64(resp.GetDropped()))
				mu.Lock()
				latencies = append(latencies, d)
				mu.Unlock()
			}
		}()
	}

	interval := time.Second / time.Duration(*rate)
	ticker := time.NewTicker(interval)
	deadline := time.Now().Add(*duration)
	sent := 0
	for now := range ticker.C {
		if now.After(deadline) {
			break
		}
		select {
		case jobs <- struct{}{}:
			sent++
		default:
			// Every worker busy: the server is behind. Counted, not queued,
			// so the offered rate stays honest.
			skipped.Add(1)
		}
	}
	ticker.Stop()
	close(jobs)
	wg.Wait()

	sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })
	pct := func(p float64) time.Duration {
		if len(latencies) == 0 {
			return 0
		}
		return latencies[int(float64(len(latencies)-1)*p)]
	}
	out, _ := json.MarshalIndent(map[string]any{
		"target_batches_per_second": *rate,
		"duration_seconds":          duration.Seconds(),
		"events_per_batch":          *events,
		"batches_sent":              sent,
		"batches_skipped_client":    skipped.Load(),
		"batches_failed":            errs.Load(),
		"events_accepted":           accepted.Load(),
		"events_dropped":            dropped.Load(),
		"latency_ms": map[string]float64{
			"p50": ms(pct(0.50)), "p95": ms(pct(0.95)), "p99": ms(pct(0.99)), "max": ms(pct(1)),
		},
	}, "", "  ")
	fmt.Println(string(out))
}

func ms(d time.Duration) float64 { return float64(d.Microseconds()) / 1000 }

var screens = []string{"home", "events", "meetup_detail", "profile", "credits", "schedule_meetup"}

func batch(install, user string, n int) *analyticsv1.IngestRequest {
	now := time.Now().UTC()
	session := uuid.NewString()
	req := &analyticsv1.IngestRequest{
		UserId: user, InstallId: install, AppVersion: "1.1.0+7", OsName: "android",
		OsVersion: "15", DeviceClass: "phone", Locale: "en-LK",
	}
	for i := 0; i < n; i++ {
		id, _ := uuid.NewV7()
		name, attrs := "screen_viewed", []byte(`{}`)
		if i%2 == 1 {
			name, attrs = "screen_left", []byte(fmt.Sprintf(`{"duration_ms": %d}`, 500+i*137))
		}
		req.Events = append(req.Events, &analyticsv1.Event{
			EventId: id.String(), EventName: name, SchemaVersion: 1,
			OccurredAt: now.Add(-time.Duration(n-i) * time.Second).Format(time.RFC3339Nano),
			SessionId:  session, Screen: screens[i%len(screens)], AttributesJson: attrs,
		})
	}
	return req
}
