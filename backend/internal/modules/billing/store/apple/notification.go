package apple

import (
	"crypto/x509"
	"errors"
	"fmt"
	"time"

	"professional-meetups-monolith/backend/internal/modules/billing/store"
)

// Notification is an App Store Server Notification V2, verified. Both the
// envelope and the transaction inside it are separately signed and both
// are verified: arriving inside a verified envelope earns nothing.
type Notification struct {
	ID          string
	Type        string
	Subtype     string
	BundleID    string
	Environment store.Environment
	// Transaction is the verified signedTransactionInfo. Absent on
	// notifications with no transaction (TEST).
	Transaction *store.Transaction
	// GracePeriodEnd is from the verified signedRenewalInfo, when Apple
	// sent one with a grace period.
	GracePeriodEnd *time.Time
	// AutoRenew is from the renewal info, when present.
	AutoRenew *bool
}

type envelope struct {
	NotificationType string `json:"notificationType"`
	Subtype          string `json:"subtype"`
	NotificationUUID string `json:"notificationUUID"`
	Data             struct {
		BundleID              string `json:"bundleId"`
		Environment           string `json:"environment"`
		SignedTransactionInfo string `json:"signedTransactionInfo"`
		SignedRenewalInfo     string `json:"signedRenewalInfo"`
	} `json:"data"`
}

type renewalInfo struct {
	AutoRenewStatus        *int  `json:"autoRenewStatus"`
	GracePeriodExpiresDate int64 `json:"gracePeriodExpiresDate"`
}

// ErrBadSignature is any notification that does not verify. The caller
// answers 401 and writes nothing.
var ErrBadSignature = errors.New("apple: notification signature does not verify")

// ParseNotification verifies signedPayload and everything signed inside it.
func ParseNotification(signedPayload string, roots *x509.CertPool) (Notification, error) {
	env, err := Decode[envelope](signedPayload, roots)
	if err != nil {
		return Notification{}, fmt.Errorf("%w: %w", ErrBadSignature, err)
	}
	if env.NotificationUUID == "" || env.NotificationType == "" {
		return Notification{}, fmt.Errorf("%w: notification without a uuid or type", store.ErrRejected)
	}
	n := Notification{
		ID: env.NotificationUUID, Type: env.NotificationType, Subtype: env.Subtype,
		BundleID: env.Data.BundleID, Environment: environment(env.Data.Environment),
	}
	if env.Data.SignedTransactionInfo != "" {
		tx, err := ParseTransaction(env.Data.SignedTransactionInfo, roots)
		if err != nil {
			return Notification{}, fmt.Errorf("%w: transaction: %w", ErrBadSignature, err)
		}
		n.Transaction = &tx
	}
	if env.Data.SignedRenewalInfo != "" {
		r, err := Decode[renewalInfo](env.Data.SignedRenewalInfo, roots)
		if err != nil {
			return Notification{}, fmt.Errorf("%w: renewal info: %w", ErrBadSignature, err)
		}
		if r.GracePeriodExpiresDate > 0 {
			g := time.UnixMilli(r.GracePeriodExpiresDate).UTC()
			n.GracePeriodEnd = &g
		}
		if r.AutoRenewStatus != nil {
			on := *r.AutoRenewStatus == 1
			n.AutoRenew = &on
		}
	}
	return n, nil
}
