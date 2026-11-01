package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"testing"
	"time"

	"professional-meetups-monolith/backend/internal/modules/billing"
	billingconfig "professional-meetups-monolith/backend/internal/modules/billing/config"
	"professional-meetups-monolith/backend/internal/modules/billing/store"
	"professional-meetups-monolith/backend/internal/modules/billing/store/fake"
)

// On Cloud Run with no store credentials, both platforms fail closed: the
// verifier answers ErrNotConfigured (billing's 503), never a transaction.
func TestStoresFailClosedWithoutCredentialsOnCloudRun(t *testing.T) {
	cfg, err := billingconfig.LoadFrom(func(k string) string {
		return map[string]string{"K_SERVICE": "monolith"}[k]
	})
	if err != nil {
		t.Fatal(err)
	}
	st := billingStore(cfg, nil, slog.New(slog.DiscardHandler))
	if _, ok := st.(*fake.Store); ok {
		t.Fatal("production wiring chose the fake store")
	}
	for _, p := range []store.Platform{store.IOS, store.Android} {
		if _, err := st.Verify(context.Background(), store.Request{Platform: p, ProductID: "credits_50", Token: "t"}); !errors.Is(err, store.ErrNotConfigured) {
			t.Fatalf("%s without credentials: %v, want ErrNotConfigured", p, err)
		}
	}
	if googlePush(cfg, slog.New(slog.DiscardHandler)) != nil {
		t.Fatal("a Google push verifier was built with no audience")
	}
	// An unusable key is treated as missing, not trusted.
	cfg.AppleIssuerID, cfg.AppleKeyID, cfg.ApplePrivateKey = "i", "k", "not a key"
	st = billingStore(cfg, nil, slog.New(slog.DiscardHandler))
	if _, err := st.Verify(context.Background(), store.Request{Platform: store.IOS, Token: "t"}); !errors.Is(err, store.ErrNotConfigured) {
		t.Fatalf("ios with an unusable key: %v", err)
	}
}

type recordingCache struct {
	user     string
	entitled bool
	calls    int
}

func (r *recordingCache) Upsert(_ context.Context, userID, _ string, entitled bool, _ time.Time) (bool, error) {
	r.user, r.entitled = userID, entitled
	r.calls++
	return true, nil
}

func (r *recordingCache) IsEntitled(context.Context, string) (bool, error) { return r.entitled, nil }

func TestSubscriptionEventsReachTheMeetupCache(t *testing.T) {
	cache := &recordingCache{}
	consume := subscriptionCacheConsumer(cache)
	payload, _ := json.Marshal(billing.SubscriptionEvent{UserID: "u-1", PlanCode: "pro", Status: "active", OccurredAt: time.Now()})
	if err := consume(context.Background(), billing.OutboxEvent{Topic: billing.TopicSubscriptionActivated, Payload: payload}); err != nil {
		t.Fatal(err)
	}
	if cache.user != "u-1" || !cache.entitled {
		t.Fatalf("activated: %+v", cache)
	}
	if err := consume(context.Background(), billing.OutboxEvent{Topic: billing.TopicSubscriptionDeactivated, Payload: payload}); err != nil || cache.entitled {
		t.Fatalf("deactivated: %+v, %v", cache, err)
	}
	if err := consume(context.Background(), billing.OutboxEvent{Topic: "credits.changed", Payload: payload}); err != nil || cache.calls != 2 {
		t.Fatalf("an unrelated topic reached the cache: %+v, %v", cache, err)
	}
}

// Security review 2026-11-01, S-1: in production the push token must come
// from our own push subscription's service account. Audience alone is not
// enough: anyone can create a Pub/Sub push subscription aimed at our URL
// with our audience and their own account, and Google signs its token.
func TestProductionGooglePushRequiresTheServiceAccount(t *testing.T) {
	cfg := billingconfig.Config{Production: true, GooglePushAudience: "https://api.example/v1/billing/webhooks/google"}
	if googlePush(cfg, slog.New(slog.DiscardHandler)) != nil {
		t.Error("production accepted Google pushes with no service account to check")
	}
	cfg.GooglePushServiceAccount = "rtdn-push@project.iam.gserviceaccount.com"
	if googlePush(cfg, slog.New(slog.DiscardHandler)) == nil {
		t.Error("production refused a fully configured push verifier")
	}
	// Locally the audience alone is enough (emulators, manual tests).
	if googlePush(billingconfig.Config{GooglePushAudience: "aud"}, slog.New(slog.DiscardHandler)) == nil {
		t.Error("local runs need only the audience")
	}
}
