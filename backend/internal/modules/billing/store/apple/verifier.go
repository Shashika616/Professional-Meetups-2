// Package apple verifies App Store purchases and notifications.
//
// A purchase is verified twice over: the StoreKit 2 signed transaction the
// app sends must verify against Apple's root (jws.go), and Apple's own copy,
// fetched from the App Store Server API by transaction id, must verify too.
// The second step is what needs credentials (an App Store Connect API key),
// and it is what catches a refunded or revoked transaction the app still
// has a signed copy of. Without the key the verifier is not built at all
// and purchases fail closed (store.Unconfigured).
package apple

import (
	"context"
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"professional-meetups-monolith/backend/internal/modules/billing/store"
)

// The App Store Server API hosts. Hard-coded (plan 29 §5, API7): the
// environment a transaction claims only picks between these two.
const (
	productionHost = "api.storekit.itunes.apple.com"
	sandboxHost    = "api.storekit-sandbox.itunes.apple.com"
)

// Config is the App Store Connect API key and the app it is for.
type Config struct {
	BundleID string
	IssuerID string
	KeyID    string
	// PrivateKeyPEM is the downloaded .p8 key (PKCS #8, P-256).
	PrivateKeyPEM []byte
}

// Verifier implements store.Verifier for the App Store.
type Verifier struct {
	cfg    Config
	key    *ecdsa.PrivateKey
	roots  *x509.CertPool
	client *http.Client

	mu        sync.Mutex
	bearer    string
	bearerExp time.Time
}

var _ store.Verifier = (*Verifier)(nil)

// New builds the verifier, refusing an incomplete or unreadable key.
func New(cfg Config, roots *x509.CertPool) (*Verifier, error) {
	if cfg.BundleID == "" || cfg.IssuerID == "" || cfg.KeyID == "" || len(cfg.PrivateKeyPEM) == 0 {
		return nil, errors.New("apple: bundle id, issuer id, key id and private key are all required")
	}
	block, _ := pem.Decode(cfg.PrivateKeyPEM)
	if block == nil {
		return nil, errors.New("apple: the App Store Connect private key is not PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("apple: parse the App Store Connect private key: %w", err)
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("apple: the App Store Connect private key is not an EC key")
	}
	return &Verifier{cfg: cfg, key: key, roots: roots, client: &http.Client{Timeout: 10 * time.Second}}, nil
}

// transaction is the subset of Apple's JWSTransactionDecodedPayload billing
// uses. Nothing in it is personal: appAccountToken is the UUIDv5 the app
// set, not an identity.
type transaction struct {
	TransactionID         string `json:"transactionId"`
	OriginalTransactionID string `json:"originalTransactionId"`
	BundleID              string `json:"bundleId"`
	ProductID             string `json:"productId"`
	Type                  string `json:"type"`
	PurchaseDate          int64  `json:"purchaseDate"`
	ExpiresDate           int64  `json:"expiresDate,omitempty"`
	Quantity              int    `json:"quantity"`
	AppAccountToken       string `json:"appAccountToken,omitempty"`
	Environment           string `json:"environment"`
	RevocationDate        int64  `json:"revocationDate,omitempty"`
	RevocationReason      *int   `json:"revocationReason,omitempty"`
	InAppOwnershipType    string `json:"inAppOwnershipType,omitempty"`
	SignedDate            int64  `json:"signedDate,omitempty"`
}

// ParseTransaction verifies a signed transaction (from the app or inside a
// notification) and turns it into a store.Transaction.
func ParseTransaction(signed string, roots *x509.CertPool) (store.Transaction, error) {
	t, err := Decode[transaction](signed, roots)
	if err != nil {
		return store.Transaction{}, fmt.Errorf("%w: %w", store.ErrRejected, err)
	}
	return t.toStore()
}

func (t transaction) toStore() (store.Transaction, error) {
	if t.TransactionID == "" || t.ProductID == "" {
		return store.Transaction{}, fmt.Errorf("%w: apple transaction without an id or product", store.ErrRejected)
	}
	raw, err := json.Marshal(t)
	if err != nil {
		return store.Transaction{}, err
	}
	out := store.Transaction{
		Platform:              store.IOS,
		TransactionID:         t.TransactionID,
		OriginalTransactionID: t.OriginalTransactionID,
		ProductID:             t.ProductID,
		AppID:                 t.BundleID,
		Environment:           environment(t.Environment),
		AccountToken:          strings.ToLower(t.AppAccountToken),
		PurchasedAt:           time.UnixMilli(t.PurchaseDate).UTC(),
		AutoRenew:             t.Type == "Auto-Renewable Subscription",
		Revoked:               t.RevocationDate > 0,
		Raw:                   raw,
	}
	if out.OriginalTransactionID == "" {
		out.OriginalTransactionID = t.TransactionID
	}
	if t.ExpiresDate > 0 {
		e := time.UnixMilli(t.ExpiresDate).UTC()
		out.ExpiresAt = &e
	}
	return out, nil
}

// environment maps Apple's names. Anything not Production (Sandbox, Xcode,
// LocalTesting) is a sandbox purchase.
func environment(s string) store.Environment {
	if s == "Production" {
		return store.Production
	}
	return store.Sandbox
}

// Verify checks the app's signed transaction, then Apple's own copy.
func (v *Verifier) Verify(ctx context.Context, req store.Request) (store.Transaction, error) {
	claimed, err := ParseTransaction(req.Token, v.roots)
	if err != nil {
		return store.Transaction{}, err
	}
	signed, err := v.fetch(ctx, claimed.Environment, claimed.TransactionID)
	if err != nil {
		return store.Transaction{}, err
	}
	tx, err := ParseTransaction(signed, v.roots)
	if err != nil {
		return store.Transaction{}, err
	}
	if tx.TransactionID != claimed.TransactionID {
		return store.Transaction{}, fmt.Errorf("%w: apple returned a different transaction", store.ErrRejected)
	}
	return tx, nil
}

// fetch is GET /inApps/v1/transactions/{transactionId}.
func (v *Verifier) fetch(ctx context.Context, env store.Environment, transactionID string) (string, error) {
	host := productionHost
	if env == store.Sandbox {
		host = sandboxHost
	}
	bearer, err := v.token()
	if err != nil {
		return "", fmt.Errorf("%w: %w", store.ErrNotConfigured, err)
	}
	endpoint := "https://" + host + "/inApps/v1/transactions/" + url.PathEscape(transactionID)
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return "", err
	}
	httpReq.Header.Set("Authorization", "Bearer "+bearer)
	resp, err := v.client.Do(httpReq)
	if err != nil {
		// Without the URL: it is noise in a log, and the same rule as
		// Google's, whose URLs carry the purchase token.
		var ue *url.Error
		if errors.As(err, &ue) {
			err = ue.Err
		}
		return "", fmt.Errorf("%w: apple: %w", store.ErrUnavailable, err)
	}
	defer func() { _ = resp.Body.Close() }()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return "", fmt.Errorf("%w: apple: read response: %w", store.ErrUnavailable, err)
	}
	switch resp.StatusCode {
	case http.StatusOK:
	case http.StatusNotFound, http.StatusBadRequest:
		return "", fmt.Errorf("%w: apple has no such transaction (status %d)", store.ErrRejected, resp.StatusCode)
	default:
		// 401 (a bad or revoked key), 429 and 5xx: our side or theirs,
		// never the purchaser's fault. The body is not logged: it can
		// echo the request.
		return "", fmt.Errorf("%w: apple returned status %d", store.ErrUnavailable, resp.StatusCode)
	}
	var parsed struct {
		SignedTransactionInfo string `json:"signedTransactionInfo"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil || parsed.SignedTransactionInfo == "" {
		return "", fmt.Errorf("%w: apple response has no signed transaction", store.ErrUnavailable)
	}
	return parsed.SignedTransactionInfo, nil
}

// token is the App Store Server API bearer: an ES256 JWT signed with the
// App Store Connect key, reused until shortly before it expires.
func (v *Verifier) token() (string, error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	now := time.Now()
	if v.bearer != "" && now.Before(v.bearerExp.Add(-time.Minute)) {
		return v.bearer, nil
	}
	exp := now.Add(20 * time.Minute)
	t := jwt.NewWithClaims(jwt.SigningMethodES256, jwt.MapClaims{
		"iss": v.cfg.IssuerID,
		"iat": now.Unix(),
		"exp": exp.Unix(),
		"aud": "appstoreconnect-v1",
		"bid": v.cfg.BundleID,
	})
	t.Header["kid"] = v.cfg.KeyID
	signed, err := t.SignedString(v.key)
	if err != nil {
		return "", fmt.Errorf("apple: sign the API token: %w", err)
	}
	v.bearer, v.bearerExp = signed, exp
	return signed, nil
}
