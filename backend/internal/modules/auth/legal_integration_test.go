package auth_test

import (
	"context"
	"errors"
	"testing"

	"professional-meetups-monolith/backend/internal/modules/auth/repository"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

func TestLegalAcceptance_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	user := seedUser(t, h.pool, "Consent Person")

	mustExec(t, h.pool, `DELETE FROM ops.legal_documents`)
	t.Cleanup(func() { mustExec(t, h.pool, `DELETE FROM ops.legal_documents`) })
	if ok, err := h.svc.HasAcceptedLegal(ctx, user); err != nil || !ok {
		t.Fatalf("nothing published is nothing to accept: %v, %v", ok, err)
	}
	if _, err := h.svc.GetLegalDocuments(ctx); !errors.Is(err, apperror.ErrNotFound) {
		t.Fatalf("nothing published: %v", err)
	}
	store := repository.NewLegalRepository(h.pool)
	if err := store.Publish(ctx, repository.LegalDocuments{Version: "v1", Terms: "t1", Privacy: "p1"}); err != nil {
		t.Fatal(err)
	}
	if ok, err := h.svc.HasAcceptedLegal(ctx, user); err != nil || ok {
		t.Fatalf("before accepting: %v, %v", ok, err)
	}
	err := h.svc.AcceptLegal(ctx, user, "an-old-version", "1.1.0+7", "ios")
	if !errors.Is(err, apperror.ErrConflict) {
		t.Fatalf("an old version: %v, want a conflict", err)
	}
	for range 2 { // repeating it changes nothing
		if err := h.svc.AcceptLegal(ctx, user, "v1", "1.1.0+7", "ios"); err != nil {
			t.Fatal(err)
		}
	}
	if ok, err := h.svc.HasAcceptedLegal(ctx, user); err != nil || !ok {
		t.Fatalf("after accepting: %v, %v", ok, err)
	}
	if n := countRows(t, h.pool, `SELECT count(*) FROM auth.legal_acceptances WHERE user_id = $1`, user); n != 1 {
		t.Errorf("%d rows, want 1", n)
	}

	// A new version asks again, with no deploy.
	mustExec(t, h.pool, `UPDATE ops.legal_documents SET published_at = now() - interval '1 day'`)
	if err := store.Publish(ctx, repository.LegalDocuments{Version: "v2", Terms: "t2", Privacy: "p2"}); err != nil {
		t.Fatal(err)
	}
	if docs, err := h.svc.GetLegalDocuments(ctx); err != nil || docs.Terms != "t2" {
		t.Fatalf("current = %+v, %v", docs, err)
	}
	if ok, err := h.svc.HasAcceptedLegal(ctx, user); err != nil || ok {
		t.Fatalf("after a new version: %v, %v", ok, err)
	}
	mustExec(t, h.pool, `DELETE FROM auth.users WHERE id = $1`, user)
	if n := countRows(t, h.pool, `SELECT count(*) FROM auth.legal_acceptances WHERE user_id = $1`, user); n != 0 {
		t.Errorf("%d rows outlived the account", n)
	}
}
