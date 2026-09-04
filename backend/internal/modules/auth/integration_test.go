package auth_test

// Integration tests: the real auth module, wired to real Postgres
// repositories, against the real migrations. This is the layer the
// fake-repository unit tests in package auth cannot cover — a bad migration,
// a bad query, a constraint that doesn't behave the way the service assumes,
// the sqlc-generated scanning, and the event bus actually firing from inside
// a repository write.
//
// External (package auth_test) on purpose: these exercise the module through
// its one public interface, exactly as internal/grpcapi does, so anything
// they reach is by definition part of the module's real surface.

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/eventbus"
	"professional-meetups-monolith/backend/internal/modules/auth"
	"professional-meetups-monolith/backend/internal/modules/auth/email"
	"professional-meetups-monolith/backend/internal/modules/auth/identity"
	"professional-meetups-monolith/backend/internal/modules/auth/linkedin"
	"professional-meetups-monolith/backend/internal/modules/auth/repository"
	"professional-meetups-monolith/backend/internal/modules/auth/sms"
	"professional-meetups-monolith/backend/internal/platform/apperror"
	"professional-meetups-monolith/backend/internal/platform/db"
)

// defaultTestDatabaseURL matches backend/docker-compose.yml's local Postgres
// defaults. CI overrides it via DATABASE_URL, as does a local run when the
// stack is on a non-default port (see backend/.env).
const defaultTestDatabaseURL = "postgres://app:app@localhost:5432/monolith_db?sslmode=disable"

// migrationsURL is relative to this file's directory (Go tests run with cwd
// set to the package directory) — this repo has ONE migration history for
// every module (ADR-001 §3), not one per module, so this points at all of it.
const migrationsURL = "file://../../../migrations"

// requirePostgres skips the test if Postgres isn't reachable within a short
// timeout, so a plain `go test ./...` stays fast and doesn't hang when a
// developer hasn't run `docker compose up` — the same pattern the sibling
// repo uses. Unlike that one, the host:port is read from the URL rather than
// hardcoded to localhost:5432, since this stack is routinely run on another
// port alongside the sibling repo's.
func requirePostgres(t *testing.T) string {
	t.Helper()

	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		dbURL = defaultTestDatabaseURL
	}

	parsed, err := url.Parse(dbURL)
	if err != nil {
		t.Fatalf("DATABASE_URL %q is not a URL: %v", dbURL, err)
	}
	hostPort := parsed.Host
	if !strings.Contains(hostPort, ":") {
		hostPort += ":5432"
	}

	conn, err := net.DialTimeout("tcp", hostPort, 500*time.Millisecond)
	if err != nil {
		t.Skipf("postgres not reachable on %s, skipping integration test (run `docker compose up -d postgres` first): %v", hostPort, err)
	}
	_ = conn.Close()

	return dbURL
}

// truncateAuthTables gives each test a clean slate without dropping the
// schema. known_companies is deliberately NOT truncated: its rows are seeded
// by the migration itself and the corporate-email tests verify against them,
// which is precisely the kind of thing a fake repository can't check.
func truncateAuthTables(t *testing.T, pool *pgxpool.Pool) {
	t.Helper()
	_, err := pool.Exec(context.Background(), `
		TRUNCATE auth.users, auth.refresh_tokens, auth.verification_codes,
		         auth.user_identities, auth.unverified_company_claims,
		         auth.trusted_contacts, auth.sos_events
		RESTART IDENTITY CASCADE`)
	if err != nil {
		t.Fatalf("truncate: %v", err)
	}
}

// recordingBus captures what the module published, so the integration tests
// can assert the events Phase 2 will subscribe to are actually emitted from
// the real repository write paths.
type recordingBus struct {
	*eventbus.InMemoryBus
	mu     sync.Mutex
	events []eventbus.Event
}

func newRecordingBus() *recordingBus {
	b := &recordingBus{InMemoryBus: eventbus.New(slog.New(slog.DiscardHandler))}
	for _, topic := range []string{
		eventbus.TopicUserOnboarded,
		eventbus.TopicUserProfileUpdated,
		eventbus.TopicUserLocationUpdated,
	} {
		b.Subscribe(topic, func(_ context.Context, e eventbus.Event) error {
			b.mu.Lock()
			defer b.mu.Unlock()
			b.events = append(b.events, e)
			return nil
		})
	}
	return b
}

func (b *recordingBus) topics() []string {
	b.mu.Lock()
	defer b.mu.Unlock()
	out := make([]string, 0, len(b.events))
	for _, e := range b.events {
		out = append(out, e.Topic)
	}
	return out
}

func (b *recordingBus) countOf(topic string) int {
	n := 0
	for _, got := range b.topics() {
		if got == topic {
			n++
		}
	}
	return n
}

// identityProviderStub stands in for the Apple/Google providers — real
// credentials don't exist, and real JWKS/nonce verification is
// internal/modules/auth/identity's own concern (identity_test.go). It still
// enforces the nonce contract so these tests can't accidentally pass a
// federated flow that forgot to thread one.
type identityProviderStub struct {
	validTokens map[string]identity.VerifiedIdentity
}

func (s *identityProviderStub) Verify(_ context.Context, idToken, expectedNonce string) (identity.VerifiedIdentity, error) {
	if expectedNonce == "" {
		return identity.VerifiedIdentity{}, fmt.Errorf("stub: sign-in nonce is required")
	}
	v, ok := s.validTokens[idToken]
	if !ok {
		return identity.VerifiedIdentity{}, fmt.Errorf("stub: invalid id_token")
	}
	return v, nil
}

// captureSender records what would have been sent. The OTP tests need the
// real generated code — this port does NOT carry the source's testing bypass
// that accepts a hardcoded "123456" (see otp.go), so a test has to read the
// code the same way local development does: off the sender.
type captureSender struct {
	mu     sync.Mutex
	codes  []string
	alerts []string
}

func (c *captureSender) SendVerificationCode(_ context.Context, _, code string, _ email.Purpose) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.codes = append(c.codes, code)
	return nil
}

func (c *captureSender) SendAlert(_ context.Context, _, message string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.alerts = append(c.alerts, message)
	return nil
}

func (c *captureSender) lastCode() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.codes) == 0 {
		return ""
	}
	return c.codes[len(c.codes)-1]
}

// smsCapture is captureSender's SmsSender-shaped twin (different
// SendVerificationCode signature — no purpose argument).
type smsCapture struct{ captureSender }

func (c *smsCapture) SendVerificationCode(_ context.Context, _, code string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.codes = append(c.codes, code)
	return nil
}

var (
	_ email.EmailSender = (*captureSender)(nil)
	_ sms.SmsSender     = (*smsCapture)(nil)
)

type harness struct {
	svc      auth.Service
	pool     *pgxpool.Pool
	bus      *recordingBus
	emailer  *captureSender
	smser    *smsCapture
	apple    *identityProviderStub
	linkedIn string // the sub the stub LinkedIn server returns
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	dbURL := requirePostgres(t)

	if err := db.Migrate(dbURL, migrationsURL); err != nil {
		t.Fatalf("run migrations: %v", err)
	}

	ctx := context.Background()
	pool, err := db.New(ctx, dbURL)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(pool.Close)
	truncateAuthTables(t, pool)

	linkedInSub := fmt.Sprintf("li-sub-%d", time.Now().UnixNano())
	mux := http.NewServeMux()
	mux.HandleFunc("/token", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"access_token":"li-access-token","expires_in":5184000}`))
	})
	mux.HandleFunc("/userinfo", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = fmt.Fprintf(w, `{"sub":%q,"name":"Integration Test User","picture":"https://example.com/p.jpg"}`, linkedInSub)
	})
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)

	bus := newRecordingBus()
	emailer := &captureSender{}
	smser := &smsCapture{}
	apple := &identityProviderStub{validTokens: map[string]identity.VerifiedIdentity{}}
	logger := slog.New(slog.DiscardHandler)

	svc := auth.New(auth.Deps{
		Users:                   repository.NewUserRepository(pool, bus, logger),
		Identities:              repository.NewUserIdentityRepository(pool),
		RefreshTokens:           repository.NewRefreshTokenRepository(pool),
		VerificationCodes:       repository.NewVerificationCodeRepository(pool),
		KnownCompanies:          repository.NewKnownCompanyRepository(pool),
		UnverifiedCompanyClaims: repository.NewUnverifiedCompanyClaimRepository(pool),
		TrustedContacts:         repository.NewTrustedContactRepository(pool),
		SOSEvents:               repository.NewSOSEventRepository(pool),
		LinkedIn: linkedin.New(
			linkedin.Config{ClientID: "cid", ClientSecret: "csecret"},
			linkedin.WithTokenURL(server.URL+"/token"),
			linkedin.WithUserInfoURL(server.URL+"/userinfo"),
		),
		Apple:            apple,
		Google:           apple,
		Email:            emailer,
		SMS:              smser,
		WorkEmailHMACKey: []byte("integration-test-hmac-key"),
		Logger:           logger,
	})

	return &harness{svc: svc, pool: pool, bus: bus, emailer: emailer, smser: smser, apple: apple, linkedIn: linkedInSub}
}

// signUpByEmail runs the real two-step email-OTP signup against Postgres and
// returns the created session.
func (h *harness) signUpByEmail(t *testing.T, address string) auth.SessionResult {
	t.Helper()
	ctx := context.Background()

	if _, err := h.svc.StartEmailSignup(ctx, auth.StartVerificationRequest{
		Purpose: auth.VerificationPurposeEmailSignup, Target: address,
	}); err != nil {
		t.Fatalf("StartEmailSignup: %v", err)
	}

	session, err := h.svc.CompleteEmailSignup(ctx, auth.CompleteEmailSignupRequest{
		Email: address, Code: h.emailer.lastCode(), AgeConfirmedOver18: true,
	})
	if err != nil {
		t.Fatalf("CompleteEmailSignup: %v", err)
	}
	return session
}

// TestEmailSignup_Integration is the flow the phase plan asks to be
// exercised end to end: OTP signup, then profile setup, then reading the
// profile back — all against real SQL.
func TestEmailSignup_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	session := h.signUpByEmail(t, "ada@example.com")
	if !session.IsNewUser {
		t.Error("IsNewUser = false, want true")
	}
	if session.UserID == "" || session.RefreshToken == "" {
		t.Fatalf("session = %+v, want a persisted user id and a raw refresh token", session)
	}
	if session.TrustLevel != 0 {
		t.Errorf("TrustLevel = %d, want 0 — email alone never grants Level 1", session.TrustLevel)
	}

	profile, err := h.svc.CompleteProfileSetup(ctx, auth.CompleteProfileSetupRequest{
		UserID: session.UserID, FullName: "Ada Lovelace",
	})
	if err != nil {
		t.Fatalf("CompleteProfileSetup: %v", err)
	}
	if profile.FullName != "Ada Lovelace" {
		t.Errorf("FullName = %q, want %q", profile.FullName, "Ada Lovelace")
	}

	got, err := h.svc.GetProfile(ctx, session.UserID)
	if err != nil {
		t.Fatalf("GetProfile: %v", err)
	}
	if got.FullName != "Ada Lovelace" || got.PersonalEmail != "ada@example.com" {
		t.Errorf("profile = %+v, want the persisted name and pre-verified personal email", got)
	}
	if !got.PersonalEmailVerified {
		t.Error("PersonalEmailVerified = false — the OTP round trip is what verified it")
	}

	// The events Phase 2's read-model caches will subscribe to must actually
	// be published by the real repository write paths.
	if h.bus.countOf(eventbus.TopicUserOnboarded) != 1 {
		t.Errorf("user-onboarded published %d times, want 1 (topics seen: %v)",
			h.bus.countOf(eventbus.TopicUserOnboarded), h.bus.topics())
	}
	if h.bus.countOf(eventbus.TopicUserProfileUpdated) == 0 {
		t.Errorf("user-profile-updated was never published (topics seen: %v)", h.bus.topics())
	}
}

// TestEmailSignup_RecoversExistingAccount covers SignUpOrRecoverWithEmail's
// deliberate design: a second signup with an address that is already a
// verified personal_email logs into THAT account rather than creating a
// duplicate — which only works if the UNIQUE index and the lookup agree.
func TestEmailSignup_RecoversExistingAccount(t *testing.T) {
	h := newHarness(t)

	first := h.signUpByEmail(t, "ada@example.com")
	second := h.signUpByEmail(t, "ada@example.com")

	if second.IsNewUser {
		t.Error("IsNewUser = true on the second signup, want false (recovery, not a duplicate account)")
	}
	if second.UserID != first.UserID {
		t.Errorf("second signup returned user %q, want the existing %q", second.UserID, first.UserID)
	}

	var users int
	if err := h.pool.QueryRow(context.Background(), `SELECT count(*) FROM auth.users`).Scan(&users); err != nil {
		t.Fatalf("count users: %v", err)
	}
	if users != 1 {
		t.Errorf("auth.users row count = %d, want 1", users)
	}
}

// TestOTP_ExpiryAttemptCapAndConsumption exercises the three OTP rules
// against real rows: a wrong code increments attempts, the 5-attempt cap
// invalidates the code, and a successful verification deletes the row (so
// the raw target doesn't linger).
func TestOTP_ExpiryAttemptCapAndConsumption(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	// A user with LinkedIn linked — phone verification requires it.
	session, err := h.svc.CompleteLinkedInOnboarding(ctx, auth.CompleteLinkedInOnboardingRequest{
		AuthorizationCode: "code", RedirectURI: "app://cb", AgeConfirmedOver18: true,
	})
	if err != nil {
		t.Fatalf("CompleteLinkedInOnboarding: %v", err)
	}
	userID := session.UserID

	start := func() {
		t.Helper()
		if _, err := h.svc.StartPhoneVerification(ctx, auth.StartVerificationRequest{
			UserID: userID, Purpose: auth.VerificationPurposePhone, Target: "+94771234567",
		}); err != nil {
			t.Fatalf("StartPhoneVerification: %v", err)
		}
	}
	verify := func(code string) error {
		_, err := h.svc.VerifyPhoneCode(ctx, auth.VerifyCodeRequest{
			UserID: userID, Purpose: auth.VerificationPurposePhone, Target: "+94771234567", Code: code,
		})
		return err
	}

	start()

	// Five wrong guesses: the first four are "invalid code", and the row's
	// attempts column really does climb in Postgres.
	for i := 1; i <= 4; i++ {
		if err := verify("000000"); err == nil {
			t.Fatalf("guess %d was accepted, want rejected", i)
		}
		var attempts int
		if err := h.pool.QueryRow(ctx,
			`SELECT attempts FROM auth.verification_codes WHERE user_id = $1 AND purpose = 'phone'`, userID).Scan(&attempts); err != nil {
			t.Fatalf("read attempts after guess %d: %v", i, err)
		}
		if attempts != i {
			t.Errorf("attempts after guess %d = %d, want %d", i, attempts, i)
		}
	}

	// The 5th failure hits the cap and the row is deleted outright, so even
	// the CORRECT code no longer works until a fresh send.
	correct := h.smser.lastCode()
	if err := verify("000000"); err == nil {
		t.Fatal("the 5th wrong guess was accepted")
	}
	var remaining int
	if err := h.pool.QueryRow(ctx,
		`SELECT count(*) FROM auth.verification_codes WHERE user_id = $1 AND purpose = 'phone'`, userID).Scan(&remaining); err != nil {
		t.Fatalf("count codes: %v", err)
	}
	if remaining != 0 {
		t.Errorf("verification_codes rows after hitting the attempt cap = %d, want 0", remaining)
	}
	if err := verify(correct); err == nil {
		t.Error("the correct code still verified after the attempt cap was hit, want rejection")
	}

	// A fresh send, then the real code, succeeds — and consumes the row.
	// (The resend cooldown is keyed on created_at, and the capped row was
	// deleted, so there is nothing to cool down against.)
	start()
	if err := verify(h.smser.lastCode()); err != nil {
		t.Fatalf("verify with a freshly sent code: %v", err)
	}
	if err := h.pool.QueryRow(ctx,
		`SELECT count(*) FROM auth.verification_codes WHERE user_id = $1 AND purpose = 'phone'`, userID).Scan(&remaining); err != nil {
		t.Fatalf("count codes: %v", err)
	}
	if remaining != 0 {
		t.Errorf("verification_codes rows after success = %d, want 0 — the row (and the raw target) must not linger", remaining)
	}

	var phone string
	if err := h.pool.QueryRow(ctx, `SELECT phone_number FROM auth.users WHERE id = $1`, userID).Scan(&phone); err != nil {
		t.Fatalf("read phone: %v", err)
	}
	if phone != "+94771234567" {
		t.Errorf("persisted phone_number = %q, want %q", phone, "+94771234567")
	}
}

// TestResendCooldown_Integration: the server-enforced 1-minute gap is the
// real control (the client's countdown is a convenience).
func TestResendCooldown_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	if _, err := h.svc.StartEmailSignup(ctx, auth.StartVerificationRequest{
		Purpose: auth.VerificationPurposeEmailSignup, Target: "ada@example.com",
	}); err != nil {
		t.Fatalf("first StartEmailSignup: %v", err)
	}

	_, err := h.svc.StartEmailSignup(ctx, auth.StartVerificationRequest{
		Purpose: auth.VerificationPurposeEmailSignup, Target: "ada@example.com",
	})
	if err == nil {
		t.Fatal("an immediate resend was allowed, want it rate limited")
	}
	if !isSentinel(err, apperror.ErrRateLimited) {
		t.Errorf("error = %v, want it to wrap ErrRateLimited", err)
	}
}

// TestCorporateEmailVerification_Integration runs the company checks against
// the migration's OWN seeded known_companies rows — the case a fake
// repository can't cover, since the seed data is part of the schema.
func TestCorporateEmailVerification_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	session, err := h.svc.CompleteLinkedInOnboarding(ctx, auth.CompleteLinkedInOnboardingRequest{
		AuthorizationCode: "code", RedirectURI: "app://cb", AgeConfirmedOver18: true,
	})
	if err != nil {
		t.Fatalf("CompleteLinkedInOnboarding: %v", err)
	}
	userID := session.UserID

	startAndVerify := func(target, companyName string) error {
		if _, err := h.svc.StartCorporateEmailVerification(ctx, auth.StartVerificationRequest{
			UserID: userID, Purpose: auth.VerificationPurposeCorporateEmail, Target: target,
		}); err != nil {
			return err
		}
		_, err := h.svc.VerifyCorporateEmailCode(ctx, auth.VerifyCodeRequest{
			UserID: userID, Purpose: auth.VerificationPurposeCorporateEmail,
			Target: target, Code: h.emailer.lastCode(), CompanyName: companyName,
		})
		return err
	}

	t.Run("free provider is rejected before any code is sent", func(t *testing.T) {
		before := len(h.emailer.codes)
		_, err := h.svc.StartCorporateEmailVerification(ctx, auth.StartVerificationRequest{
			UserID: userID, Purpose: auth.VerificationPurposeCorporateEmail, Target: "ada@gmail.com",
		})
		if err == nil {
			t.Fatal("gmail.com was accepted as a work email")
		}
		if !isSentinel(err, apperror.ErrInvalidInput) {
			t.Errorf("error = %v, want ErrInvalidInput", err)
		}
		if len(h.emailer.codes) != before {
			t.Error("an OTP was sent for a rejected address — the check must run before the send (it costs money)")
		}
	})

	t.Run("known company with a mismatched domain is rejected", func(t *testing.T) {
		// "wso2" is seeded by the migration with domain wso2.com.
		err := startAndVerify("ada@wso2-lookalike.com", "WSO2")
		if err == nil {
			t.Fatal("a lookalike domain was accepted for a known company")
		}
		if !isSentinel(err, apperror.ErrInvalidInput) {
			t.Errorf("error = %v, want ErrInvalidInput", err)
		}
	})

	t.Run("known company with a matching domain, case-insensitively", func(t *testing.T) {
		if err := startAndVerify("Ada@WSO2.com", "  wso2  "); err != nil {
			t.Fatalf("a legitimate employee was rejected: %v", err)
		}

		var domain string
		var verified bool
		if err := h.pool.QueryRow(ctx,
			`SELECT company_domain, work_email_verified FROM auth.users WHERE id = $1`, userID).Scan(&domain, &verified); err != nil {
			t.Fatalf("read company columns: %v", err)
		}
		if domain != "wso2.com" || !verified {
			t.Errorf("stored (domain %q, verified %v), want (wso2.com, true) — the domain must be lowercased", domain, verified)
		}

		// ADR-003's stronger rule: the raw address is never persisted, in any
		// column, anywhere in the schema.
		assertRawWorkEmailNotStored(t, h.pool, "Ada@WSO2.com")
	})

	t.Run("unknown company is accepted and flagged for review", func(t *testing.T) {
		if err := startAndVerify("ada@some-unlisted-co.com", "Some Unlisted Co"); err != nil {
			t.Fatalf("unknown company was rejected, want accept-and-flag: %v", err)
		}
		var claims int
		if err := h.pool.QueryRow(ctx,
			`SELECT count(*) FROM auth.unverified_company_claims WHERE user_id = $1`, userID).Scan(&claims); err != nil {
			t.Fatalf("count claims: %v", err)
		}
		if claims != 1 {
			t.Errorf("unverified_company_claims rows = %d, want 1", claims)
		}
	})

	t.Run("the same mailbox cannot verify a second account", func(t *testing.T) {
		other := h.signUpByEmail(t, "someone-else@example.com")
		if _, err := h.svc.StartCorporateEmailVerification(ctx, auth.StartVerificationRequest{
			UserID: other.UserID, Purpose: auth.VerificationPurposeCorporateEmail, Target: "ada@some-unlisted-co.com",
		}); err != nil {
			t.Fatalf("start for the second account: %v", err)
		}
		_, err := h.svc.VerifyCorporateEmailCode(ctx, auth.VerifyCodeRequest{
			UserID: other.UserID, Purpose: auth.VerificationPurposeCorporateEmail,
			Target: "ada@some-unlisted-co.com", Code: h.emailer.lastCode(), CompanyName: "Some Unlisted Co",
		})
		if err == nil {
			t.Fatal("the same work email verified a second account")
		}
		if !isSentinel(err, apperror.ErrConflict) {
			t.Errorf("error = %v, want ErrConflict", err)
		}
	})
}

// assertRawWorkEmailNotStored greps every text-ish column of every auth table
// for the raw address. This is the structural version of the rule: not "the
// code doesn't return it" but "it isn't anywhere".
func assertRawWorkEmailNotStored(t *testing.T, pool *pgxpool.Pool, rawAddress string) {
	t.Helper()
	rows, err := pool.Query(context.Background(), `
		SELECT table_name, column_name
		FROM information_schema.columns
		WHERE table_schema = 'auth' AND data_type IN ('text', 'character varying')`)
	if err != nil {
		t.Fatalf("list columns: %v", err)
	}
	type col struct{ table, column string }
	var cols []col
	for rows.Next() {
		var c col
		if err := rows.Scan(&c.table, &c.column); err != nil {
			t.Fatalf("scan column: %v", err)
		}
		cols = append(cols, c)
	}
	rows.Close()

	for _, c := range cols {
		var hits int
		q := fmt.Sprintf(`SELECT count(*) FROM auth.%s WHERE lower(%s) = lower($1)`, c.table, c.column)
		if err := pool.QueryRow(context.Background(), q, rawAddress).Scan(&hits); err != nil {
			t.Fatalf("scan %s.%s: %v", c.table, c.column, err)
		}
		if hits != 0 {
			t.Errorf("the raw work email is stored in auth.%s.%s — it must never be retained past the verification round trip",
				c.table, c.column)
		}
	}
}

// TestRefreshTokenRotation_Integration covers the rotation-as-theft-detection
// rule against real rows, including the replay case.
func TestRefreshTokenRotation_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	session := h.signUpByEmail(t, "ada@example.com")

	rotated, err := h.svc.RefreshSession(ctx, session.RefreshToken)
	if err != nil {
		t.Fatalf("RefreshSession: %v", err)
	}
	if rotated.RefreshToken == session.RefreshToken {
		t.Error("the refresh token was not rotated")
	}
	if rotated.UserID != session.UserID {
		t.Errorf("rotated session belongs to %q, want %q", rotated.UserID, session.UserID)
	}

	// Replaying the original token is a theft signal, not a silent success.
	if _, err := h.svc.RefreshSession(ctx, session.RefreshToken); err == nil {
		t.Error("replaying an already-rotated refresh token succeeded, want rejection")
	} else if !isSentinel(err, apperror.ErrUnauthorized) {
		t.Errorf("error = %v, want ErrUnauthorized", err)
	}

	// The raw token is never stored — only its hash.
	var stored int
	if err := h.pool.QueryRow(ctx,
		`SELECT count(*) FROM auth.refresh_tokens WHERE token_hash = $1`, session.RefreshToken).Scan(&stored); err != nil {
		t.Fatalf("count: %v", err)
	}
	if stored != 0 {
		t.Error("the raw refresh token appears in token_hash — only its SHA-256 may be persisted")
	}

	// Logout is idempotent all the way down.
	if err := h.svc.RevokeSession(ctx, rotated.RefreshToken); err != nil {
		t.Fatalf("RevokeSession: %v", err)
	}
	if err := h.svc.RevokeSession(ctx, rotated.RefreshToken); err != nil {
		t.Fatalf("second RevokeSession: %v", err)
	}
	if err := h.svc.RevokeSession(ctx, "never-issued"); err != nil {
		t.Fatalf("RevokeSession on an unknown token: %v", err)
	}
	if _, err := h.svc.RefreshSession(ctx, rotated.RefreshToken); err == nil {
		t.Error("a revoked refresh token still refreshed, want rejection")
	}
}

// TestTrustedContactsAndSOS_Integration covers the cap, the ownership-scoped
// delete (the IDOR case), and the audit row.
func TestTrustedContactsAndSOS_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	owner := h.signUpByEmail(t, "owner@example.com")
	attacker := h.signUpByEmail(t, "attacker@example.com")

	var first auth.TrustedContact
	for i := 0; i < 3; i++ {
		contact, err := h.svc.AddTrustedContact(ctx, auth.AddTrustedContactRequest{
			UserID: owner.UserID, Name: fmt.Sprintf("Contact %d", i), PhoneNumber: "+9477123456" + fmt.Sprint(i),
		})
		if err != nil {
			t.Fatalf("AddTrustedContact %d: %v", i, err)
		}
		if i == 0 {
			first = contact
		}
	}

	if _, err := h.svc.AddTrustedContact(ctx, auth.AddTrustedContactRequest{
		UserID: owner.UserID, Name: "Fourth", PhoneNumber: "+94771234599",
	}); err == nil {
		t.Error("a 4th trusted contact was accepted, want the cap of 3 enforced")
	} else if !isSentinel(err, apperror.ErrInvalidInput) {
		t.Errorf("error = %v, want ErrInvalidInput", err)
	}

	// IDOR: another user must not be able to delete this contact by id.
	if err := h.svc.RemoveTrustedContact(ctx, auth.RemoveTrustedContactRequest{
		UserID: attacker.UserID, ContactID: first.ID,
	}); err == nil {
		t.Error("a non-owner deleted someone else's trusted contact")
	} else if !isSentinel(err, apperror.ErrForbidden) {
		t.Errorf("error = %v, want ErrForbidden", err)
	}

	stillThere, err := h.svc.ListTrustedContacts(ctx, owner.UserID)
	if err != nil {
		t.Fatalf("ListTrustedContacts: %v", err)
	}
	if len(stillThere) != 3 {
		t.Errorf("owner has %d contacts, want 3 — the non-owner's delete must not have landed", len(stillThere))
	}
	// And listing is self-scoped: the attacker sees none of them.
	attackerContacts, err := h.svc.ListTrustedContacts(ctx, attacker.UserID)
	if err != nil {
		t.Fatalf("ListTrustedContacts(attacker): %v", err)
	}
	if len(attackerContacts) != 0 {
		t.Errorf("another user's list returned %d contacts, want 0", len(attackerContacts))
	}

	result, err := h.svc.TriggerSOS(ctx, auth.TriggerSOSRequest{
		UserID: owner.UserID, ContextMessage: "Coffee at 3pm", Latitude: 6.9271, Longitude: 79.8612,
	})
	if err != nil {
		t.Fatalf("TriggerSOS: %v", err)
	}
	if result.ContactsNotified != 3 {
		t.Errorf("ContactsNotified = %d, want 3", result.ContactsNotified)
	}

	var events int
	if err := h.pool.QueryRow(ctx,
		`SELECT count(*) FROM auth.sos_events WHERE user_id = $1 AND contacts_notified = 3`, owner.UserID).Scan(&events); err != nil {
		t.Fatalf("count sos_events: %v", err)
	}
	if events != 1 {
		t.Errorf("sos_events rows = %d, want 1 — the audit row is written even though the alerts already went out", events)
	}

	// Oversized context message is rejected server-side.
	if _, err := h.svc.TriggerSOS(ctx, auth.TriggerSOSRequest{
		UserID: owner.UserID, ContextMessage: strings.Repeat("a", 501), Latitude: 1, Longitude: 1,
	}); err == nil {
		t.Error("a 501-character context message was accepted, want the 500 cap enforced")
	}

	// Out-of-range coordinates never reach a real maps link.
	if _, err := h.svc.TriggerSOS(ctx, auth.TriggerSOSRequest{
		UserID: owner.UserID, Latitude: 91, Longitude: 0,
	}); err == nil {
		t.Error("latitude 91 was accepted, want rejection")
	}
}

// TestUpdateLastKnownLocation_Integration confirms both the write and the
// event Phase 2's user_location_cache will consume.
func TestUpdateLastKnownLocation_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	session := h.signUpByEmail(t, "ada@example.com")
	before := h.bus.countOf(eventbus.TopicUserLocationUpdated)

	if err := h.svc.UpdateLastKnownLocation(ctx, auth.UpdateLastKnownLocationRequest{
		UserID: session.UserID, Lat: 6.9271, Lng: 79.8612,
	}); err != nil {
		t.Fatalf("UpdateLastKnownLocation: %v", err)
	}

	var lat, lng float64
	if err := h.pool.QueryRow(ctx,
		`SELECT last_location_lat, last_location_lng FROM auth.users WHERE id = $1`, session.UserID).Scan(&lat, &lng); err != nil {
		t.Fatalf("read location: %v", err)
	}
	if lat != 6.9271 || lng != 79.8612 {
		t.Errorf("stored (%v, %v), want (6.9271, 79.8612)", lat, lng)
	}
	if got := h.bus.countOf(eventbus.TopicUserLocationUpdated); got != before+1 {
		t.Errorf("user-location-updated published %d times, want %d", got, before+1)
	}

	if err := h.svc.UpdateLastKnownLocation(ctx, auth.UpdateLastKnownLocationRequest{
		UserID: session.UserID, Lat: 200, Lng: 0,
	}); err == nil {
		t.Error("an out-of-range latitude was accepted")
	}
}

// TestVerifiedTargetsAreUniquePlatformWide covers the partial UNIQUE indexes:
// a second account cannot claim a phone number already verified elsewhere.
func TestVerifiedTargetsAreUniquePlatformWide(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	// Two LinkedIn-linked accounts. The stub server always returns the same
	// sub, so the second account is made directly and then linked.
	first, err := h.svc.CompleteLinkedInOnboarding(ctx, auth.CompleteLinkedInOnboardingRequest{
		AuthorizationCode: "code", RedirectURI: "app://cb", AgeConfirmedOver18: true,
	})
	if err != nil {
		t.Fatalf("CompleteLinkedInOnboarding: %v", err)
	}
	second := h.signUpByEmail(t, "second@example.com")
	if _, err := h.pool.Exec(ctx,
		`UPDATE auth.users SET linkedin_sub = 'other-li-sub', trust_level = 1 WHERE id = $1`, second.UserID); err != nil {
		t.Fatalf("seed second linkedin_sub: %v", err)
	}

	verifyPhone := func(userID, phone string) error {
		if _, err := h.svc.StartPhoneVerification(ctx, auth.StartVerificationRequest{
			UserID: userID, Purpose: auth.VerificationPurposePhone, Target: phone,
		}); err != nil {
			return err
		}
		_, err := h.svc.VerifyPhoneCode(ctx, auth.VerifyCodeRequest{
			UserID: userID, Purpose: auth.VerificationPurposePhone, Target: phone, Code: h.smser.lastCode(),
		})
		return err
	}

	if err := verifyPhone(first.UserID, "+94771234567"); err != nil {
		t.Fatalf("first account phone verification: %v", err)
	}
	err = verifyPhone(second.UserID, "+94771234567")
	if err == nil {
		t.Fatal("the same phone number verified on two accounts")
	}
	if !isSentinel(err, apperror.ErrConflict) {
		t.Errorf("error = %v, want ErrConflict (the partial UNIQUE index is what resolves the race)", err)
	}
}

// TestRequireLinkedIn_Integration: LinkedIn is a hard prerequisite for Level
// 2+, enforced before any OTP is sent (an OTP costs real money).
func TestRequireLinkedIn_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	session := h.signUpByEmail(t, "ada@example.com") // Level 0, no LinkedIn
	before := len(h.smser.codes)

	_, err := h.svc.StartPhoneVerification(ctx, auth.StartVerificationRequest{
		UserID: session.UserID, Purpose: auth.VerificationPurposePhone, Target: "+94771234567",
	})
	if err == nil {
		t.Fatal("phone verification started for a Level 0 account with no LinkedIn")
	}
	if !isSentinel(err, apperror.ErrForbidden) {
		t.Errorf("error = %v, want ErrForbidden", err)
	}
	if len(h.smser.codes) != before {
		t.Error("an SMS was sent before the LinkedIn prerequisite was checked")
	}
}

// TestFederatedSignup_RequiresNonce_Integration is the module-level half of
// the replay fix: the identity package rejects a bad nonce (identity_test.go),
// and this proves the module actually threads the caller's nonce through to
// it rather than dropping it.
func TestFederatedSignup_RequiresNonce_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	h.apple.validTokens["good-token"] = identity.VerifiedIdentity{Subject: "apple-sub-1", Name: "Ada"}

	if _, err := h.svc.CompleteFederatedSignup(ctx, auth.CompleteFederatedSignupRequest{
		Provider: auth.FederatedProviderApple, IDToken: "good-token", AgeConfirmedOver18: true,
	}); err == nil {
		t.Error("federated signup with no nonce succeeded, want rejection")
	}

	session, err := h.svc.CompleteFederatedSignup(ctx, auth.CompleteFederatedSignupRequest{
		Provider: auth.FederatedProviderApple, IDToken: "good-token", Nonce: "n-1", AgeConfirmedOver18: true,
	})
	if err != nil {
		t.Fatalf("federated signup with a nonce: %v", err)
	}
	if !session.IsNewUser {
		t.Error("IsNewUser = false, want true")
	}

	var identities int
	if err := h.pool.QueryRow(ctx,
		`SELECT count(*) FROM auth.user_identities WHERE provider = 'apple' AND subject = 'apple-sub-1'`).Scan(&identities); err != nil {
		t.Fatalf("count identities: %v", err)
	}
	if identities != 1 {
		t.Errorf("user_identities rows = %d, want 1", identities)
	}
}

// TestAgeGate_Integration: no account is ever created without the 18+
// confirmation, on any path.
func TestAgeGate_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	h.apple.validTokens["good-token"] = identity.VerifiedIdentity{Subject: "apple-sub-1"}

	if _, err := h.svc.CompleteFederatedSignup(ctx, auth.CompleteFederatedSignupRequest{
		Provider: auth.FederatedProviderApple, IDToken: "good-token", Nonce: "n", AgeConfirmedOver18: false,
	}); err == nil {
		t.Error("federated signup without the age confirmation created an account")
	}

	if _, err := h.svc.CompleteLinkedInOnboarding(ctx, auth.CompleteLinkedInOnboardingRequest{
		AuthorizationCode: "code", RedirectURI: "app://cb", AgeConfirmedOver18: false,
	}); err == nil {
		t.Error("LinkedIn signup without the age confirmation created an account")
	}

	if _, err := h.svc.StartEmailSignup(ctx, auth.StartVerificationRequest{
		Purpose: auth.VerificationPurposeEmailSignup, Target: "ada@example.com",
	}); err != nil {
		t.Fatalf("StartEmailSignup: %v", err)
	}
	if _, err := h.svc.CompleteEmailSignup(ctx, auth.CompleteEmailSignupRequest{
		Email: "ada@example.com", Code: h.emailer.lastCode(), AgeConfirmedOver18: false,
	}); err == nil {
		t.Error("email signup without the age confirmation created an account")
	}

	var users int
	if err := h.pool.QueryRow(ctx, `SELECT count(*) FROM auth.users`).Scan(&users); err != nil {
		t.Fatalf("count users: %v", err)
	}
	if users != 0 {
		t.Errorf("auth.users row count = %d, want 0 — no path may create an account without the age gate", users)
	}
}

// isSentinel is errors.Is, spelled out here so the assertion reads the same
// way in every test above.
func isSentinel(err, sentinel error) bool {
	for err != nil {
		if err == sentinel {
			return true
		}
		unwrapped, ok := err.(interface{ Unwrap() error })
		if !ok {
			return false
		}
		err = unwrapped.Unwrap()
	}
	return false
}
