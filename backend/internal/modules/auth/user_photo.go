package auth

import (
	"context"
	"time"

	"professional-meetups-monolith/backend/internal/modules/auth/photo"
	"professional-meetups-monolith/backend/internal/modules/auth/repository"
	"professional-meetups-monolith/backend/internal/platform/ratelimit"
)

// PhotoFetcher downloads a LinkedIn picture (photo.Fetcher).
type PhotoFetcher interface {
	Fetch(ctx context.Context, rawURL string) (jpeg []byte, w, h int, err error)
}

// photoUploadRule: 10 uploads an hour per account. Failing open costs a few
// extra small writes.
var photoUploadRule = ratelimit.Rule{Name: "auth:photo-upload", Limit: 10, Window: time.Hour}

// SetProfilePhoto stores the user's own picture and returns its path.
func (s *service) SetProfilePhoto(ctx context.Context, userID string, raw []byte) (string, error) {
	if err := s.limits.Check(ctx, photoUploadRule, userID); err != nil {
		return "", err
	}
	out, w, h, err := photo.Normalize(raw)
	if err != nil {
		return "", err
	}
	return s.storePhoto(ctx, userID, out, w, h)
}

// storePhoto writes the bytes, then the path on the user row, which publishes
// the user-profile event the meetup module's display cache follows.
func (s *service) storePhoto(ctx context.Context, userID string, jpeg []byte, w, h int) (string, error) {
	etag := photo.Etag(jpeg)
	if err := s.photos.Upsert(ctx, userID, repository.UserPhoto{JPEG: jpeg, Etag: etag, Width: w, Height: h}); err != nil {
		return "", err
	}
	path := photo.Path(userID, etag)
	if _, err := s.users.UpdateProfilePhoto(ctx, userID, path); err != nil {
		return "", err
	}
	return path, nil
}

// DeleteProfilePhoto removes the user's picture.
func (s *service) DeleteProfilePhoto(ctx context.Context, userID string) error {
	if err := s.photos.Delete(ctx, userID); err != nil {
		return err
	}
	_, err := s.users.UpdateProfilePhoto(ctx, userID, "")
	return err
}

// GetProfilePhoto returns the stored JPEG and its etag, or just the etag
// when knownEtag already matches it (jpeg is then nil).
func (s *service) GetProfilePhoto(ctx context.Context, userID, knownEtag string) ([]byte, string, error) {
	if knownEtag != "" {
		etag, err := s.photos.Etag(ctx, userID)
		if err != nil {
			return nil, "", err
		}
		if etag == knownEtag {
			return nil, etag, nil
		}
	}
	p, err := s.photos.Get(ctx, userID)
	if err != nil {
		return nil, "", err
	}
	return p.JPEG, p.Etag, nil
}

// captureLinkedInPhoto takes the LinkedIn picture once, when an account is
// created through LinkedIn and has no photo (plan 2.1). There is no other
// path: signing in again or connecting LinkedIn later never touches a photo,
// and Google and Apple never set one.
//
// Best effort: the caller is mid sign-up, and failing that over an avatar
// would trade an account for a picture. On any failure the account has
// initials, and the user can add a photo themselves.
func (s *service) captureLinkedInPhoto(ctx context.Context, user repository.User, pictureURL string) repository.User {
	if pictureURL == "" || s.photoFetcher == nil || s.photos == nil {
		return user
	}
	jpeg, w, h, err := s.photoFetcher.Fetch(ctx, pictureURL)
	if err != nil {
		s.logger.Warn("linkedin picture not captured", "user_id", user.ID, "error", err)
		return user
	}
	path, err := s.storePhoto(ctx, user.ID, jpeg, w, h)
	if err != nil {
		s.logger.Warn("linkedin picture not stored", "user_id", user.ID, "error", err)
		return user
	}
	user.ProfilePhotoURL = path
	return user
}
