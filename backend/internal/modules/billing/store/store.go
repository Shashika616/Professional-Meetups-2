// Package store is the billing module's boundary with Apple and Google
// (plan 29 §3.7): verifying a purchase the app says it made, finishing it
// with the store, and authenticating the stores' webhooks.
//
// Ported from ../Professional-Meetups/backend/services/billing
// (internal/verify and internal/webhookauth, reviewed in ADR-031) and
// extended for what this app sells that the source did not: consumable
// credit packs, the account binding, and the environment. The adapters are
// apple, google and fake; billing only ever sees this package's types.
//
// # NEVER TRUST THE CLIENT
//
// A Transaction comes only from the store's own signed or authenticated
// answer. A missing credential is ErrNotConfigured, never a guess, and the
// caller turns it into 503 (fail closed).
package store

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"time"
)

// Platform is which store sold it.
type Platform string

const (
	IOS     Platform = "ios"
	Android Platform = "android"
)

// Kind is what was sold. The catalog decides it, not the store's answer.
type Kind string

const (
	Consumable   Kind = "consumable"
	Subscription Kind = "subscription"
)

// Environment is the store environment the purchase was made in.
type Environment string

const (
	Production Environment = "production"
	Sandbox    Environment = "sandbox"
)

var (
	// ErrNotConfigured means the platform's credentials are not set. Fail
	// closed: the purchase is neither trusted nor refused as invalid.
	ErrNotConfigured = errors.New("store: verification is not configured for this platform")
	// ErrUnavailable is a transient store failure (network, 5xx, an open
	// breaker). Retrying later may succeed.
	ErrUnavailable = errors.New("store: temporarily unavailable")
	// ErrRejected means the store says this is not a genuine, valid
	// purchase of what the app claimed.
	ErrRejected = errors.New("store: purchase rejected")
)

// Request is one purchase the app asks the server to verify.
type Request struct {
	Platform  Platform
	Kind      Kind
	ProductID string
	// Token is what the store handed the app: the StoreKit 2 signed
	// transaction (JWS) on iOS, the purchase token on Android. It is a
	// credential: never logged, never stored (TokenHash is).
	Token string
}

// Transaction is a purchase as the store itself reports it.
type Transaction struct {
	Platform Platform
	// TransactionID identifies this purchase (or this subscription
	// renewal): Apple's transactionId, Google's orderId, or the token hash
	// when Google gives no orderId (some test purchases).
	TransactionID string
	// OriginalTransactionID links a subscription's renewals: Apple's
	// originalTransactionId, the token hash on Google.
	OriginalTransactionID string
	ProductID             string
	// AppID is the bundle id (Apple) or package name (Google) the purchase
	// belongs to.
	AppID       string
	Environment Environment
	// AccountToken is the appAccountToken (Apple) or obfuscated account id
	// (Google) the app set at purchase: UUIDv5 of the user id (billing
	// checks it).
	AccountToken string
	PurchasedAt  time.Time
	// ExpiresAt is a subscription's current period end.
	ExpiresAt *time.Time
	AutoRenew bool
	// Revoked is a refunded or revoked purchase; Pending one not yet paid.
	Revoked bool
	Pending bool
	// TokenHash is sha256 of the Android purchase token, for finding the
	// purchase again from a webhook. Empty on iOS.
	TokenHash string
	// Raw is the store's answer reduced to the fields above and a few more
	// for audit, with nothing personal in it (store_purchases.raw).
	Raw json.RawMessage
}

// Verifier confirms a purchase with the store that sold it.
type Verifier interface {
	Verify(ctx context.Context, req Request) (Transaction, error)
}

// Finisher tells the store a granted purchase is done with: Google's
// consume (consumables) or acknowledge (subscriptions). Unacknowledged
// Google purchases are refunded after three days.
type Finisher interface {
	Finish(ctx context.Context, platform Platform, kind Kind, productID, token string) error
}

// HashToken is the stored stand-in for a purchase token.
func HashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// Unconfigured fails every call closed. It is what a platform without
// credentials gets, never a stand-in for a configured one.
type Unconfigured struct{}

func (Unconfigured) Verify(context.Context, Request) (Transaction, error) {
	return Transaction{}, ErrNotConfigured
}

func (Unconfigured) Finish(context.Context, Platform, Kind, string, string) error {
	return ErrNotConfigured
}

// ByPlatform routes each request to its platform's verifier and finisher.
type ByPlatform struct {
	Apple, Google                 Verifier
	AppleFinisher, GoogleFinisher Finisher
}

func (b ByPlatform) Verify(ctx context.Context, req Request) (Transaction, error) {
	switch req.Platform {
	case IOS:
		return orUnconfigured(b.Apple).Verify(ctx, req)
	case Android:
		return orUnconfigured(b.Google).Verify(ctx, req)
	default:
		return Transaction{}, ErrRejected
	}
}

func (b ByPlatform) Finish(ctx context.Context, platform Platform, kind Kind, productID, token string) error {
	switch platform {
	case IOS:
		// The app finishes StoreKit transactions itself; nothing to tell
		// Apple.
		return nil
	case Android:
		if b.GoogleFinisher == nil {
			return ErrNotConfigured
		}
		return b.GoogleFinisher.Finish(ctx, platform, kind, productID, token)
	default:
		return ErrRejected
	}
}

func orUnconfigured(v Verifier) Verifier {
	if v == nil {
		return Unconfigured{}
	}
	return v
}
