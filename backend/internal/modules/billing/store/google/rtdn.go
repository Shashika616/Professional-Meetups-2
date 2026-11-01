package google

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"time"

	"professional-meetups-monolith/backend/internal/modules/billing/store"
)

// Notification is one Real-time Developer Notification, decoded from the
// Pub/Sub message after the push request's OIDC token has verified.
type Notification struct {
	// ID is the Pub/Sub message id: the same on a redelivery, so it is
	// the idempotency key (RTDN itself carries no notification id).
	ID          string
	PackageName string
	EventTime   time.Time

	// Exactly one of these is set for a notification billing acts on.
	Subscription *SubscriptionEvent
	Voided       *VoidedEvent
	// Test is a console test notification.
	Test bool
}

// SubscriptionEvent is subscriptionNotification.
type SubscriptionEvent struct {
	Type           int
	ProductID      string
	TokenHash      string
	PurchaseToken  string
	NotificationAt time.Time
}

// VoidedEvent is voidedPurchaseNotification: a refund or chargeback.
type VoidedEvent struct {
	TokenHash string
	OrderID   string
	// ProductType 1 is a subscription, 2 a one-time product.
	ProductType int
}

// The subscriptionNotification types billing maps (Google's enum).
const (
	SubRecovered      = 1
	SubRenewed        = 2
	SubCanceled       = 3
	SubPurchased      = 4
	SubOnHold         = 5
	SubInGracePeriod  = 6
	SubRestarted      = 7
	SubPaused         = 10
	SubRevoked        = 12
	SubExpired        = 13
	VoidedProductSub  = 1
	VoidedProductItem = 2
)

type rtdn struct {
	PackageName              string `json:"packageName"`
	EventTimeMillis          string `json:"eventTimeMillis"`
	SubscriptionNotification *struct {
		NotificationType int    `json:"notificationType"`
		PurchaseToken    string `json:"purchaseToken"`
		SubscriptionID   string `json:"subscriptionId"`
	} `json:"subscriptionNotification"`
	VoidedPurchaseNotification *struct {
		PurchaseToken string `json:"purchaseToken"`
		OrderID       string `json:"orderId"`
		ProductType   int    `json:"productType"`
	} `json:"voidedPurchaseNotification"`
	TestNotification *json.RawMessage `json:"testNotification"`
}

// ParseNotification decodes message.data. Call it only after the push
// request's token has verified.
func ParseNotification(messageID, dataBase64 string) (Notification, error) {
	if messageID == "" {
		return Notification{}, fmt.Errorf("%w: push message without an id", store.ErrRejected)
	}
	data, err := base64.StdEncoding.DecodeString(dataBase64)
	if err != nil {
		return Notification{}, fmt.Errorf("%w: message data is not base64", store.ErrRejected)
	}
	var m rtdn
	if err := json.Unmarshal(data, &m); err != nil {
		return Notification{}, fmt.Errorf("%w: message data is not an RTDN", store.ErrRejected)
	}
	n := Notification{ID: messageID, PackageName: m.PackageName, EventTime: millis(m.EventTimeMillis),
		Test: m.TestNotification != nil}
	if s := m.SubscriptionNotification; s != nil && s.PurchaseToken != "" {
		n.Subscription = &SubscriptionEvent{
			Type: s.NotificationType, ProductID: s.SubscriptionID,
			TokenHash: store.HashToken(s.PurchaseToken), PurchaseToken: s.PurchaseToken,
			NotificationAt: n.EventTime,
		}
	}
	if v := m.VoidedPurchaseNotification; v != nil && v.PurchaseToken != "" {
		n.Voided = &VoidedEvent{TokenHash: store.HashToken(v.PurchaseToken), OrderID: v.OrderID, ProductType: v.ProductType}
	}
	return n, nil
}
