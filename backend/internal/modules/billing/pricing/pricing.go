// Package pricing turns a versioned rules document into the cost of creating
// one meetup (plan 29 §3.3). Price is a pure function: no clock, no database,
// no user. Everything that varies — the base cost, the per-person cost, the
// lead-time bands, the free limits, the welcome grant, the refund policy —
// is data in billing.price_rules, so changing a price is an INSERT, not a
// deploy.
package pricing

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

// Document is one billing.price_rules row's JSON. Field names are the
// document's contract: decoding is strict, so a misspelt key fails loading
// instead of silently defaulting to zero credits.
type Document struct {
	Base struct {
		Credits          int64 `json:"credits"`
		IncludesCapacity int   `json:"includes_capacity"`
	} `json:"base"`
	PerExtraPerson int64        `json:"per_extra_person"`
	LeadTime       []LeadBand   `json:"lead_time"`
	Free           Limits       `json:"free"`
	Welcome        Welcome      `json:"welcome"`
	Refunds        RefundPolicy `json:"refunds"`
	HoldTTLMinutes int          `json:"hold_ttl_minutes"`
}

// LeadBand prices meetups starting up to UpToHours from now.
type LeadBand struct {
	UpToHours int   `json:"up_to_hours"`
	Credits   int64 `json:"credits"`
}

// Limits is how big and how far ahead a meetup may be.
type Limits struct {
	MaxCapacity    int `json:"max_capacity"`
	MaxAdvanceDays int `json:"max_advance_days"`
}

// Welcome is the one-off grant on reaching hosting (D1) and its decay (D2).
type Welcome struct {
	Credits        int64 `json:"credits"`
	DecayPercent   int   `json:"decay_percent"`
	DecayEveryDays int   `json:"decay_every_days"`
}

// RefundPolicy is plan 29 §3.6 (D7).
type RefundPolicy struct {
	FullIfCancelledHoursBefore int `json:"full_if_cancelled_hours_before"`
	NoParticipantsPercent      int `json:"no_participants_percent"`
	MaxPer30Days               int `json:"max_per_30_days"`
}

// Rules is a parsed, validated document and the version it was stored as.
type Rules struct {
	Version int
	Doc     Document
}

// HoldTTL is how long a reservation lives before the sweep releases it.
func (r Rules) HoldTTL() time.Duration { return time.Duration(r.Doc.HoldTTLMinutes) * time.Minute }

// MaxPricedLead is the furthest ahead any band prices.
func (r Rules) MaxPricedLead() time.Duration {
	return time.Duration(r.Doc.LeadTime[len(r.Doc.LeadTime)-1].UpToHours) * time.Hour
}

// Parse decodes and validates a document. It refuses unknown fields and any
// value that would make pricing nonsensical, so a bad document stops pricing
// rather than charging by half a rule.
func Parse(version int, raw []byte) (Rules, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	var doc Document
	if err := dec.Decode(&doc); err != nil {
		return Rules{}, fmt.Errorf("pricing: decode rules v%d: %w", version, err)
	}
	if err := validate(doc); err != nil {
		return Rules{}, fmt.Errorf("pricing: rules v%d: %w", version, err)
	}
	return Rules{Version: version, Doc: doc}, nil
}

func validate(d Document) error {
	switch {
	case d.Base.Credits < 0:
		return errors.New("base.credits is negative")
	case d.Base.IncludesCapacity < 1:
		return errors.New("base.includes_capacity must be at least 1")
	case d.PerExtraPerson < 0:
		return errors.New("per_extra_person is negative")
	case len(d.LeadTime) == 0:
		return errors.New("lead_time has no bands")
	case d.Free.MaxCapacity < 1 || d.Free.MaxCapacity > 30:
		return errors.New("free.max_capacity must be 1-30")
	case d.Free.MaxAdvanceDays < 1:
		return errors.New("free.max_advance_days must be at least 1")
	case d.Welcome.Credits < 0:
		return errors.New("welcome.credits is negative")
	case d.Welcome.DecayPercent < 1 || d.Welcome.DecayPercent > 100:
		return errors.New("welcome.decay_percent must be 1-100")
	case d.Welcome.DecayEveryDays < 1:
		return errors.New("welcome.decay_every_days must be at least 1")
	case d.Refunds.FullIfCancelledHoursBefore < 0:
		return errors.New("refunds.full_if_cancelled_hours_before is negative")
	case d.Refunds.NoParticipantsPercent < 0 || d.Refunds.NoParticipantsPercent > 100:
		return errors.New("refunds.no_participants_percent must be 0-100")
	case d.Refunds.MaxPer30Days < 0:
		return errors.New("refunds.max_per_30_days is negative")
	case d.HoldTTLMinutes < 1:
		return errors.New("hold_ttl_minutes must be at least 1")
	}
	// Bands strictly widen and never get cheaper: that is what makes cost
	// monotonic in lead time, which the property test pins.
	prevHours, prevCredits := 0, int64(0)
	for i, b := range d.LeadTime {
		if b.UpToHours <= prevHours {
			return fmt.Errorf("lead_time[%d].up_to_hours must exceed the band before it", i)
		}
		if b.Credits < prevCredits || b.Credits < 0 {
			return fmt.Errorf("lead_time[%d].credits must not be less than the band before it", i)
		}
		prevHours, prevCredits = b.UpToHours, b.Credits
	}
	return nil
}

// Input is what the user chose. Lead is window_start minus the server's now.
type Input struct {
	Capacity int
	Lead     time.Duration
}

// Breakdown is the cost and the three parts it is made of.
type Breakdown struct {
	Base     int64
	People   int64
	LeadTime int64
}

// Total is the cost in credits.
func (b Breakdown) Total() int64 { return b.Base + b.People + b.LeadTime }

// ErrBeyondPricing is returned for a meetup further ahead than any band, or
// with no capacity.
var ErrBeyondPricing = errors.New("pricing: outside the priced range")

// Price is the cost of creating one meetup. It does not know about plans or
// entitlements: a plan's quota makes a creation free, and a user's limits
// cap capacity and lead time, both decided by the caller before or after
// pricing.
func Price(r Rules, in Input) (Breakdown, error) {
	if in.Capacity < 1 {
		return Breakdown{}, fmt.Errorf("%w: capacity %d", ErrBeyondPricing, in.Capacity)
	}
	lead := in.Lead
	if lead < 0 {
		// A meetup starting now (inside the creation grace period) is in the
		// nearest band, not an error.
		lead = 0
	}
	var leadCredits int64
	found := false
	for _, b := range r.Doc.LeadTime {
		if lead <= time.Duration(b.UpToHours)*time.Hour {
			leadCredits, found = b.Credits, true
			break
		}
	}
	if !found {
		return Breakdown{}, fmt.Errorf("%w: starts more than %s ahead", ErrBeyondPricing, r.MaxPricedLead())
	}
	var people int64
	if extra := in.Capacity - r.Doc.Base.IncludesCapacity; extra > 0 {
		people = int64(extra) * r.Doc.PerExtraPerson
	}
	return Breakdown{Base: r.Doc.Base.Credits, People: people, LeadTime: leadCredits}, nil
}
