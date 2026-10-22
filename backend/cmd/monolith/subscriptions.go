package main

import (
	"context"
	"fmt"
	"log/slog"

	"professional-meetups-monolith/backend/internal/eventbus"
	"professional-meetups-monolith/backend/internal/modules/auth"
	"professional-meetups-monolith/backend/internal/modules/meetup"
	meetuprepo "professional-meetups-monolith/backend/internal/modules/meetup/repository"
)

// subscriptionDeps is everything the cross-module event handlers touch.
type subscriptionDeps struct {
	bus               *eventbus.InMemoryBus
	userDisplayCache  meetuprepo.UserDisplayCacheRepository
	userLocationCache meetuprepo.UserLocationCacheRepository
	subscriptionCache meetuprepo.SubscriptionCacheRepository
	meetupService     meetup.Service
	authService       auth.Service
	logger            *slog.Logger
}

// registerSubscriptions wires every cross-module event handler onto the bus.
// Moved out of run() unchanged (#96): it is one self-contained concern, and
// main.go had grown to 830 lines.
func registerSubscriptions(d subscriptionDeps) {
	// --- event subscriptions ---
	//
	// Every handler below is idempotent and order-guarded on the payload's
	// own OccurredAt (never time.Now()), so a redelivered or out-of-order
	// event no-ops rather than regressing newer data. A handler returning an
	// error is logged and swallowed by the d.bus (ADR-001 §4) — a consumer
	// problem must never fail the business write that triggered it.

	// auth -> meetup: keep the display cache current. Both topics carry the
	// same payload shape and mean the same thing to this cache ("here is
	// this user's current display info"), so they share one handler.
	displayCacheHandler := func(ctx context.Context, e eventbus.Event) error {
		switch payload := e.Payload.(type) {
		case eventbus.UserOnboardedPayload:
			_, err := d.userDisplayCache.Upsert(ctx, payload.UserID, payload.FullName, payload.ProfilePhotoURL, payload.TrustLevel, payload.OccurredAt)
			return err
		case eventbus.UserProfileUpdatedPayload:
			_, err := d.userDisplayCache.Upsert(ctx, payload.UserID, payload.FullName, payload.ProfilePhotoURL, payload.TrustLevel, payload.OccurredAt)
			return err
		default:
			return fmt.Errorf("user display cache: unexpected payload type %T on %s", e.Payload, e.Topic)
		}
	}
	d.bus.Subscribe(eventbus.TopicUserOnboarded, displayCacheHandler)
	d.bus.Subscribe(eventbus.TopicUserProfileUpdated, displayCacheHandler)

	// auth -> meetup: last-known location, which backs the nearby-notify
	// fan-out (never the browse-screen radius filter — that uses the
	// caller's own fresh coordinate, passed per request).
	d.bus.Subscribe(eventbus.TopicUserLocationUpdated, func(ctx context.Context, e eventbus.Event) error {
		payload, ok := e.Payload.(eventbus.UserLocationUpdatedPayload)
		if !ok {
			return fmt.Errorf("user location cache: unexpected payload type %T", e.Payload)
		}
		_, err := d.userLocationCache.Upsert(ctx, payload.UserID, payload.Lat, payload.Lng, payload.OccurredAt)
		return err
	})

	// billing -> meetup: entitlement cache. NOTHING PUBLISHES THESE UNTIL
	// PHASE 3 — wired now anyway, the same bootstrapping pattern Phase 1
	// used for publishing events nothing consumed yet, so Phase 3 adds a
	// publisher rather than also having to add plumbing here.
	d.bus.Subscribe(eventbus.TopicSubscriptionActivated, func(ctx context.Context, e eventbus.Event) error {
		payload, ok := e.Payload.(eventbus.SubscriptionActivatedPayload)
		if !ok {
			return fmt.Errorf("subscription cache: unexpected payload type %T", e.Payload)
		}
		_, err := d.subscriptionCache.Upsert(ctx, payload.UserID, payload.Tier, true, payload.OccurredAt)
		return err
	})
	d.bus.Subscribe(eventbus.TopicSubscriptionDeactivated, func(ctx context.Context, e eventbus.Event) error {
		payload, ok := e.Payload.(eventbus.SubscriptionDeactivatedPayload)
		if !ok {
			return fmt.Errorf("subscription cache: unexpected payload type %T", e.Payload)
		}
		_, err := d.subscriptionCache.Upsert(ctx, payload.UserID, payload.Tier, false, payload.OccurredAt)
		return err
	})

	// meetup -> meetup: the nearby-notify fan-out. The one same-module,
	// different-subscription consumer — CreateMeetup publishes it, and this
	// handler notifies everyone with a non-stale cached location within 40km.
	d.bus.Subscribe(eventbus.TopicMeetupCreated, func(ctx context.Context, e eventbus.Event) error {
		payload, ok := e.Payload.(eventbus.MeetupCreatedPayload)
		if !ok {
			return fmt.Errorf("nearby notify: unexpected payload type %T", e.Payload)
		}
		return d.meetupService.HandleMeetupCreated(ctx, meetup.NearbyNotifyPayload{
			MeetupID:    payload.MeetupID,
			HostUserID:  payload.HostUserID,
			Intent:      payload.Intent,
			LocationLat: payload.LocationLat,
			LocationLng: payload.LocationLng,
		})
	})

	// meetup -> auth: the rating cache Phase 1 deliberately left unwired,
	// because only the meetup module publishes this and it didn't exist yet.
	// Its publisher exists as of this phase, so the subscription does too.
	d.bus.Subscribe(eventbus.TopicRatingUpdated, func(ctx context.Context, e eventbus.Event) error {
		payload, ok := e.Payload.(eventbus.RatingUpdatedPayload)
		if !ok {
			return fmt.Errorf("rating cache: unexpected payload type %T", e.Payload)
		}
		_, err := d.authService.ApplyRatingUpdate(ctx, payload.UserID, payload.RatingAverage, payload.RatingCount, payload.OccurredAt)
		return err
	})

	// meetup -> auth: the profile's "meetups completed" figure, on exactly
	// the same terms as the rating cache above — the meetup module owns the
	// meetups and recomputes the total whenever one completes, this is the
	// only writer of auth.users.meetups_completed.
	d.bus.Subscribe(eventbus.TopicMeetupsCompletedUpdated, func(ctx context.Context, e eventbus.Event) error {
		payload, ok := e.Payload.(eventbus.MeetupsCompletedUpdatedPayload)
		if !ok {
			return fmt.Errorf("meetups-completed cache: unexpected payload type %T", e.Payload)
		}
		_, err := d.authService.ApplyMeetupsCompletedUpdate(ctx, payload.UserID, payload.MeetupsCompleted, payload.OccurredAt)
		return err
	})

	// push-notification-requested is NO LONGER AN EVENT-BUS TOPIC at all.
	// The meetup module writes those notifications into
	// meetup.notification_outbox inside the same transaction as the business
	// write that implies them, and the poller started below delivers them
	// (ADR-001's durable-notification-delivery correction, §F). Every other
	// topic above is unchanged: still the in-memory d.bus, still synchronous,
	// still the ADR-001 §4 trade-off as originally reasoned.
}
