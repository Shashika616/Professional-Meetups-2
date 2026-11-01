package grpcapi

import (
	"context"
	"time"

	"professional-meetups-monolith/backend/internal/modules/billing"
	"professional-meetups-monolith/backend/internal/platform/apperror"
	billingv1 "professional-meetups-monolith/backend/internal/proto/billing/v1"
)

// BillingServer adapts the billing module to billingv1.BillingServiceServer:
// field copying and apperror.ToGRPCStatus, no business rules — the same thin
// shape as AuthServer and MeetupServer.
type BillingServer struct {
	billingv1.UnimplementedBillingServiceServer
	svc *billing.Service
}

// NewBillingServer constructs a BillingServer over svc.
func NewBillingServer(svc *billing.Service) *BillingServer {
	return &BillingServer{svc: svc}
}

func callerFromProto(c *billingv1.Caller) billing.Caller {
	return billing.Caller{UserID: c.GetUserId(), TrustLevel: int(c.GetTrustLevel())}
}

func unixOrZero(t *time.Time) int64 {
	if t == nil {
		return 0
	}
	return t.Unix()
}

func limitsToProto(l billing.Limits) *billingv1.Limits {
	return &billingv1.Limits{MaxCapacity: int32(l.MaxCapacity), MaxAdvanceDays: int32(l.MaxAdvanceDays)}
}

func (s *BillingServer) GetWallet(ctx context.Context, req *billingv1.GetWalletRequest) (*billingv1.WalletResponse, error) {
	v, err := s.svc.Wallet(ctx, callerFromProto(req.GetCaller()))
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return walletToProto(v), nil
}

func walletToProto(v billing.WalletView) *billingv1.WalletResponse {
	resp := &billingv1.WalletResponse{Balance: v.Balance, Held: v.Held, Available: v.Available, Debt: v.Debt}
	for _, e := range v.ExpiringSoon {
		resp.ExpiringSoon = append(resp.ExpiringSoon, &billingv1.ExpiringCredits{
			Kind:                   e.Kind,
			Remaining:              e.Remaining,
			ExpiresAtUnixSeconds:   unixOrZero(e.ExpiresAt),
			NextDecayAtUnixSeconds: unixOrZero(e.NextDecayAt),
			NextDecayCredits:       e.NextDecayCredits,
		})
	}
	return resp
}

func (s *BillingServer) ListLedger(ctx context.Context, req *billingv1.ListLedgerRequest) (*billingv1.ListLedgerResponse, error) {
	page, err := s.svc.Ledger(ctx, req.GetCaller().GetUserId(), req.GetCursor(), int(req.GetPageSize()))
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	resp := &billingv1.ListLedgerResponse{NextCursor: page.NextCursor}
	for _, e := range page.Entries {
		resp.Entries = append(resp.Entries, &billingv1.LedgerEntry{
			Id: e.ID, Delta: e.Delta, HeldDelta: e.HeldDelta, Reason: e.Reason,
			RefType: e.RefType, RefId: e.RefID, BalanceAfter: e.BalanceAfter,
			CreatedAtUnixSeconds: e.CreatedAt.Unix(),
		})
	}
	return resp, nil
}

func (s *BillingServer) Quote(ctx context.Context, req *billingv1.QuoteRequest) (*billingv1.QuoteResponse, error) {
	q, err := s.svc.Quote(ctx, callerFromProto(req.GetCaller()), int(req.GetCapacity()),
		time.Unix(req.GetWindowStartUnixSeconds(), 0).UTC())
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return &billingv1.QuoteResponse{
		Cost: q.Cost, WouldCost: q.WouldCost,
		Base: q.Breakdown.Base, People: q.Breakdown.People, LeadTime: q.Breakdown.LeadTime,
		PriceVersion: int32(q.PriceVersion), CoveredByPlan: q.CoveredByPlan,
		BalanceAvailable: q.BalanceAvailable, Limits: limitsToProto(q.Limits), CreditsEnforced: true,
	}, nil
}

func (s *BillingServer) GetEntitlements(ctx context.Context, req *billingv1.GetEntitlementsRequest) (*billingv1.EntitlementsResponse, error) {
	e, err := s.svc.Entitlements(ctx, callerFromProto(req.GetCaller()))
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	resp := &billingv1.EntitlementsResponse{
		PlanCode: e.PlanCode, PlanStatus: e.PlanStatus, Limits: limitsToProto(e.Limits),
		MeetupsIncluded: int32(e.MeetupsIncluded), MeetupsUsed: int32(e.MeetupsUsed),
		CreditsEnforced: true,
	}
	if !e.PeriodEnd.IsZero() {
		resp.PeriodEndUnixSeconds = e.PeriodEnd.Unix()
	}
	return resp, nil
}

func subscriptionToProto(v billing.SubscriptionView) *billingv1.SubscriptionResponse {
	return &billingv1.SubscriptionResponse{
		Status: v.Status, PlanCode: v.PlanCode, Platform: v.Platform, ProductId: v.ProductID,
		CurrentPeriodEndUnixSeconds: unixOrZero(v.PeriodEnd), AutoRenew: v.AutoRenew, Entitled: v.Entitled,
	}
}

func (s *BillingServer) VerifyPurchase(ctx context.Context, req *billingv1.VerifyPurchaseRequest) (*billingv1.VerifyPurchaseResponse, error) {
	r, err := s.svc.VerifyPurchase(ctx, callerFromProto(req.GetCaller()), billing.PurchaseRequest{
		Platform: req.GetPlatform(), ProductID: req.GetProductId(), Token: req.GetToken(),
	})
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return &billingv1.VerifyPurchaseResponse{
		Kind: r.Kind, ProductId: r.ProductID, CreditsGranted: r.CreditsGranted, AlreadyProcessed: r.AlreadyProcessed,
		Wallet: walletToProto(r.Wallet), Subscription: subscriptionToProto(r.Subscription),
	}, nil
}

func (s *BillingServer) GetSubscription(ctx context.Context, req *billingv1.GetSubscriptionRequest) (*billingv1.SubscriptionResponse, error) {
	v, err := s.svc.Subscription(ctx, callerFromProto(req.GetCaller()))
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return subscriptionToProto(v), nil
}

func (s *BillingServer) GetCatalog(ctx context.Context, req *billingv1.GetCatalogRequest) (*billingv1.CatalogResponse, error) {
	c, err := s.svc.Catalog(ctx, req.GetUserId())
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	resp := &billingv1.CatalogResponse{
		CatalogVersion: int32(c.Version), PlansVisible: c.PlansVisible,
		TermsUrl: c.TermsURL, PrivacyUrl: c.PrivacyURL, AppAccountToken: c.AppAccountToken,
	}
	for _, p := range c.CreditPacks {
		resp.CreditPacks = append(resp.CreditPacks, &billingv1.CreditPack{
			ProductId: p.ProductID, Credits: p.Credits, Bonus: p.Bonus, Badge: p.Badge, Sort: int32(p.Sort),
		})
	}
	for _, p := range c.Plans {
		resp.Plans = append(resp.Plans, &billingv1.CatalogPlan{
			Code: p.Code, ProductIds: p.ProductIDs, Period: p.Period, Title: p.Title, Perks: p.Perks, Featured: p.Featured,
		})
	}
	return resp, nil
}

func (s *BillingServer) HandleAppleNotification(ctx context.Context, req *billingv1.HandleAppleNotificationRequest) (*billingv1.HandleNotificationResponse, error) {
	processed, err := s.svc.HandleAppleNotification(ctx, req.GetSignedPayload())
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return &billingv1.HandleNotificationResponse{Processed: processed}, nil
}

func (s *BillingServer) HandleGoogleNotification(ctx context.Context, req *billingv1.HandleGoogleNotificationRequest) (*billingv1.HandleNotificationResponse, error) {
	processed, err := s.svc.HandleGoogleNotification(ctx, req.GetAuthorizationHeader(), req.GetMessageId(), req.GetMessageDataBase64())
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return &billingv1.HandleNotificationResponse{Processed: processed}, nil
}
