package handlers

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"professional-meetups-monolith/backend/internal/gateway/monolithclient"
)

type confirmMonolith struct {
	monolithclient.Client
	calls []string
	name  string
	err   error
}

func (m *confirmMonolith) ConfirmTrustedContact(_ context.Context, token string) (string, error) {
	m.calls = append(m.calls, token)
	return m.name, m.err
}

func confirmServer(t *testing.T, m *confirmMonolith) *http.ServeMux {
	t.Helper()
	signer, verifier := newTestKeys(t)
	mux := http.NewServeMux()
	New(m, signer, verifier, WithLogger(slog.New(slog.DiscardHandler))).Register(mux)
	return mux
}

// SMS and chat apps fetch links by themselves to draw a preview. A GET that
// confirmed would let a preview agree on the contact's behalf, so GET must
// only ever show the question.
func TestContactConfirm_GETNeverConfirms(t *testing.T) {
	m := &confirmMonolith{name: "Ada"}
	mux := confirmServer(t, m)

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/c/tok123", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("GET status %d, want 200", rec.Code)
	}
	if len(m.calls) != 0 {
		t.Errorf("a GET confirmed the contact (%d calls): a link preview would agree on their behalf", len(m.calls))
	}
	body := rec.Body.String()
	if !strings.Contains(body, `method="post"`) || !strings.Contains(body, "I agree") {
		t.Errorf("GET page has no agree button posting back")
	}
}

func TestContactConfirm_POSTConfirmsAndNamesTheRequester(t *testing.T) {
	m := &confirmMonolith{name: "Ada <script>"}
	mux := confirmServer(t, m)

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/c/tok123", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("POST status %d, want 200", rec.Code)
	}
	if len(m.calls) != 1 || m.calls[0] != "tok123" {
		t.Errorf("confirm calls = %v, want one for tok123", m.calls)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "Ada &lt;script&gt;") {
		t.Errorf("the requester's name is not shown, or not escaped: %s", body)
	}
}

func TestContactConfirm_AnUsedOrExpiredLinkSaysSo(t *testing.T) {
	m := &confirmMonolith{err: status.Error(codes.NotFound, "gone")}
	mux := confirmServer(t, m)

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/c/used", nil))

	if rec.Code != http.StatusNotFound {
		t.Errorf("status %d, want 404", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "expired or was already used") {
		t.Errorf("the page does not explain the link is spent")
	}
}

// The token is the whole credential, so the page must not leak it onward,
// be cached, or be framed by another site.
func TestContactConfirm_PageProtectsTheToken(t *testing.T) {
	mux := confirmServer(t, &confirmMonolith{})
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/c/tok123", nil))

	for header, want := range map[string]string{
		"Referrer-Policy": "no-referrer",
		"Cache-Control":   "no-store",
		"X-Frame-Options": "DENY",
	} {
		if got := rec.Header().Get(header); got != want {
			t.Errorf("%s = %q, want %q", header, got, want)
		}
	}
	csp := rec.Header().Get("Content-Security-Policy")
	for _, want := range []string{"default-src 'none'", "frame-ancestors 'none'", "form-action 'self'"} {
		if !strings.Contains(csp, want) {
			t.Errorf("CSP %q lacks %q", csp, want)
		}
	}
	body, _ := io.ReadAll(rec.Body)
	if strings.Contains(string(body), "http") {
		t.Errorf("the page references an outside URL, which could carry the token away")
	}
}
