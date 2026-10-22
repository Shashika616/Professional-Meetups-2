package monolithclient

import (
	"context"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	authv1 "professional-meetups-monolith/backend/internal/proto/auth/v1"
)

// AccountClaimRequiredError is what the two federated signup calls return
// when the monolith answered ALREADY_EXISTS with an
// authv1.AccountClaimRequired detail: the provider's verified address is
// already on an account, and the caller has to prove they still hold the
// mailbox before it is handed over.
//
// Shaped exactly like ScheduleConflictError (meetup.go), including the
// Unwrap: status.Convert and the gateway's code mapping keep working on it
// unchanged, and the handler that wants the ticket uses errors.As.
type AccountClaimRequiredError struct {
	Ticket             string
	Email              string
	ResendAfterSeconds int32
	status             error
}

// NewAccountClaimRequiredError pairs the claim detail with the status error
// it arrived on; status must be a gRPC status error so the gateway's code
// mapping still resolves through Unwrap. Exported for the gateway's handler
// tests, which fake this client.
func NewAccountClaimRequiredError(ticket, email string, resendAfterSeconds int32, status error) *AccountClaimRequiredError {
	return &AccountClaimRequiredError{
		Ticket:             ticket,
		Email:              email,
		ResendAfterSeconds: resendAfterSeconds,
		status:             status,
	}
}

// Error returns the status message alone rather than the status error's own
// "rpc error: code = ..." text — that message is what the gateway turns
// into the user-facing sentence.
func (e *AccountClaimRequiredError) Error() string { return status.Convert(e.status).Message() }
func (e *AccountClaimRequiredError) Unwrap() error { return e.status }

// withAccountClaim lifts the detail off err, or returns err untouched when
// it carries none — every other failure keeps its plain status.
//
// A ticket-less detail is ignored on purpose: without one there is nothing
// the app can do with the popup, and a plain "an account already exists"
// sentence is a better outcome than a dialog with no way forward.
func withAccountClaim(err error) error {
	st, ok := status.FromError(err)
	if !ok || st.Code() != codes.AlreadyExists {
		return err
	}
	for _, detail := range st.Details() {
		claim, ok := detail.(*authv1.AccountClaimRequired)
		if ok && claim.GetTicket() != "" {
			return NewAccountClaimRequiredError(
				claim.GetTicket(), claim.GetEmail(), claim.GetResendAfterSeconds(), err,
			)
		}
	}
	return err
}

func (c *grpcClient) CompleteAccountClaim(ctx context.Context, ticket, code string) (Session, error) {
	resp, err := c.auth.CompleteAccountClaim(ctx, &authv1.CompleteAccountClaimRequest{
		Ticket: ticket,
		Code:   code,
	})
	if err != nil {
		return Session{}, err
	}
	return sessionFromProto(resp), nil
}

func (c *grpcClient) ResendAccountClaimCode(ctx context.Context, ticket string) (int32, error) {
	resp, err := c.auth.ResendAccountClaimCode(ctx, &authv1.ResendAccountClaimCodeRequest{Ticket: ticket})
	if err != nil {
		return 0, err
	}
	return resp.GetResendAfterSeconds(), nil
}
