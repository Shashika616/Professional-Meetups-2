// Package fake is a store for local runs and tests: the "token" is a JSON
// description of the transaction, and it is believed.
//
// That is exactly why it must never run in production. The only way to
// select it is BILLING_STORE=fake, and cmd/monolith refuses to start with
// that set on Cloud Run (K_SERVICE), the same guard as the OTP bypass.
package fake

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"time"

	"professional-meetups-monolith/backend/internal/modules/billing/store"
)

// Token is what a fake purchase token decodes to.
type Token struct {
	TransactionID string `json:"transaction_id"`
	// OriginalTransactionID defaults to TransactionID on iOS and to the
	// token hash on Android, as the real stores do.
	OriginalTransactionID string `json:"original_transaction_id,omitempty"`
	ProductID             string `json:"product_id"`
	AppID                 string `json:"app_id"`
	// Environment defaults to sandbox.
	Environment  store.Environment `json:"environment,omitempty"`
	AccountToken string            `json:"account_token"`
	ExpiresAt    *time.Time        `json:"expires_at,omitempty"`
	Revoked      bool              `json:"revoked,omitempty"`
	Pending      bool              `json:"pending,omitempty"`
}

// Encode makes a fake token.
func Encode(t Token) string {
	b, _ := json.Marshal(t)
	return string(b)
}

// Store is the fake verifier and finisher.
type Store struct {
	mu       sync.Mutex
	finished []string
}

var (
	_ store.Verifier = (*Store)(nil)
	_ store.Finisher = (*Store)(nil)
)

// Verify decodes the token. A token that is not a fake token is rejected.
func (s *Store) Verify(_ context.Context, req store.Request) (store.Transaction, error) {
	var t Token
	if err := json.Unmarshal([]byte(req.Token), &t); err != nil || t.TransactionID == "" {
		return store.Transaction{}, fmt.Errorf("%w: not a fake token", store.ErrRejected)
	}
	env := t.Environment
	if env == "" {
		env = store.Sandbox
	}
	tx := store.Transaction{
		Platform: req.Platform, TransactionID: t.TransactionID, OriginalTransactionID: t.OriginalTransactionID,
		ProductID: t.ProductID, AppID: t.AppID, Environment: env, AccountToken: strings.ToLower(t.AccountToken),
		PurchasedAt: time.Now().UTC(), ExpiresAt: t.ExpiresAt, AutoRenew: req.Kind == store.Subscription,
		Revoked: t.Revoked, Pending: t.Pending, Raw: json.RawMessage(`{"fake":true}`),
	}
	if req.Platform == store.Android {
		// As Google: the token hash is the purchase's lasting identity.
		tx.TokenHash = store.HashToken(req.Token)
		if tx.OriginalTransactionID == "" {
			tx.OriginalTransactionID = tx.TokenHash
		}
	}
	if tx.OriginalTransactionID == "" {
		tx.OriginalTransactionID = tx.TransactionID
	}
	return tx, nil
}

// Finish records the call.
func (s *Store) Finish(_ context.Context, platform store.Platform, kind store.Kind, productID, _ string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.finished = append(s.finished, fmt.Sprintf("%s/%s/%s", platform, kind, productID))
	return nil
}

// Finished lists every Finish so far, for tests.
func (s *Store) Finished() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.finished...)
}
