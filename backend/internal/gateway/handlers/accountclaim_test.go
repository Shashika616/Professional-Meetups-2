package handlers

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"professional-meetups-monolith/backend/internal/gateway/monolithclient"
	"professional-meetups-monolith/backend/internal/platform/jwt"
)

// claimServer is newTestServer with a caller-supplied monolith. The shared
// helper types its field as *fakeMonolith, and these tests need their own
// double for the two claim methods, so this wires the same Handler around
// one rather than widening a struct the whole suite depends on.
type claimServer struct {
	mux      *http.ServeMux
	signer   *jwt.Signer
	verifier *jwt.Verifier
}

func newTestServerWithMonolith(t *testing.T, monolith monolithclient.Client) *claimServer {
	t.Helper()
	signer, verifier := newTestKeys(t)
	mux := http.NewServeMux()
	New(monolith, signer, verifier, WithLogger(slog.New(slog.DiscardHandler))).Register(mux)
	return &claimServer{mux: mux, signer: signer, verifier: verifier}
}

// doRequest serves an already-built request, for the cases that need a
// bearer token and a body at once (the deletion-authorisation tests).
func (s *claimServer) doRequest(r *http.Request) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	s.mux.ServeHTTP(rec, r)
	return rec
}

// tokenFor mints a real access token with this server's own signer, so the
// tests exercise the actual verify path rather than a stubbed identity.
func (s *claimServer) tokenFor(t *testing.T, userID string, trustLevel int) string {
	t.Helper()
	token, err := s.signer.Sign(jwt.Claims{UserID: userID, TrustLevel: trustLevel})
	if err != nil {
		t.Fatalf("sign test token: %v", err)
	}
	return token
}

func (s *claimServer) do(method, path, body, _ string) *httptest.ResponseRecorder {
	var r *http.Request
	if body == "" {
		r = httptest.NewRequest(method, path, nil)
	} else {
		r = httptest.NewRequest(method, path, strings.NewReader(body))
	}
	rec := httptest.NewRecorder()
	s.mux.ServeHTTP(rec, r)
	return rec
}

// testSession is the session shape the shared suite uses, so a claim that
// succeeds is asserted against the same response contract as every other
// session-issuing route.
func testSession() monolithclient.Session {
	return monolithclient.Session{
		UserID: "user-1", RefreshToken: "raw-refresh-token", TrustLevel: 2,
		FullName: "Ada Lovelace",
	}
}

// claimFake records the claim routes and serves the two outcomes they have.
// Separate from fakeMonolith's shared fields so these tests cannot be
// perturbed by, or perturb, the rest of the handler suite.
type claimFake struct {
	monolithclient.Client

	session monolithclient.Session
	err     error

	gotTicket string
	gotCode   string

	resendAfter int32
	resendErr   error
}

func (f *claimFake) CompleteFederatedSignup(_ context.Context, _, _, _ string, _ bool, _ string) (monolithclient.Session, error) {
	return f.session, f.err
}

func (f *claimFake) CompleteAccountClaim(_ context.Context, ticket, code string) (monolithclient.Session, error) {
	f.gotTicket, f.gotCode = ticket, code
	return f.session, f.err
}

func (f *claimFake) ResendAccountClaimCode(_ context.Context, ticket string) (int32, error) {
	f.gotTicket = ticket
	return f.resendAfter, f.resendErr
}

// claimRequiredErr builds the error the real client produces when the
// monolith answers ALREADY_EXISTS with the detail attached.
func claimRequiredErr() error {
	return monolithclient.NewAccountClaimRequiredError(
		"signed-ticket", "ada@example.com", 60,
		status.Error(codes.AlreadyExists, "an account already exists for this email address"),
	)
}

func TestFederatedSignup_AccountClaimRequiredBody(t *testing.T) {
	s := newTestServerWithMonolith(t, &claimFake{err: claimRequiredErr()})

	rec := s.do(http.MethodPost, "/v1/auth/federated/signup",
		`{"provider":"apple","id_token":"tok","nonce":"n","age_confirmed_over_18":true}`, "")

	if rec.Code != http.StatusConflict {
		t.Fatalf("status = %d, want 409 (body: %s)", rec.Code, rec.Body.String())
	}
	body := decodeBody(t, rec)

	// The app opens a different screen on this, so it switches on the code
	// rather than on the sentence — matching prose would break the first
	// time the wording improved.
	if body["code"] != accountClaimRequiredCode {
		t.Errorf("code = %v, want %q", body["code"], accountClaimRequiredCode)
	}
	if body["ticket"] != "signed-ticket" {
		t.Errorf("ticket = %v, want it passed through — without it the popup has nothing to send back", body["ticket"])
	}
	if body["email"] != "ada@example.com" {
		t.Errorf("email = %v, want the address the code went to", body["email"])
	}
	if body["resend_after_seconds"] != float64(60) {
		t.Errorf("resend_after_seconds = %v, want 60", body["resend_after_seconds"])
	}
	if body["error"] == "" || body["error"] == nil {
		t.Error("no sentence: a client that does not know this code must still have something to show")
	}

	// Nothing that would hand out a session for an account nobody has
	// proved anything about yet.
	for _, forbidden := range []string{"access_token", "refresh_token", "user_id"} {
		if v, present := body[forbidden]; present && v != "" {
			t.Errorf("the 409 body carries %q = %v", forbidden, v)
		}
	}
}

func TestCompleteAccountClaimRoute(t *testing.T) {
	t.Run("forwards the ticket and code and returns a signed session", func(t *testing.T) {
		fake := &claimFake{session: testSession()}
		s := newTestServerWithMonolith(t, fake)

		rec := s.do(http.MethodPost, "/v1/auth/account-claim",
			`{"ticket":"signed-ticket","code":"123456"}`, "")
		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200 (body: %s)", rec.Code, rec.Body.String())
		}
		if fake.gotTicket != "signed-ticket" || fake.gotCode != "123456" {
			t.Errorf("forwarded ticket=%q code=%q", fake.gotTicket, fake.gotCode)
		}

		body := decodeBody(t, rec)
		accessToken, _ := body["access_token"].(string)
		if accessToken == "" {
			t.Fatal("no access_token: a successful claim must end in a usable session")
		}
		if _, err := s.verifier.Verify(accessToken); err != nil {
			t.Errorf("the gateway's own verifier rejected the token it just signed: %v", err)
		}
	})

	t.Run("a rejected code produces no session", func(t *testing.T) {
		s := newTestServerWithMonolith(t, &claimFake{
			err: status.Error(codes.InvalidArgument, "invalid code"),
		})

		rec := s.do(http.MethodPost, "/v1/auth/account-claim",
			`{"ticket":"signed-ticket","code":"000000"}`, "")
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("status = %d, want 400 (body: %s)", rec.Code, rec.Body.String())
		}
		if body := decodeBody(t, rec); body["access_token"] != nil {
			t.Error("a rejected code returned an access token")
		}
	})

	t.Run("a malformed body is refused without reaching the monolith", func(t *testing.T) {
		fake := &claimFake{session: testSession()}
		s := newTestServerWithMonolith(t, fake)

		rec := s.do(http.MethodPost, "/v1/auth/account-claim", `not json`, "")
		if rec.Code != http.StatusBadRequest {
			t.Errorf("status = %d, want 400", rec.Code)
		}
		if fake.gotTicket != "" {
			t.Error("a malformed body was forwarded upstream")
		}
	})
}

func TestResendAccountClaimCodeRoute(t *testing.T) {
	t.Run("returns the new cooldown", func(t *testing.T) {
		fake := &claimFake{resendAfter: 60}
		s := newTestServerWithMonolith(t, fake)

		rec := s.do(http.MethodPost, "/v1/auth/account-claim/resend", `{"ticket":"signed-ticket"}`, "")
		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200 (body: %s)", rec.Code, rec.Body.String())
		}
		if fake.gotTicket != "signed-ticket" {
			t.Errorf("forwarded ticket = %q", fake.gotTicket)
		}
		if body := decodeBody(t, rec); body["resend_after_seconds"] != float64(60) {
			t.Errorf("resend_after_seconds = %v, want 60", body["resend_after_seconds"])
		}
	})

	t.Run("the cooldown refusal reaches the client as 429", func(t *testing.T) {
		s := newTestServerWithMonolith(t, &claimFake{
			resendErr: status.Error(codes.ResourceExhausted, "please wait before requesting another code"),
		})

		rec := s.do(http.MethodPost, "/v1/auth/account-claim/resend", `{"ticket":"signed-ticket"}`, "")
		if rec.Code != http.StatusTooManyRequests {
			t.Errorf("status = %d, want 429 (body: %s)", rec.Code, rec.Body.String())
		}
	})
}
