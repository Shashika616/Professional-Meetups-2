// Package google verifies Google Play purchases, finishes them
// (acknowledge or consume), and authenticates RTDN push requests.
//
// Ported from the source's verify.googleVerifier: the same service-account
// JWT bearer grant and Play Developer API v3 calls, extended with one-time
// products (credit packs), the account binding, acknowledge and consume,
// and a cached access token. There is no credential-free path: a purchase
// token is opaque and only Google can say what it is.
package google

import (
	"context"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"professional-meetups-monolith/backend/internal/modules/billing/store"
)

// Hard-coded endpoints (plan 29 §5, API7). The service account file's own
// token_uri is ignored on purpose: a URL from configuration is still not a
// store endpoint we chose.
const (
	tokenURL      = "https://oauth2.googleapis.com/token" // #nosec G101 -- Google's token endpoint, not a credential
	publisherBase = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/"
	scope         = "https://www.googleapis.com/auth/androidpublisher"
)

// Verifier implements store.Verifier and store.Finisher for Google Play.
type Verifier struct {
	packageName string
	email       string
	key         *rsa.PrivateKey
	client      *http.Client

	mu        sync.Mutex
	bearer    string
	bearerExp time.Time
}

var (
	_ store.Verifier = (*Verifier)(nil)
	_ store.Finisher = (*Verifier)(nil)
)

// New parses the service account key file (its contents, not a path).
func New(serviceAccountJSON []byte, packageName string) (*Verifier, error) {
	if packageName == "" {
		return nil, errors.New("google: the package name is required")
	}
	var key struct {
		ClientEmail string `json:"client_email"`
		PrivateKey  string `json:"private_key"`
	}
	if err := json.Unmarshal(serviceAccountJSON, &key); err != nil {
		return nil, fmt.Errorf("google: parse the service account json: %w", err)
	}
	if key.ClientEmail == "" || key.PrivateKey == "" {
		return nil, errors.New("google: the service account json has no client_email or private_key")
	}
	block, _ := pem.Decode([]byte(key.PrivateKey))
	if block == nil {
		return nil, errors.New("google: the service account private_key is not PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("google: parse the service account private key: %w", err)
	}
	rsaKey, ok := parsed.(*rsa.PrivateKey)
	if !ok {
		return nil, errors.New("google: the service account private key is not RSA")
	}
	return &Verifier{packageName: packageName, email: key.ClientEmail, key: rsaKey,
		client: &http.Client{Timeout: 10 * time.Second}}, nil
}

// productPurchase is the subset of purchases.products.get billing keeps.
type productPurchase struct {
	OrderID                     string `json:"orderId"`
	PurchaseState               int    `json:"purchaseState"`
	ConsumptionState            int    `json:"consumptionState"`
	PurchaseTimeMillis          string `json:"purchaseTimeMillis"`
	PurchaseType                *int   `json:"purchaseType,omitempty"`
	AcknowledgementState        int    `json:"acknowledgementState"`
	ObfuscatedExternalAccountID string `json:"obfuscatedExternalAccountId"`
	Quantity                    int    `json:"quantity,omitempty"`
}

// subscriptionPurchase is the subset of purchases.subscriptions.get billing
// keeps. The full resource can carry the buyer's name and email; those are
// never decoded, so they never reach store_purchases.raw.
type subscriptionPurchase struct {
	OrderID                     string `json:"orderId"`
	StartTimeMillis             string `json:"startTimeMillis"`
	ExpiryTimeMillis            string `json:"expiryTimeMillis"`
	AutoRenewing                bool   `json:"autoRenewing"`
	PaymentState                *int   `json:"paymentState,omitempty"`
	CancelReason                *int   `json:"cancelReason,omitempty"`
	PurchaseType                *int   `json:"purchaseType,omitempty"`
	AcknowledgementState        int    `json:"acknowledgementState"`
	ObfuscatedExternalAccountID string `json:"obfuscatedExternalAccountId"`
}

// Verify asks the Play Developer API about the token.
func (v *Verifier) Verify(ctx context.Context, req store.Request) (store.Transaction, error) {
	if req.Token == "" || req.ProductID == "" {
		return store.Transaction{}, store.ErrRejected
	}
	hash := store.HashToken(req.Token)
	if req.Kind == store.Subscription {
		var p subscriptionPurchase
		if err := v.get(ctx, "purchases/subscriptions/"+url.PathEscape(req.ProductID)+"/tokens/"+url.PathEscape(req.Token), &p); err != nil {
			return store.Transaction{}, err
		}
		return subscriptionTransaction(p, req.ProductID, v.packageName, hash)
	}
	var p productPurchase
	if err := v.get(ctx, "purchases/products/"+url.PathEscape(req.ProductID)+"/tokens/"+url.PathEscape(req.Token), &p); err != nil {
		return store.Transaction{}, err
	}
	return productTransaction(p, req.ProductID, v.packageName, hash)
}

func productTransaction(p productPurchase, productID, packageName, hash string) (store.Transaction, error) {
	raw, err := json.Marshal(p)
	if err != nil {
		return store.Transaction{}, err
	}
	tx := store.Transaction{
		Platform:              store.Android,
		TransactionID:         orHash(p.OrderID, hash),
		OriginalTransactionID: hash,
		ProductID:             productID,
		// The URL is scoped to our package: a token from another app is a
		// 404, so a 200 means the purchase is ours.
		AppID:        packageName,
		Environment:  googleEnvironment(p.PurchaseType),
		AccountToken: strings.ToLower(p.ObfuscatedExternalAccountID),
		PurchasedAt:  millis(p.PurchaseTimeMillis),
		Revoked:      p.PurchaseState == 1,
		Pending:      p.PurchaseState == 2,
		TokenHash:    hash,
		Raw:          raw,
	}
	return tx, nil
}

func subscriptionTransaction(p subscriptionPurchase, productID, packageName, hash string) (store.Transaction, error) {
	raw, err := json.Marshal(p)
	if err != nil {
		return store.Transaction{}, err
	}
	tx := store.Transaction{
		Platform:              store.Android,
		TransactionID:         orHash(p.OrderID, hash),
		OriginalTransactionID: hash,
		ProductID:             productID,
		AppID:                 packageName,
		Environment:           googleEnvironment(p.PurchaseType),
		AccountToken:          strings.ToLower(p.ObfuscatedExternalAccountID),
		PurchasedAt:           millis(p.StartTimeMillis),
		AutoRenew:             p.AutoRenewing,
		// paymentState 0 is "payment pending".
		Pending:   p.PaymentState != nil && *p.PaymentState == 0,
		TokenHash: hash,
		Raw:       raw,
	}
	if p.ExpiryTimeMillis != "" {
		e := millis(p.ExpiryTimeMillis)
		tx.ExpiresAt = &e
	}
	return tx, nil
}

// googleEnvironment: purchaseType 0 is a license-test purchase. Absent is a
// real one.
func googleEnvironment(purchaseType *int) store.Environment {
	if purchaseType != nil && *purchaseType == 0 {
		return store.Sandbox
	}
	return store.Production
}

func orHash(orderID, hash string) string {
	if orderID != "" {
		return orderID
	}
	return "token:" + hash
}

func millis(s string) time.Time {
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil || n <= 0 {
		return time.Time{}
	}
	return time.UnixMilli(n).UTC()
}

// Finish consumes a one-time product or acknowledges a subscription. A
// purchase already consumed or acknowledged counts as done: when Google
// refuses the call, the purchase is read back and its own state decides,
// rather than the wording of Google's error.
func (v *Verifier) Finish(ctx context.Context, _ store.Platform, kind store.Kind, productID, token string) error {
	base := "purchases/products/" + url.PathEscape(productID) + "/tokens/" + url.PathEscape(token)
	action := ":consume"
	if kind == store.Subscription {
		base = "purchases/subscriptions/" + url.PathEscape(productID) + "/tokens/" + url.PathEscape(token)
		action = ":acknowledge"
	}
	err := v.post(ctx, base+action)
	if err == nil || errors.Is(err, errAlreadyDone) {
		return nil
	}
	if !errors.Is(err, store.ErrRejected) {
		return err
	}
	var state struct {
		ConsumptionState     int `json:"consumptionState"`
		AcknowledgementState int `json:"acknowledgementState"`
	}
	if getErr := v.get(ctx, base, &state); getErr != nil {
		return err
	}
	if (kind == store.Subscription && state.AcknowledgementState == 1) || (kind != store.Subscription && state.ConsumptionState == 1) {
		return nil
	}
	return err
}

// withoutURL drops the request URL from a transport error. The purchase
// token is in the URL's path, and these errors are logged.
func withoutURL(err error) error {
	var ue *url.Error
	if errors.As(err, &ue) {
		return ue.Err
	}
	return err
}

var errAlreadyDone = errors.New("google: already consumed or acknowledged")

func (v *Verifier) get(ctx context.Context, path string, out any) error {
	body, status, err := v.do(ctx, http.MethodGet, path)
	if err != nil {
		return err
	}
	if status != http.StatusOK {
		return statusError(status)
	}
	if err := json.Unmarshal(body, out); err != nil {
		return fmt.Errorf("%w: google: decode response: %w", store.ErrUnavailable, err)
	}
	return nil
}

func (v *Verifier) post(ctx context.Context, path string) error {
	body, status, err := v.do(ctx, http.MethodPost, path)
	if err != nil {
		return err
	}
	if status == http.StatusOK || status == http.StatusNoContent {
		return nil
	}
	// Google answers 400 for a purchase already consumed or acknowledged.
	if status == http.StatusBadRequest && strings.Contains(string(body), "already") {
		return errAlreadyDone
	}
	return statusError(status)
}

// statusError classifies a Play Developer API status. The body is never
// part of the error: it can echo the token.
func statusError(status int) error {
	switch status {
	case http.StatusNotFound, http.StatusBadRequest, http.StatusGone:
		return fmt.Errorf("%w: google has no such purchase (status %d)", store.ErrRejected, status)
	default:
		return fmt.Errorf("%w: google returned status %d", store.ErrUnavailable, status)
	}
}

func (v *Verifier) do(ctx context.Context, method, path string) ([]byte, int, error) {
	bearer, err := v.accessToken(ctx)
	if err != nil {
		return nil, 0, err
	}
	req, err := http.NewRequestWithContext(ctx, method, publisherBase+url.PathEscape(v.packageName)+"/"+path, nil)
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Authorization", "Bearer "+bearer)
	resp, err := v.client.Do(req)
	if err != nil {
		return nil, 0, fmt.Errorf("%w: google: %w", store.ErrUnavailable, withoutURL(err))
	}
	defer func() { _ = resp.Body.Close() }()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, 0, fmt.Errorf("%w: google: read response: %w", store.ErrUnavailable, err)
	}
	return body, resp.StatusCode, nil
}

// accessToken exchanges a self-signed JWT assertion for an access token
// (RFC 7523) and reuses it until shortly before it expires.
func (v *Verifier) accessToken(ctx context.Context) (string, error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	now := time.Now()
	if v.bearer != "" && now.Before(v.bearerExp.Add(-time.Minute)) {
		return v.bearer, nil
	}
	assertion, err := jwt.NewWithClaims(jwt.SigningMethodRS256, jwt.MapClaims{
		"iss": v.email, "scope": scope, "aud": tokenURL,
		"iat": now.Unix(), "exp": now.Add(time.Hour).Unix(),
	}).SignedString(v.key)
	if err != nil {
		return "", fmt.Errorf("%w: google: sign the token assertion: %w", store.ErrNotConfigured, err)
	}
	form := url.Values{"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"}, "assertion": {assertion}}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, tokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := v.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("%w: google token: %w", store.ErrUnavailable, withoutURL(err))
	}
	defer func() { _ = resp.Body.Close() }()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	if err != nil {
		return "", fmt.Errorf("%w: google token: %w", store.ErrUnavailable, err)
	}
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("%w: google token endpoint returned status %d", store.ErrUnavailable, resp.StatusCode)
	}
	var parsed struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int64  `json:"expires_in"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil || parsed.AccessToken == "" {
		return "", fmt.Errorf("%w: google token response has no access_token", store.ErrUnavailable)
	}
	if parsed.ExpiresIn <= 0 {
		parsed.ExpiresIn = 3600
	}
	v.bearer, v.bearerExp = parsed.AccessToken, now.Add(time.Duration(parsed.ExpiresIn)*time.Second)
	return v.bearer, nil
}
