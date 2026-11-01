package meetup_test

import (
	"context"
	"testing"
	"time"

	"github.com/google/uuid"

	meetuprepo "professional-meetups-monolith/backend/internal/modules/meetup/repository"
	"professional-meetups-monolith/backend/internal/platform/db"
)

// V-20 (gap tracker #69): the subscription cache's hand-written SQL named
// the table without its schema, so on any connection whose search_path does
// not include `meetup` (every one here) both calls failed. Plan 29B feeds
// this cache for real, so it has to work.
func TestSubscriptionCacheUpsertAndRead(t *testing.T) {
	dbURL := requirePostgres(t)
	if err := db.Migrate(dbURL, migrationsURL); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	ctx := context.Background()
	pool, err := db.New(ctx, dbURL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)

	cache := meetuprepo.NewSubscriptionCacheRepository(pool)
	user := uuid.NewString()
	t0 := time.Now().UTC().Truncate(time.Microsecond)

	if ok, err := cache.IsEntitled(ctx, user); err != nil || ok {
		t.Fatalf("unseen user: %v, %v; want false, nil", ok, err)
	}
	if applied, err := cache.Upsert(ctx, user, "pro", true, t0); err != nil || !applied {
		t.Fatalf("activate: %v, %v", applied, err)
	}
	if ok, err := cache.IsEntitled(ctx, user); err != nil || !ok {
		t.Fatalf("after activation: %v, %v; want true", ok, err)
	}
	// An older event (redelivered out of order) does not undo a newer one.
	if applied, err := cache.Upsert(ctx, user, "pro", false, t0.Add(-time.Minute)); err != nil || applied {
		t.Fatalf("stale deactivation: applied=%v, %v; want skipped", applied, err)
	}
	if applied, err := cache.Upsert(ctx, user, "pro", false, t0.Add(time.Minute)); err != nil || !applied {
		t.Fatalf("deactivate: %v, %v", applied, err)
	}
	if ok, _ := cache.IsEntitled(ctx, user); ok {
		t.Fatal("still entitled after a newer deactivation")
	}
}
