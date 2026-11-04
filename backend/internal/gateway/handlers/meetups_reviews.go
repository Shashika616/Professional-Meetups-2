package handlers

import (
	"encoding/json"
	"net/http"

	"professional-meetups-monolith/backend/internal/gateway/middleware"
	"professional-meetups-monolith/backend/internal/gateway/monolithclient"
)

// ratableParticipantResponse mirrors monolithclient.RatableParticipant
// (ADR-015) — the host + accepted requesters of a meetup, minus the viewer,
// each flagged with whether the viewer already rated them.
type ratableParticipantResponse struct {
	UserID          string  `json:"user_id"`
	FullName        string  `json:"full_name"`
	ProfilePhotoURL string  `json:"photo_url"`
	TrustLevel      int32   `json:"trust_level"`
	AlreadyRated    bool    `json:"already_rated"`
	ContextNote     *string `json:"context_note,omitempty"`
}

type ratingTraitResponse struct {
	Key   string `json:"key"`
	Label string `json:"label"`
	Emoji string `json:"emoji"`
	// Sorts the trait into the review screen's Negative tab. Server-owned
	// so a client never decides which words count as criticism.
	Negative bool `json:"negative"`
}

type listRatableParticipantsResponse struct {
	Participants []ratableParticipantResponse `json:"participants"`
	// The trait vocabulary, sent with the list because the review screen
	// renders both together and would otherwise need a second round trip
	// before it could draw anything.
	AvailableTraits []ratingTraitResponse `json:"available_traits"`
}

func (h *Handler) listRatableParticipants(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	// Trust level from the verified JWT, exactly as listMeetupParticipants
	// above does — it gates a redaction, so it is precisely the value a
	// modified client would want to supply.
	result, err := h.monolith.ListRatableParticipants(
		ctx,
		r.PathValue("id"),
		middleware.UserIDFromContext(ctx),
		int32(middleware.TrustLevelFromContext(ctx)),
	)
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	out := make([]ratableParticipantResponse, 0, len(result.Participants))
	for _, p := range result.Participants {
		out = append(out, ratableParticipantResponse{
			UserID:          p.UserID,
			FullName:        p.FullName,
			ProfilePhotoURL: photoPath(p.ProfilePhotoURL),
			TrustLevel:      p.TrustLevel,
			AlreadyRated:    p.AlreadyRated,
			ContextNote:     p.ContextNote,
		})
	}
	traits := make([]ratingTraitResponse, 0, len(result.AvailableTraits))
	for _, t := range result.AvailableTraits {
		traits = append(traits, ratingTraitResponse{Key: t.Key, Label: t.Label, Emoji: t.Emoji, Negative: t.Negative})
	}
	writeJSON(w, http.StatusOK, listRatableParticipantsResponse{Participants: out, AvailableTraits: traits})
}

type reviewParticipantRequest struct {
	UserID string   `json:"user_id"`
	Score  int32    `json:"score"`
	Traits []string `json:"traits"`
}

type submitMeetupReviewRequest struct {
	OverallScore int32                      `json:"overall_score"`
	Notes        *string                    `json:"notes"`
	Participants []reviewParticipantRequest `json:"participants"`
}

func (h *Handler) submitMeetupReview(w http.ResponseWriter, r *http.Request) {
	var req submitMeetupReviewRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, msgBadRequest)
		return
	}

	participants := make([]monolithclient.ReviewParticipantInput, 0, len(req.Participants))
	for _, p := range req.Participants {
		participants = append(participants, monolithclient.ReviewParticipantInput{
			UserID: p.UserID, Score: p.Score, Traits: p.Traits,
		})
	}

	ctx := r.Context()
	if err := h.monolith.SubmitMeetupReview(ctx, r.PathValue("id"), middleware.UserIDFromContext(ctx), req.OverallScore, req.Notes, participants); err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, successResponse{Success: true})
}

type reviewedParticipantResponse struct {
	UserID          string   `json:"user_id"`
	FullName        string   `json:"full_name"`
	ProfilePhotoURL string   `json:"photo_url"`
	Score           int32    `json:"score"`
	Traits          []string `json:"traits"`
}

type meetupReviewResponse struct {
	Completed    bool                          `json:"completed"`
	OverallScore int32                         `json:"overall_score"`
	Notes        *string                       `json:"notes,omitempty"`
	Participants []reviewedParticipantResponse `json:"participants"`
}

func (h *Handler) getMeetupReview(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	review, err := h.monolith.GetMeetupReview(ctx, r.PathValue("id"), middleware.UserIDFromContext(ctx))
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	participants := make([]reviewedParticipantResponse, 0, len(review.Participants))
	for _, p := range review.Participants {
		participants = append(participants, reviewedParticipantResponse{
			UserID:          p.UserID,
			FullName:        p.FullName,
			ProfilePhotoURL: photoPath(p.ProfilePhotoURL),
			Score:           p.Score,
			Traits:          p.Traits,
		})
	}
	writeJSON(w, http.StatusOK, meetupReviewResponse{
		Completed:    review.Completed,
		OverallScore: review.OverallScore,
		Notes:        review.Notes,
		Participants: participants,
	})
}

type submitRatingRequest struct {
	RatedUserID string `json:"rated_user_id"`
	Score       int32  `json:"score"`
}

func (h *Handler) submitRating(w http.ResponseWriter, r *http.Request) {
	var req submitRatingRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, msgBadRequest)
		return
	}

	ctx := r.Context()
	if err := h.monolith.SubmitRating(ctx, r.PathValue("id"), middleware.UserIDFromContext(ctx), req.RatedUserID, req.Score); err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, successResponse{Success: true})
}
