package monolithclient

import (
	"context"
	"encoding/json"

	billingv1 "professional-meetups-monolith/backend/internal/proto/billing/v1"
	opsv1 "professional-meetups-monolith/backend/internal/proto/ops/v1"
)

// CreateCharge is what a create-meetup request carries for billing (plan 29
// §3.5): the cost the app showed and the request's Idempotency-Key. All
// optional — a build without the credits UI sends none of it.
type CreateCharge struct {
	ExpectedCost   *int64
	PriceVersion   int32
	IdempotencyKey string
}

// Limits is how big and how far ahead the caller may schedule.
type Limits struct {
	MaxCapacity    int32 `json:"max_capacity"`
	MaxAdvanceDays int32 `json:"max_advance_days"`
}

// ExpiringCredits is credits about to expire or decay.
type ExpiringCredits struct {
	Kind                   string `json:"kind"`
	Remaining              int64  `json:"remaining"`
	ExpiresAtUnixSeconds   int64  `json:"expires_at_unix_seconds,omitempty"`
	NextDecayAtUnixSeconds int64  `json:"next_decay_at_unix_seconds,omitempty"`
	NextDecayCredits       int64  `json:"next_decay_credits,omitempty"`
}

// Wallet is the caller's balance.
type Wallet struct {
	Balance      int64             `json:"balance"`
	Held         int64             `json:"held"`
	Available    int64             `json:"available"`
	Debt         int64             `json:"debt"`
	ExpiringSoon []ExpiringCredits `json:"expiring_soon"`
}

// LedgerEntry is one line of the caller's credit history.
type LedgerEntry struct {
	ID                   int64  `json:"id"`
	Delta                int64  `json:"delta"`
	HeldDelta            int64  `json:"held_delta"`
	Reason               string `json:"reason"`
	RefType              string `json:"ref_type,omitempty"`
	RefID                string `json:"ref_id,omitempty"`
	BalanceAfter         int64  `json:"balance_after"`
	CreatedAtUnixSeconds int64  `json:"created_at_unix_seconds"`
}

// LedgerPage is one page of history.
type LedgerPage struct {
	Entries    []LedgerEntry `json:"entries"`
	NextCursor string        `json:"next_cursor"`
}

// QuoteBreakdown is the three parts of a price.
type QuoteBreakdown struct {
	Base     int64 `json:"base"`
	People   int64 `json:"people"`
	LeadTime int64 `json:"lead_time"`
}

// Quote is what creating a meetup would cost the caller.
type Quote struct {
	Cost             int64          `json:"cost"`
	WouldCost        int64          `json:"would_cost"`
	Breakdown        QuoteBreakdown `json:"breakdown"`
	PriceVersion     int32          `json:"price_version"`
	CoveredByPlan    bool           `json:"covered_by_plan"`
	BalanceAvailable int64          `json:"balance_available"`
	Limits           Limits         `json:"limits"`
	CreditsEnforced  bool           `json:"credits_enforced"`
}

// Entitlements is the caller's plan and limits.
type Entitlements struct {
	PlanCode             string `json:"plan_code"`
	PlanStatus           string `json:"plan_status"`
	PeriodEndUnixSeconds int64  `json:"period_end_unix_seconds,omitempty"`
	Limits               Limits `json:"limits"`
	MeetupsIncluded      int32  `json:"meetups_included"`
	MeetupsUsed          int32  `json:"meetups_used"`
	CreditsEnforced      bool   `json:"credits_enforced"`
}

// AppConfig is GET /v1/app-config.
type AppConfig struct {
	Flags                  map[string]bool            `json:"flags"`
	Values                 map[string]json.RawMessage `json:"values"`
	MinSupportedAppVersion string                     `json:"min_supported_app_version"`
	BillingCatalogVersion  int32                      `json:"billing_catalog_version"`
}

func limitsFromProto(l *billingv1.Limits) Limits {
	return Limits{MaxCapacity: l.GetMaxCapacity(), MaxAdvanceDays: l.GetMaxAdvanceDays()}
}

func (c *grpcClient) GetWallet(ctx context.Context, userID string, trustLevel int32) (Wallet, error) {
	resp, err := c.billing.GetWallet(ctx, &billingv1.GetWalletRequest{
		Caller: &billingv1.Caller{UserId: userID, TrustLevel: trustLevel},
	})
	if err != nil {
		return Wallet{}, err
	}
	return walletFromProto(resp), nil
}

func (c *grpcClient) ListLedger(ctx context.Context, userID, cursor string, pageSize int32) (LedgerPage, error) {
	resp, err := c.billing.ListLedger(ctx, &billingv1.ListLedgerRequest{
		Caller: &billingv1.Caller{UserId: userID}, Cursor: cursor, PageSize: pageSize,
	})
	if err != nil {
		return LedgerPage{}, err
	}
	page := LedgerPage{Entries: []LedgerEntry{}, NextCursor: resp.GetNextCursor()}
	for _, e := range resp.GetEntries() {
		page.Entries = append(page.Entries, LedgerEntry{
			ID: e.GetId(), Delta: e.GetDelta(), HeldDelta: e.GetHeldDelta(), Reason: e.GetReason(),
			RefType: e.GetRefType(), RefID: e.GetRefId(), BalanceAfter: e.GetBalanceAfter(),
			CreatedAtUnixSeconds: e.GetCreatedAtUnixSeconds(),
		})
	}
	return page, nil
}

func (c *grpcClient) Quote(ctx context.Context, userID string, trustLevel, capacity int32, windowStart int64) (Quote, error) {
	resp, err := c.billing.Quote(ctx, &billingv1.QuoteRequest{
		Caller:   &billingv1.Caller{UserId: userID, TrustLevel: trustLevel},
		Capacity: capacity, WindowStartUnixSeconds: windowStart,
	})
	if err != nil {
		return Quote{}, err
	}
	return Quote{
		Cost: resp.GetCost(), WouldCost: resp.GetWouldCost(),
		Breakdown:    QuoteBreakdown{Base: resp.GetBase(), People: resp.GetPeople(), LeadTime: resp.GetLeadTime()},
		PriceVersion: resp.GetPriceVersion(), CoveredByPlan: resp.GetCoveredByPlan(),
		BalanceAvailable: resp.GetBalanceAvailable(), Limits: limitsFromProto(resp.GetLimits()),
		CreditsEnforced: resp.GetCreditsEnforced(),
	}, nil
}

func (c *grpcClient) GetEntitlements(ctx context.Context, userID string, trustLevel int32) (Entitlements, error) {
	resp, err := c.billing.GetEntitlements(ctx, &billingv1.GetEntitlementsRequest{
		Caller: &billingv1.Caller{UserId: userID, TrustLevel: trustLevel},
	})
	if err != nil {
		return Entitlements{}, err
	}
	return Entitlements{
		PlanCode: resp.GetPlanCode(), PlanStatus: resp.GetPlanStatus(),
		PeriodEndUnixSeconds: resp.GetPeriodEndUnixSeconds(), Limits: limitsFromProto(resp.GetLimits()),
		MeetupsIncluded: resp.GetMeetupsIncluded(), MeetupsUsed: resp.GetMeetupsUsed(),
		CreditsEnforced: resp.GetCreditsEnforced(),
	}, nil
}

func (c *grpcClient) GetAppConfig(ctx context.Context, userID string) (AppConfig, error) {
	resp, err := c.ops.GetAppConfig(ctx, &opsv1.GetAppConfigRequest{UserId: userID})
	if err != nil {
		return AppConfig{}, err
	}
	out := AppConfig{
		Flags:                  make(map[string]bool, len(resp.GetFlags())),
		Values:                 map[string]json.RawMessage{},
		MinSupportedAppVersion: resp.GetMinSupportedAppVersion(),
		BillingCatalogVersion:  resp.GetBillingCatalogVersion(),
	}
	for key, f := range resp.GetFlags() {
		out.Flags[key] = f.GetEnabled()
		if v := f.GetValueJson(); v != "" && json.Valid([]byte(v)) {
			out.Values[key] = json.RawMessage(v)
		}
	}
	return out, nil
}

// Subscription is GET /v1/billing/subscription.
type Subscription struct {
	Status                      string `json:"status"`
	PlanCode                    string `json:"plan_code,omitempty"`
	Platform                    string `json:"platform,omitempty"`
	ProductID                   string `json:"product_id,omitempty"`
	CurrentPeriodEndUnixSeconds int64  `json:"current_period_end_unix_seconds,omitempty"`
	AutoRenew                   bool   `json:"auto_renew"`
	Entitled                    bool   `json:"entitled"`
}

// PurchaseResult is POST /v1/billing/purchases/verify.
type PurchaseResult struct {
	Kind             string       `json:"kind"`
	ProductID        string       `json:"product_id"`
	CreditsGranted   int64        `json:"credits_granted"`
	AlreadyProcessed bool         `json:"already_processed"`
	Wallet           Wallet       `json:"wallet"`
	Subscription     Subscription `json:"subscription"`
}

// CreditPack is one pack in the catalog.
type CreditPack struct {
	ProductID string `json:"product_id"`
	Credits   int64  `json:"credits"`
	Bonus     int64  `json:"bonus"`
	Badge     string `json:"badge,omitempty"`
	Sort      int32  `json:"sort"`
}

// CatalogPlan is one subscription product in the catalog.
type CatalogPlan struct {
	Code       string            `json:"code"`
	ProductIDs map[string]string `json:"product_ids"`
	Period     string            `json:"period"`
	Title      string            `json:"title"`
	Perks      []string          `json:"perks"`
	Featured   bool              `json:"featured"`
}

// CatalogLegal is the links the subscription screens must show.
type CatalogLegal struct {
	TermsURL   string `json:"terms_url"`
	PrivacyURL string `json:"privacy_url"`
}

// Catalog is GET /v1/billing/catalog. It has no prices by design.
type Catalog struct {
	CatalogVersion  int32         `json:"catalog_version"`
	CreditPacks     []CreditPack  `json:"credit_packs"`
	PlansVisible    bool          `json:"plans_visible"`
	Plans           []CatalogPlan `json:"plans"`
	Legal           CatalogLegal  `json:"legal"`
	AppAccountToken string        `json:"app_account_token,omitempty"`
}

func walletFromProto(resp *billingv1.WalletResponse) Wallet {
	w := Wallet{Balance: resp.GetBalance(), Held: resp.GetHeld(), Available: resp.GetAvailable(),
		Debt: resp.GetDebt(), ExpiringSoon: []ExpiringCredits{}}
	for _, e := range resp.GetExpiringSoon() {
		w.ExpiringSoon = append(w.ExpiringSoon, ExpiringCredits{
			Kind: e.GetKind(), Remaining: e.GetRemaining(),
			ExpiresAtUnixSeconds: e.GetExpiresAtUnixSeconds(), NextDecayAtUnixSeconds: e.GetNextDecayAtUnixSeconds(),
			NextDecayCredits: e.GetNextDecayCredits(),
		})
	}
	return w
}

func subscriptionFromProto(r *billingv1.SubscriptionResponse) Subscription {
	return Subscription{
		Status: r.GetStatus(), PlanCode: r.GetPlanCode(), Platform: r.GetPlatform(), ProductID: r.GetProductId(),
		CurrentPeriodEndUnixSeconds: r.GetCurrentPeriodEndUnixSeconds(), AutoRenew: r.GetAutoRenew(), Entitled: r.GetEntitled(),
	}
}

func (c *grpcClient) VerifyPurchase(ctx context.Context, userID string, trustLevel int32, platform, productID, token string) (PurchaseResult, error) {
	resp, err := c.billing.VerifyPurchase(ctx, &billingv1.VerifyPurchaseRequest{
		Caller: &billingv1.Caller{UserId: userID, TrustLevel: trustLevel}, Platform: platform, ProductId: productID, Token: token,
	})
	if err != nil {
		return PurchaseResult{}, err
	}
	return PurchaseResult{
		Kind: resp.GetKind(), ProductID: resp.GetProductId(), CreditsGranted: resp.GetCreditsGranted(),
		AlreadyProcessed: resp.GetAlreadyProcessed(), Wallet: walletFromProto(resp.GetWallet()),
		Subscription: subscriptionFromProto(resp.GetSubscription()),
	}, nil
}

func (c *grpcClient) GetSubscription(ctx context.Context, userID string) (Subscription, error) {
	resp, err := c.billing.GetSubscription(ctx, &billingv1.GetSubscriptionRequest{Caller: &billingv1.Caller{UserId: userID}})
	if err != nil {
		return Subscription{}, err
	}
	return subscriptionFromProto(resp), nil
}

func (c *grpcClient) GetCatalog(ctx context.Context, userID string) (Catalog, error) {
	resp, err := c.billing.GetCatalog(ctx, &billingv1.GetCatalogRequest{UserId: userID})
	if err != nil {
		return Catalog{}, err
	}
	out := Catalog{
		CatalogVersion: resp.GetCatalogVersion(), CreditPacks: []CreditPack{}, PlansVisible: resp.GetPlansVisible(),
		Plans: []CatalogPlan{}, Legal: CatalogLegal{TermsURL: resp.GetTermsUrl(), PrivacyURL: resp.GetPrivacyUrl()},
		AppAccountToken: resp.GetAppAccountToken(),
	}
	for _, p := range resp.GetCreditPacks() {
		out.CreditPacks = append(out.CreditPacks, CreditPack{
			ProductID: p.GetProductId(), Credits: p.GetCredits(), Bonus: p.GetBonus(), Badge: p.GetBadge(), Sort: p.GetSort(),
		})
	}
	for _, p := range resp.GetPlans() {
		perks := p.GetPerks()
		if perks == nil {
			perks = []string{}
		}
		out.Plans = append(out.Plans, CatalogPlan{
			Code: p.GetCode(), ProductIDs: p.GetProductIds(), Period: p.GetPeriod(), Title: p.GetTitle(),
			Perks: perks, Featured: p.GetFeatured(),
		})
	}
	return out, nil
}

func (c *grpcClient) HandleAppleNotification(ctx context.Context, signedPayload string) (bool, error) {
	resp, err := c.billing.HandleAppleNotification(ctx, &billingv1.HandleAppleNotificationRequest{SignedPayload: signedPayload})
	if err != nil {
		return false, err
	}
	return resp.GetProcessed(), nil
}

func (c *grpcClient) HandleGoogleNotification(ctx context.Context, authorization, messageID, dataBase64 string) (bool, error) {
	resp, err := c.billing.HandleGoogleNotification(ctx, &billingv1.HandleGoogleNotificationRequest{
		AuthorizationHeader: authorization, MessageId: messageID, MessageDataBase64: dataBase64,
	})
	if err != nil {
		return false, err
	}
	return resp.GetProcessed(), nil
}
