package meetup

import (
	"fmt"

	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// The personality traits a rater can attach to a participant.
//
// # WHY THE SERVER OWNS THIS LIST
//
// A closed vocabulary keeps the traits aggregatable — "seven people found
// them thoughtful" is a sentence this data can support, which free text
// never could. It also keeps the app out of the business of moderating
// user-authored words attached to a named real person, and it lets the list
// grow without an app release, since clients render whatever this returns
// rather than a hardcoded copy.
//
// # WHY THEY ARE ALL POSITIVE
//
// Deliberate. These are shown on a real professional's profile alongside
// their name, and a vocabulary containing "rude" or "boring" turns a
// networking app into a place people get labelled. The negative signal this
// system does need already exists and is private: the 1-5 score, the safety
// feedback, and the report path. Traits are the part that is public, so
// they only ever say what someone was good at.
//
// Ordered deliberately — clients render them in this order, and the list is
// grouped conversation-style first, then working-style.
var ratingTraits = []RatingTrait{
	{Key: "great_listener", Label: "Great listener", Emoji: "👂"},
	{Key: "easy_to_talk_to", Label: "Easy to talk to", Emoji: "😄"},
	{Key: "cheerful", Label: "Cheerful", Emoji: "☀️"},
	{Key: "thoughtful", Label: "Thoughtful", Emoji: "💭"},
	{Key: "funny", Label: "Funny", Emoji: "😂"},
	{Key: "welcoming", Label: "Welcoming", Emoji: "🤝"},
	{Key: "knowledgeable", Label: "Knowledgeable", Emoji: "🧠"},
	{Key: "insightful", Label: "Insightful", Emoji: "💡"},
	{Key: "well_prepared", Label: "Well prepared", Emoji: "📋"},
	{Key: "generous_with_time", Label: "Generous with time", Emoji: "⏳"},
	{Key: "great_connector", Label: "Great connector", Emoji: "🌐"},
	{Key: "inspiring", Label: "Inspiring", Emoji: "🚀"},
}

// maxTraitsPerParticipant caps how many a rater may attach to one person.
// Without a cap, selecting all of them says nothing — the point of the
// feature is that a rater chooses.
const maxTraitsPerParticipant = 3

// RatingTrait is one selectable trait. The client renders Emoji + Label and
// sends back Key; Key is the only part ever stored.
type RatingTrait struct {
	Key   string
	Label string
	Emoji string
}

// RatingTraits returns the vocabulary, for the client to render.
func RatingTraits() []RatingTrait {
	out := make([]RatingTrait, len(ratingTraits))
	copy(out, ratingTraits)
	return out
}

var traitKeys = func() map[string]bool {
	m := make(map[string]bool, len(ratingTraits))
	for _, t := range ratingTraits {
		m[t.Key] = true
	}
	return m
}()

// validateTraits rejects anything outside the vocabulary, anything repeated,
// and more than the cap. Validated server-side rather than trusted from the
// client for the usual reason: these end up displayed on someone else's
// profile, so an arbitrary string from a modified client would be text one
// user gets to write onto another user's name.
func validateTraits(traits []string) error {
	if len(traits) > maxTraitsPerParticipant {
		return fmt.Errorf("meetup: at most %d traits per participant: %w", maxTraitsPerParticipant, apperror.ErrInvalidInput)
	}
	seen := make(map[string]bool, len(traits))
	for _, t := range traits {
		if !traitKeys[t] {
			return fmt.Errorf("meetup: unknown trait %q: %w", t, apperror.ErrInvalidInput)
		}
		if seen[t] {
			return fmt.Errorf("meetup: duplicate trait %q: %w", t, apperror.ErrInvalidInput)
		}
		seen[t] = true
	}
	return nil
}
