package store

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
)

type countingVerifier struct {
	calls atomic.Int32
	err   error
}

func (c *countingVerifier) Verify(context.Context, Request) (Transaction, error) {
	c.calls.Add(1)
	return Transaction{TransactionID: "t"}, c.err
}

func TestResilientRetriesOnlyTransientFailures(t *testing.T) {
	transient := &countingVerifier{err: ErrUnavailable}
	if _, err := NewResilient(transient, nil).Verify(context.Background(), Request{}); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("err = %v", err)
	}
	if n := transient.calls.Load(); n != maxAttempts {
		t.Fatalf("a transient failure was tried %d times, want %d", n, maxAttempts)
	}

	rejected := &countingVerifier{err: ErrRejected}
	if _, err := NewResilient(rejected, nil).Verify(context.Background(), Request{}); !errors.Is(err, ErrRejected) {
		t.Fatalf("err = %v", err)
	}
	if n := rejected.calls.Load(); n != 1 {
		t.Fatalf("a rejection was tried %d times, want 1", n)
	}
}

// A run of bad tokens must not open the breaker on everyone else; a run of
// outages must.
func TestResilientBreaker(t *testing.T) {
	rejected := &countingVerifier{err: ErrRejected}
	r := NewResilient(rejected, nil)
	for range breakerThreshold * 2 {
		_, _ = r.Verify(context.Background(), Request{})
	}
	rejected.err = nil
	if _, err := r.Verify(context.Background(), Request{}); err != nil {
		t.Fatalf("rejections opened the breaker: %v", err)
	}

	down := &countingVerifier{err: ErrUnavailable}
	r = NewResilient(down, nil)
	for range breakerThreshold {
		_, _ = r.Verify(context.Background(), Request{})
	}
	before := down.calls.Load()
	if _, err := r.Verify(context.Background(), Request{}); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("err = %v", err)
	}
	if down.calls.Load() != before {
		t.Fatal("an open breaker still called the store")
	}
}

func TestUnconfiguredFailsClosed(t *testing.T) {
	if _, err := (ByPlatform{}).Verify(context.Background(), Request{Platform: IOS}); !errors.Is(err, ErrNotConfigured) {
		t.Fatalf("ios with nothing configured: %v", err)
	}
	if err := (ByPlatform{}).Finish(context.Background(), Android, Consumable, "p", "t"); !errors.Is(err, ErrNotConfigured) {
		t.Fatalf("android finish with nothing configured: %v", err)
	}
	if err := NewResilient(Unconfigured{}, nil).Finish(context.Background(), Android, Consumable, "p", "t"); !errors.Is(err, ErrNotConfigured) {
		t.Fatalf("resilient finish without a finisher: %v", err)
	}
}
