package auth

import (
	"context"
	"errors"
	"fmt"

	"professional-meetups-monolith/backend/internal/modules/auth/repository"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// GetLegalDocuments returns the current published version. Wraps
// apperror.ErrNotFound before the first publish.
func (s *service) GetLegalDocuments(ctx context.Context) (repository.LegalDocuments, error) {
	return s.legal.Current(ctx)
}

// AcceptLegal records that userID agreed to the current documents. A version
// other than the current one is refused, so nobody is recorded as agreeing to
// text that is no longer what the app shows.
func (s *service) AcceptLegal(ctx context.Context, userID, version, appVersion, platform string) error {
	current, err := s.legal.Current(ctx)
	if err != nil {
		return err
	}
	if version != current.Version {
		return fmt.Errorf("these terms have changed, please review them again: %w", apperror.ErrConflict)
	}
	return s.legal.Accept(ctx, userID, version, appVersion, platform)
}

// HasAcceptedLegal says whether userID has agreed to the current documents.
// With nothing published there is nothing to agree to.
func (s *service) HasAcceptedLegal(ctx context.Context, userID string) (bool, error) {
	current, err := s.legal.Current(ctx)
	if errors.Is(err, apperror.ErrNotFound) {
		return true, nil
	}
	if err != nil {
		return false, err
	}
	return s.legal.HasAccepted(ctx, userID, current.Version)
}
