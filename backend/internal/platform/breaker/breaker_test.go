package breaker

import (
	"errors"
	"testing"
	"time"
)

var errBoom = errors.New("boom")

func TestBreaker_ClosedAllowsCalls(t *testing.T) {
	b := New(3, time.Minute)
	calls := 0
	err := b.Execute(func() error {
		calls++
		return nil
	})
	if err != nil {
		t.Fatalf("Execute() error = %v, want nil", err)
	}
	if calls != 1 {
		t.Fatalf("calls = %d, want 1", calls)
	}
}

func TestBreaker_OpensAfterThreshold(t *testing.T) {
	b := New(3, time.Minute)

	for i := 0; i < 3; i++ {
		if err := b.Execute(func() error { return errBoom }); !errors.Is(err, errBoom) {
			t.Fatalf("attempt %d: Execute() error = %v, want errBoom", i, err)
		}
	}

	// The breaker should now be open — fn must not even run.
	ran := false
	err := b.Execute(func() error {
		ran = true
		return nil
	})
	if !errors.Is(err, ErrOpen) {
		t.Fatalf("Execute() error = %v, want ErrOpen", err)
	}
	if ran {
		t.Error("fn ran while breaker was open, want it skipped entirely")
	}
}

func TestBreaker_StaysOpenUntilResetTimeout(t *testing.T) {
	b := New(1, 50*time.Millisecond)

	if err := b.Execute(func() error { return errBoom }); !errors.Is(err, errBoom) {
		t.Fatalf("Execute() error = %v, want errBoom", err)
	}

	// Immediately after — still open.
	if err := b.Execute(func() error { return nil }); !errors.Is(err, ErrOpen) {
		t.Fatalf("Execute() error = %v, want ErrOpen (too soon)", err)
	}

	time.Sleep(60 * time.Millisecond)

	// Reset timeout elapsed — one trial call should now be allowed
	// through (half-open), and a success closes the breaker.
	ran := false
	if err := b.Execute(func() error { ran = true; return nil }); err != nil {
		t.Fatalf("Execute() error = %v, want nil (half-open trial)", err)
	}
	if !ran {
		t.Fatal("fn did not run for the half-open trial call")
	}

	// Breaker should be closed again now — a second call runs normally.
	ran = false
	if err := b.Execute(func() error { ran = true; return nil }); err != nil {
		t.Fatalf("Execute() error = %v, want nil (closed again)", err)
	}
	if !ran {
		t.Fatal("fn did not run after breaker closed")
	}
}

func TestBreaker_HalfOpenFailureReopens(t *testing.T) {
	b := New(1, 30*time.Millisecond)

	if err := b.Execute(func() error { return errBoom }); !errors.Is(err, errBoom) {
		t.Fatalf("Execute() error = %v, want errBoom", err)
	}

	time.Sleep(40 * time.Millisecond)

	// Half-open trial fails — breaker must re-open, not close.
	if err := b.Execute(func() error { return errBoom }); !errors.Is(err, errBoom) {
		t.Fatalf("half-open trial: Execute() error = %v, want errBoom", err)
	}

	// Immediately after a failed half-open trial, the breaker should be
	// open again (freshly re-opened, so still within its own reset
	// window) — the next call must be rejected without running fn.
	ran := false
	err := b.Execute(func() error { ran = true; return nil })
	if !errors.Is(err, ErrOpen) {
		t.Fatalf("Execute() error = %v, want ErrOpen (re-opened after failed half-open trial)", err)
	}
	if ran {
		t.Error("fn ran immediately after a failed half-open trial, want breaker re-opened")
	}
}

func TestBreaker_SuccessResetsFailureCount(t *testing.T) {
	b := New(2, time.Minute)

	// One failure, then a success — failure count should reset, so a
	// second failure alone shouldn't be enough to open a threshold-2
	// breaker.
	_ = b.Execute(func() error { return errBoom })
	_ = b.Execute(func() error { return nil })

	if err := b.Execute(func() error { return errBoom }); !errors.Is(err, errBoom) {
		t.Fatalf("Execute() error = %v, want errBoom", err)
	}

	// Still closed — only one consecutive failure since the reset.
	ran := false
	if err := b.Execute(func() error { ran = true; return nil }); err != nil {
		t.Fatalf("Execute() error = %v, want nil (still closed)", err)
	}
	if !ran {
		t.Fatal("fn did not run — breaker opened prematurely")
	}
}
