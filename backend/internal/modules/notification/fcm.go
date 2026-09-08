package notification

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sync"
	"time"

	"cloud.google.com/go/auth/credentials"
	"cloud.google.com/go/auth/httptransport"
)

const (
	defaultBaseURL = "https://fcm.googleapis.com"

	// defaultTimeout is deliberately explicit — the zero-value http.Client
	// has no timeout at all, which would let a hung FCM request block a
	// poller worker indefinitely (same reasoning as the auth module's
	// linkedin and resend clients).
	defaultTimeout = 5 * time.Second

	fcmMessagingScope = "https://www.googleapis.com/auth/firebase.messaging"

	// maxConcurrentSends bounds the fan-out inside one SendToTokens call
	// (§E2b). The source sent sequentially, which is fine for the two or
	// three devices one person has, but this same code path also serves
	// rows produced by the nearby-notify fan-out. At a 5s per-call timeout,
	// a sequential worst case is 5s × token count; with a small worker pool
	// it is bounded by the batch deadline instead.
	//
	// 10 rather than something larger: these are outbound calls to a single
	// third party from a background loop, and the goal is to stop one slow
	// batch serialising, not to maximise throughput against FCM.
	maxConcurrentSends = 10

	// batchDeadline caps one SendToTokens call regardless of token count, so
	// a pathological row can never hold a poller worker open indefinitely.
	batchDeadline = 30 * time.Second
)

// ErrTokenUnregistered marks a device token that will NEVER work again — the
// app was uninstalled, the token was rotated, or it belongs to a different
// Firebase project (§E2c).
//
// This is the distinction that matters, and getting it wrong is expensive in
// one direction: treating a TRANSIENT failure (rate limiting, a 500, a
// timeout) as permanent would delete a live device and silently stop
// notifying a real user, with nothing to indicate why. So only FCM's explicit
// permanent-failure signals produce this, and everything else — including
// anything unrecognised — is treated as retryable.
var ErrTokenUnregistered = errors.New("notification: device token is permanently unregistered")

// TokenError pairs a failed token with its cause, so the caller can act on
// the specific tokens FCM rejected permanently.
//
// It carries the token because the CALLER needs it to delete the right row —
// but Error() deliberately never renders it, so a TokenError that reaches a
// log line or a wrapped error string cannot leak one.
type TokenError struct {
	Token string
	Err   error
}

func (e *TokenError) Error() string {
	// Token deliberately absent — see the type's doc comment.
	return fmt.Sprintf("notification: send to device failed: %v", e.Err)
}

func (e *TokenError) Unwrap() error { return e.Err }

// SendResult reports the per-token outcome of one SendToTokens call.
type SendResult struct {
	// Unregistered lists tokens FCM said are permanently dead. The caller
	// deletes exactly these and no others.
	Unregistered []string
	// Delivered counts tokens that succeeded.
	Delivered int
	// LastErr is the last transient failure seen, if any — what the caller
	// records as the row's last_error.
	LastErr error
}

// FCMPushSender sends real push notifications via the FCM HTTP v1 API,
// authenticated with a Firebase service account (OAuth2 JWT bearer grant via
// cloud.google.com/go/auth — the standard library for calling Google APIs
// with a service account, not hand-rolled token signing).
//
// A send failure to one token never blocks the others in the same call: the
// same fault-tolerance contract the source had, now achieved with a bounded
// worker pool instead of a sequential loop (§E2b).
type FCMPushSender struct {
	projectID  string
	httpClient *http.Client
	baseURL    string
}

// NewFCMPushSender constructs an FCMPushSender from a Firebase service
// account's JSON key bytes.
//
// The credential is consumed as RAW JSON CONTENT, not a file path — the same
// shape the source's config uses, and the shape
// FIREBASE_SERVICE_ACCOUNT_JSON already has in backend/.env.
func NewFCMPushSender(ctx context.Context, serviceAccountJSON []byte) (*FCMPushSender, error) {
	// NewCredentialsFromJSON with an explicit credentials.ServiceAccount
	// type, not DetectDefault/CredentialsFromJSON(WithParams) — both are
	// deprecated precisely because they don't validate the credential
	// configuration, which matters here since this JSON ultimately comes
	// from an operator-supplied environment variable rather than a
	// hardcoded trusted source. Asserting the expected type up front is the
	// mitigation those deprecation notices recommend.
	creds, err := credentials.NewCredentialsFromJSON(credentials.ServiceAccount, serviceAccountJSON, &credentials.DetectOptions{
		Scopes: []string{fcmMessagingScope},
	})
	if err != nil {
		return nil, fmt.Errorf("notification: parse firebase service account: %w", err)
	}
	projectID, err := creds.ProjectID(ctx)
	if err != nil {
		return nil, fmt.Errorf("notification: read project id from firebase service account: %w", err)
	}
	if projectID == "" {
		return nil, fmt.Errorf("notification: firebase service account JSON has no project_id")
	}

	httpClient, err := httptransport.NewClient(&httptransport.Options{Credentials: creds})
	if err != nil {
		return nil, fmt.Errorf("notification: build authenticated http client: %w", err)
	}
	httpClient.Timeout = defaultTimeout

	return &FCMPushSender{
		projectID:  projectID,
		httpClient: httpClient,
		baseURL:    defaultBaseURL,
	}, nil
}

// ProjectID reports the Firebase project this sender targets. Logged once at
// startup so an operator can confirm which project is configured without
// decoding the service-account JSON by hand.
func (s *FCMPushSender) ProjectID() string { return s.projectID }

type fcmMessage struct {
	Message fcmMessageBody `json:"message"`
}

type fcmMessageBody struct {
	Token        string            `json:"token"`
	Notification fcmNotification   `json:"notification"`
	Data         map[string]string `json:"data,omitempty"`
}

type fcmNotification struct {
	Title string `json:"title"`
	Body  string `json:"body"`
}

// fcmErrorResponse is the shape of FCM HTTP v1's error body. Only the fields
// that classify the failure are decoded; the rest is ignored.
type fcmErrorResponse struct {
	Error struct {
		Code    int    `json:"code"`
		Status  string `json:"status"`
		Message string `json:"message"`
		Details []struct {
			Type      string `json:"@type"`
			ErrorCode string `json:"errorCode"`
		} `json:"details"`
	} `json:"error"`
}

// SendToTokens satisfies Sender. It reports only whether the whole call
// failed; callers that need the per-token detail (to delete dead tokens)
// use SendToTokensDetailed.
func (s *FCMPushSender) SendToTokens(ctx context.Context, tokens []string, title, body string, data map[string]string) error {
	result, err := s.SendToTokensDetailed(ctx, tokens, title, body, data)
	if err != nil {
		return err
	}
	if result.Delivered == 0 && result.LastErr != nil {
		return fmt.Errorf("notification: send to all %d device(s) failed, last error: %w", len(tokens), result.LastErr)
	}
	return nil
}

// SendToTokensDetailed sends to every token concurrently (bounded) and
// reports the per-token outcome.
//
// The batch is NOT abandoned on the first failure. One expired token among a
// user's three devices must not stop the other two receiving the
// notification — the same tolerance the source's sequential loop had, kept
// deliberately.
func (s *FCMPushSender) SendToTokensDetailed(ctx context.Context, tokens []string, title, body string, data map[string]string) (SendResult, error) {
	if len(tokens) == 0 {
		return SendResult{}, nil
	}

	ctx, cancel := context.WithTimeout(ctx, batchDeadline)
	defer cancel()

	concurrency := maxConcurrentSends
	if len(tokens) < concurrency {
		concurrency = len(tokens)
	}

	var (
		mu     sync.Mutex
		result SendResult
		wg     sync.WaitGroup
	)
	sem := make(chan struct{}, concurrency)

	for _, token := range tokens {
		wg.Add(1)
		go func(token string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()

			err := s.send(ctx, token, title, body, data)

			mu.Lock()
			defer mu.Unlock()
			switch {
			case err == nil:
				result.Delivered++
			case errors.Is(err, ErrTokenUnregistered):
				result.Unregistered = append(result.Unregistered, token)
			default:
				result.LastErr = err
			}
		}(token)
	}
	wg.Wait()

	return result, nil
}

// send delivers to one token.
//
// NEVER INCLUDES THE RAW TOKEN in a returned error or a log line. The
// source's version returned the raw FCM response body on a non-200, which is
// a smaller version of the same leak — FCM echoes an INVALID_ARGUMENT back
// with the offending registration token in the message. Only the status code
// and FCM's own classification (both PII-free) are surfaced.
func (s *FCMPushSender) send(ctx context.Context, token, title, body string, data map[string]string) error {
	payload := fcmMessage{Message: fcmMessageBody{
		Token:        token,
		Notification: fcmNotification{Title: title, Body: body},
		Data:         data,
	}}
	encoded, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("notification: marshal fcm payload: %w", err)
	}

	endpoint := fmt.Sprintf("%s/v1/projects/%s/messages:send", s.baseURL, s.projectID)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(encoded))
	if err != nil {
		return fmt.Errorf("notification: build fcm request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := s.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("notification: fcm request: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode == http.StatusOK {
		return nil
	}

	// Bounded read: an error body is diagnostic, and an unbounded read of a
	// misbehaving endpoint's response is its own denial of service.
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<10))
	if classifyFCMError(resp.StatusCode, raw) {
		return &TokenError{Token: token, Err: ErrTokenUnregistered}
	}
	return fmt.Errorf("notification: fcm send failed with status %d (%s)", resp.StatusCode, fcmReason(raw))
}

// classifyFCMError reports whether this response means the token is
// permanently dead (§E2c).
//
// TRUE only for FCM's two explicit permanent signals:
//
//   - UNREGISTERED (HTTP 404) — the app was uninstalled or the token rotated.
//   - INVALID_ARGUMENT (HTTP 400) — the token is malformed, or belongs to a
//     different Firebase project. Narrowed to responses that name the
//     registration token specifically, because INVALID_ARGUMENT is also what
//     a malformed MESSAGE returns, and deleting a perfectly good token
//     because the notification body was wrong would be a self-inflicted
//     outage.
//
// Everything else — 429, 5xx, timeouts, and any status or body shape not
// recognised here — is transient by default. That default direction is the
// safe one: a transient failure misread as permanent silently and
// irreversibly stops notifying a real user, while a permanent failure
// misread as transient merely wastes a few retries before the row
// dead-letters on its own.
func classifyFCMError(status int, body []byte) bool {
	var parsed fcmErrorResponse
	if err := json.Unmarshal(body, &parsed); err != nil {
		// An unparseable body tells us nothing, so it justifies nothing.
		return false
	}

	for _, detail := range parsed.Error.Details {
		switch detail.ErrorCode {
		case "UNREGISTERED":
			return true
		case "INVALID_ARGUMENT":
			return status == http.StatusBadRequest && mentionsRegistrationToken(parsed.Error.Message)
		}
	}

	switch parsed.Error.Status {
	case "NOT_FOUND":
		// FCM's documented status for an unregistered token.
		return status == http.StatusNotFound
	case "INVALID_ARGUMENT":
		return status == http.StatusBadRequest && mentionsRegistrationToken(parsed.Error.Message)
	}
	return false
}

// mentionsRegistrationToken distinguishes "your token is bad" from "your
// message is bad" inside INVALID_ARGUMENT, which FCM uses for both.
func mentionsRegistrationToken(message string) bool {
	for _, needle := range []string{"registration token", "registration-token", "not a valid FCM registration token"} {
		if containsFold(message, needle) {
			return true
		}
	}
	return false
}

// fcmReason extracts FCM's own PII-free classification for an error message.
// Falls back to a fixed string rather than the raw body — the body can echo
// the registration token.
func fcmReason(body []byte) string {
	var parsed fcmErrorResponse
	if err := json.Unmarshal(body, &parsed); err != nil || parsed.Error.Status == "" {
		return "unclassified"
	}
	for _, detail := range parsed.Error.Details {
		if detail.ErrorCode != "" {
			return parsed.Error.Status + "/" + detail.ErrorCode
		}
	}
	return parsed.Error.Status
}

// containsFold is a tiny case-insensitive substring check, kept local rather
// than pulling in strings.ToLower allocations on every classification.
func containsFold(haystack, needle string) bool {
	if len(needle) > len(haystack) {
		return false
	}
	for i := 0; i+len(needle) <= len(haystack); i++ {
		if equalFold(haystack[i:i+len(needle)], needle) {
			return true
		}
	}
	return false
}

func equalFold(a, b string) bool {
	for i := 0; i < len(a); i++ {
		ca, cb := a[i], b[i]
		if 'A' <= ca && ca <= 'Z' {
			ca += 'a' - 'A'
		}
		if 'A' <= cb && cb <= 'Z' {
			cb += 'a' - 'A'
		}
		if ca != cb {
			return false
		}
	}
	return true
}

var _ Sender = (*FCMPushSender)(nil)
