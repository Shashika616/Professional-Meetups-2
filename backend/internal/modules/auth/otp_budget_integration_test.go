package auth_test

// Plan 30B, tracker #106: daily per-target OTP budgets in Postgres. Five
// sends and ten failed guesses per target, purpose and Asia/Colombo day,
// not reset by asking for a new code, and never applied to the
// allowlisted test targets (TESTING-NOTES.md).

import (
	"bytes"
	"context"
	"errors"
	"image"
	"image/jpeg"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"professional-meetups-monolith/backend/internal/modules/auth"
	"professional-meetups-monolith/backend/internal/modules/auth/repository"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// skipCooldown deletes the pending code, which is all the one-minute
// resend cooldown looks at: a test cannot wait a minute between sends.
func (h *harness) skipCooldown(t *testing.T) {
	t.Helper()
	if _, err := h.pool.Exec(context.Background(), `DELETE FROM auth.verification_codes`); err != nil {
		t.Fatal(err)
	}
}

func startLogin(h *harness, address string) error {
	_, err := h.svc.StartEmailLogin(context.Background(), auth.StartVerificationRequest{
		Purpose: auth.VerificationPurposeEmailLogin, Target: address,
	})
	return err
}

func completeLogin(h *harness, address, code string) error {
	_, err := h.svc.CompleteEmailLogin(context.Background(), auth.VerifyCodeRequest{
		Purpose: auth.VerificationPurposeEmailLogin, Target: address, Code: code,
	})
	return err
}

func TestOTPSendsAreCappedPerTargetPerDay_Integration(t *testing.T) {
	h := newHarness(t)
	const victim = "victim@example.com"
	for i := 1; i <= 5; i++ {
		h.skipCooldown(t)
		if err := startLogin(h, victim); err != nil {
			t.Fatalf("send %d refused: %v", i, err)
		}
	}
	sent := len(h.emailer.codes)
	h.skipCooldown(t)
	err := startLogin(h, victim)
	if !errors.Is(err, apperror.ErrRateLimited) || !strings.Contains(err.Error(), "today") {
		t.Fatalf("the 6th send: %v, want the daily limit", err)
	}
	if len(h.emailer.codes) != sent {
		t.Error("an e-mail went out past the daily limit")
	}
	// Another spelling of the same address shares the budget.
	h.skipCooldown(t)
	if err := startLogin(h, "  Victim@Example.com "); !errors.Is(err, apperror.ErrRateLimited) {
		t.Errorf("another spelling got a fresh budget: %v", err)
	}
	// Another address does not.
	if err := startLogin(h, "someone.else@example.com"); err != nil {
		t.Errorf("another address was limited: %v", err)
	}

	// The refusal reads the same whether or not an account exists.
	h.signUpByEmail(t, "has.account@example.com")
	for i := 0; i < 4; i++ { // signup used one send of email_signup, not login
		h.skipCooldown(t)
		_ = startLogin(h, "has.account@example.com")
	}
	h.skipCooldown(t)
	_ = startLogin(h, "has.account@example.com")
	h.skipCooldown(t)
	withAccount := startLogin(h, "has.account@example.com")
	if withAccount == nil || withAccount.Error() != err.Error() {
		t.Errorf("the refusal differs when an account exists: %q vs %q", withAccount, err)
	}

	// No address is stored.
	var leaked int
	_ = h.pool.QueryRow(context.Background(),
		`SELECT count(*) FROM auth.otp_budgets WHERE position('victim'::bytea IN target_hash) > 0 OR length(target_hash) <> 32`,
	).Scan(&leaked)
	if leaked != 0 {
		t.Error("the budget table holds something other than 32-byte hashes")
	}
}

// Ten failed guesses a day, and a new code does not give more.
func TestOTPFailedGuessesAreCappedAcrossCodes_Integration(t *testing.T) {
	h := newHarness(t)
	const address = "target@example.com"
	h.signUpByEmail(t, address)
	for code := 0; code < 2; code++ {
		h.skipCooldown(t)
		if err := startLogin(h, address); err != nil {
			t.Fatal(err)
		}
		for guess := 0; guess < 5; guess++ { // the per-code cap is five
			if err := completeLogin(h, address, "000000"); err == nil {
				t.Fatal("a wrong code signed in")
			}
		}
	}
	h.skipCooldown(t)
	if err := startLogin(h, address); err != nil {
		t.Fatal(err)
	}
	err := completeLogin(h, address, h.emailer.lastCode())
	if !errors.Is(err, apperror.ErrRateLimited) {
		t.Fatalf("the right code after ten failures today: %v, want the daily limit", err)
	}
}

// A correct guess is handed back, so signing in normally never eats into
// the failure budget.
func TestACorrectCodeDoesNotCountAsAFailure_Integration(t *testing.T) {
	h := newHarness(t)
	const address = "normal@example.com"
	h.signUpByEmail(t, address)
	h.skipCooldown(t)
	if err := startLogin(h, address); err != nil {
		t.Fatal(err)
	}
	if err := completeLogin(h, address, "000000"); err == nil {
		t.Fatal("a wrong code signed in")
	}
	if err := completeLogin(h, address, h.emailer.lastCode()); err != nil {
		t.Fatal(err)
	}
	var failed int
	_ = h.pool.QueryRow(context.Background(),
		`SELECT coalesce(sum(failed_guesses), 0) FROM auth.otp_budgets WHERE purpose = 'email_login'`).Scan(&failed)
	if failed != 1 {
		t.Errorf("failed guesses recorded: %d, want 1", failed)
	}
}

// Thirty guesses at once cannot get more than the ten the day allows.
func TestOTPGuessBudgetHoldsUnderConcurrency_Integration(t *testing.T) {
	h := newHarness(t)
	budgets := repository.NewOTPBudgetRepository(h.pool)
	hash := make([]byte, 32)
	hash[0] = 7
	var taken atomic.Int32
	var wg sync.WaitGroup
	for i := 0; i < 30; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if ok, err := budgets.TakeGuess(context.Background(), hash, "email_login", 10); err == nil && ok {
				taken.Add(1)
			}
		}()
	}
	wg.Wait()
	if got := taken.Load(); got != 10 {
		t.Errorf("%d guesses taken under concurrency, want 10", got)
	}
}

// THE SIGN-IN TEST CODES MUST KEEP WORKING (plan 30 §1). A seeded test
// account signs in twenty times in a row with the fixed code, and no
// budget row is ever written for it.
func TestASeededTestAccountSignsInTwentyTimesInARow_Integration(t *testing.T) {
	const testAccount = "l2.a@meetups.test"
	t.Setenv("TEST_OTP_BYPASS_EMAILS", testAccount+",l3.a@meetups.test")
	h := newHarness(t)
	ctx := context.Background()
	if _, err := h.svc.StartEmailSignup(ctx, auth.StartVerificationRequest{Purpose: auth.VerificationPurposeEmailSignup, Target: testAccount}); err != nil {
		t.Fatal(err)
	}
	if _, err := h.svc.CompleteEmailSignup(ctx, auth.CompleteEmailSignupRequest{Email: testAccount, Code: "123456", AgeConfirmedOver18: true}); err != nil {
		t.Fatal(err)
	}
	for i := 1; i <= 20; i++ {
		if err := startLogin(h, testAccount); err != nil {
			t.Fatalf("sign-in %d: start: %v", i, err)
		}
		if i%3 == 0 { // a mistyped code now and then
			if err := completeLogin(h, testAccount, "999999"); err == nil {
				t.Fatal("a wrong code signed in")
			}
		}
		if err := completeLogin(h, testAccount, "123456"); err != nil {
			t.Fatalf("sign-in %d: %v", i, err)
		}
	}
	var rows int
	_ = h.pool.QueryRow(ctx, `SELECT count(*) FROM auth.otp_budgets`).Scan(&rows)
	if rows != 0 {
		t.Errorf("%d budget rows written for an allowlisted test account", rows)
	}
}

// Plan 30B, 3.3: a last known location is kept to 3 decimals (about
// 110 m), whatever precision the app sends, and so is every copy of it.
func TestLastKnownLocationIsStoredRounded_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	user := h.signUpByEmail(t, "located@example.com")
	if err := h.svc.UpdateLastKnownLocation(ctx, auth.UpdateLastKnownLocationRequest{
		UserID: user.UserID, Lat: 6.927123456, Lng: 79.861249876,
	}); err != nil {
		t.Fatal(err)
	}
	var lat, lng float64
	if err := h.pool.QueryRow(ctx, `SELECT last_location_lat, last_location_lng FROM auth.users WHERE id = $1`, user.UserID).Scan(&lat, &lng); err != nil {
		t.Fatal(err)
	}
	if lat != 6.927 || lng != 79.861 {
		t.Errorf("stored (%v, %v), want (6.927, 79.861)", lat, lng)
	}
}

// Plan 30B, 3.3: a last known location is forgotten after 30 days, and an
// SOS event, with its coordinates, deleted after 90.
func TestLocationRetentionForgetsOldLocationsAndSOSEvents_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	user := h.signUpByEmail(t, "retention@example.com")
	if err := h.svc.UpdateLastKnownLocation(ctx, auth.UpdateLastKnownLocationRequest{UserID: user.UserID, Lat: 6.9, Lng: 79.8}); err != nil {
		t.Fatal(err)
	}
	if _, err := h.pool.Exec(ctx, `UPDATE auth.users SET last_location_updated_at = now() - interval '31 days' WHERE id = $1`, user.UserID); err != nil {
		t.Fatal(err)
	}
	if _, err := h.pool.Exec(ctx, `INSERT INTO auth.sos_events (user_id, latitude, longitude, triggered_at) VALUES
		($1, 6.9, 79.8, now() - interval '91 days'), ($1, 6.9, 79.8, now() - interval '1 day')`, user.UserID); err != nil {
		t.Fatal(err)
	}
	n, err := h.svc.SweepLocationRetention(ctx)
	if err != nil || n != 2 {
		t.Fatalf("affected %d, %v; want 2 (one location, one SOS event)", n, err)
	}
	var lat *float64
	_ = h.pool.QueryRow(ctx, `SELECT last_location_lat FROM auth.users WHERE id = $1`, user.UserID).Scan(&lat)
	if lat != nil {
		t.Error("a 31-day-old location was kept")
	}
	var events int
	_ = h.pool.QueryRow(ctx, `SELECT count(*) FROM auth.sos_events WHERE user_id = $1`, user.UserID).Scan(&events)
	if events != 1 {
		t.Errorf("%d SOS events left, want the recent one", events)
	}
}

// Plan 30D: ten uploads an hour per account, counted in Postgres.
func TestPhotoUploadsAreCappedPerHour_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	user := h.signUpByEmail(t, "uploader@example.com")
	var b bytes.Buffer
	if err := jpeg.Encode(&b, image.NewRGBA(image.Rect(0, 0, 64, 64)), nil); err != nil {
		t.Fatal(err)
	}
	for i := 1; i <= 10; i++ {
		if _, err := h.svc.SetProfilePhoto(ctx, user.UserID, b.Bytes()); err != nil {
			t.Fatalf("upload %d: %v", i, err)
		}
	}
	if _, err := h.svc.SetProfilePhoto(ctx, user.UserID, b.Bytes()); !errors.Is(err, apperror.ErrRateLimited) {
		t.Errorf("the 11th upload: %v, want rate limited", err)
	}
	var rows int
	_ = h.pool.QueryRow(ctx, `SELECT count(*) FROM auth.user_photos WHERE user_id = $1 AND bytes <= 102400 AND width = 320`, user.UserID).Scan(&rows)
	if rows != 1 {
		t.Errorf("%d photo rows, want the one", rows)
	}
}
