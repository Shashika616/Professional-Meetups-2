package main

import (
	"context"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"log/slog"

	"professional-meetups-monolith/backend/internal/modules/billing"
	billingconfig "professional-meetups-monolith/backend/internal/modules/billing/config"
	"professional-meetups-monolith/backend/internal/modules/billing/store"
	"professional-meetups-monolith/backend/internal/modules/billing/store/apple"
	"professional-meetups-monolith/backend/internal/modules/billing/store/fake"
	"professional-meetups-monolith/backend/internal/modules/billing/store/google"
	meetuprepo "professional-meetups-monolith/backend/internal/modules/meetup/repository"
)

// billingStore builds the stores billing verifies purchases with (plan 29B).
//
// FAIL CLOSED: a platform without credentials gets store.Unconfigured, so
// its purchases are 503 with a log line, never trusted. A credential that is
// set but unreadable is treated the same way rather than stopping the whole
// monolith: hosting and every other route keep working, and the log says
// what to fix. The fake store is only reachable off Cloud Run;
// billingconfig.Load refuses BILLING_STORE=fake when K_SERVICE is set.
func billingStore(cfg billingconfig.Config, roots *x509.CertPool, logger *slog.Logger) billing.Store {
	if cfg.Store == billingconfig.StoreFake {
		logger.Warn("billing: BILLING_STORE=fake: every purchase token is believed. Local runs only.")
		return &fake.Store{}
	}
	var stores store.ByPlatform
	if cfg.AppleConfigured() {
		v, err := apple.New(apple.Config{
			BundleID: cfg.AppleBundleID, IssuerID: cfg.AppleIssuerID, KeyID: cfg.AppleKeyID,
			PrivateKeyPEM: []byte(cfg.ApplePrivateKey),
		}, roots)
		if err != nil {
			logger.Error("billing: the App Store Connect key is unusable; iOS purchases fail closed (503)", "error", err)
		} else {
			stores.Apple = store.NewResilient(v, nil)
		}
	} else {
		logger.Warn("billing: APPLE_APP_STORE_ISSUER_ID / _KEY_ID / _PRIVATE_KEY not set; iOS purchases fail closed (503)")
	}
	if cfg.GoogleConfigured() {
		v, err := google.New([]byte(cfg.GoogleServiceAccountJSON), cfg.GooglePackageName)
		if err != nil {
			logger.Error("billing: the Google Play service account is unusable; Android purchases fail closed (503)", "error", err)
		} else {
			r := store.NewResilient(v, v)
			stores.Google, stores.GoogleFinisher = r, r
		}
	} else {
		logger.Warn("billing: GOOGLE_PLAY_SERVICE_ACCOUNT_JSON not set; Android purchases fail closed (503)")
	}
	return stores
}

// googlePush builds the RTDN push verifier, or nil (every Google webhook
// refused with 503) when the push audience is not set. Returning a nil
// interface, not a nil *OIDCVerifier, is what makes billing see "absent".
func googlePush(cfg billingconfig.Config, logger *slog.Logger) billing.PushVerifier {
	if cfg.GooglePushAudience == "" {
		logger.Warn("billing: GOOGLE_PUBSUB_PUSH_AUDIENCE not set; Google notifications are refused (503)")
		return nil
	}
	// Security review 2026-11-01, S-1: the audience alone does not prove
	// the push came from our subscription (anyone can aim a subscription
	// at our URL with our audience), so production also requires the
	// subscription's service account.
	if cfg.Production && cfg.GooglePushServiceAccount == "" {
		logger.Warn("billing: GOOGLE_PUBSUB_PUSH_SERVICE_ACCOUNT not set; Google notifications are refused (503)")
		return nil
	}
	return &google.OIDCVerifier{Audience: cfg.GooglePushAudience, ServiceAccount: cfg.GooglePushServiceAccount}
}

// subscriptionCacheConsumer carries billing's subscription.activated and
// subscription.deactivated to the meetup module's read model (billing ->
// meetup). Through billing's outbox, so a change is retried until it lands:
// the in-process bus these used to be wired to is lossy, and nothing ever
// published on it (plan 29 §0).
func subscriptionCacheConsumer(cache meetuprepo.SubscriptionCacheRepository) billing.OutboxConsumer {
	return func(ctx context.Context, e billing.OutboxEvent) error {
		var entitled bool
		switch e.Topic {
		case billing.TopicSubscriptionActivated:
			entitled = true
		case billing.TopicSubscriptionDeactivated:
		default:
			return nil
		}
		var p billing.SubscriptionEvent
		if err := json.Unmarshal(e.Payload, &p); err != nil {
			return fmt.Errorf("subscription cache: decode %s: %w", e.Topic, err)
		}
		_, err := cache.Upsert(ctx, p.UserID, p.PlanCode, entitled, p.OccurredAt)
		return err
	}
}
