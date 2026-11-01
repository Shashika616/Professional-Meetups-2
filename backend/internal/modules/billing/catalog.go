package billing

import (
	"context"
	"encoding/json"
	"fmt"

	"professional-meetups-monolith/backend/internal/modules/billing/store"
)

// Catalog is GET /v1/billing/catalog (plan 29 §3.8): what the app may
// offer, already filtered for the caller.
//
// It never carries a price. The app shows the store's own localised price
// for these product ids and skips any product its store does not return,
// so a price is set once, in the store, and a product can be withdrawn
// without an app update.
type Catalog struct {
	Version     int
	CreditPacks []CreditPack
	// PlansVisible is billing.plans.visible for this caller. Plans is empty
	// when it is false.
	PlansVisible bool
	Plans        []CatalogPlan
	TermsURL     string
	PrivacyURL   string
	// AppAccountToken is what the app must attach to a purchase by this
	// caller (AccountToken). Empty for an anonymous caller.
	AppAccountToken string
}

// CreditPack is one credit pack. Credits is everything the pack grants;
// Bonus is how much of that is shown as a bonus.
type CreditPack struct {
	ProductID string
	Credits   int64
	Bonus     int64
	Badge     string
	Sort      int
}

// CatalogPlan is one subscription product.
type CatalogPlan struct {
	Code string
	// ProductIDs is the store product id per platform.
	ProductIDs map[string]string
	Period     string
	Title      string
	Perks      []string
	Featured   bool
}

// Catalog builds the caller's catalog. userID is "" for a caller who is not
// signed in, who sees plans only once the flag is on for everyone.
func (s *Service) Catalog(ctx context.Context, userID string) (Catalog, error) {
	rows, err := s.q.ListCatalogProducts(ctx)
	if err != nil {
		return Catalog{}, fmt.Errorf("billing: read catalog: %w", err)
	}
	out := Catalog{
		Version: s.cfg.CatalogVersion, CreditPacks: []CreditPack{}, Plans: []CatalogPlan{},
		PlansVisible: s.plansVisibleTo(ctx, userID),
		TermsURL:     s.cfg.TermsURL, PrivacyURL: s.cfg.PrivacyURL,
	}
	if userID != "" {
		if _, err := parseUser(userID); err == nil {
			out.AppAccountToken = AccountToken(userID)
		}
	}
	for _, r := range rows {
		switch store.Kind(r.Kind) {
		case store.Consumable:
			out.CreditPacks = append(out.CreditPacks, CreditPack{
				ProductID: r.ProductID, Credits: r.Credits.Int64 + r.Bonus, Bonus: r.Bonus,
				Badge: r.Badge.String, Sort: int(r.Sort),
			})
		case store.Subscription:
			if !out.PlansVisible {
				continue
			}
			var perks []string
			if err := json.Unmarshal(r.PlanPerks, &perks); err != nil {
				return Catalog{}, fmt.Errorf("billing: plan %s perks: %w", r.PlanCode.String, err)
			}
			out.Plans = append(out.Plans, CatalogPlan{
				Code: r.PlanCode.String, Period: r.Period.String, Title: r.PlanTitle, Perks: perks,
				Featured:   r.Featured,
				ProductIDs: map[string]string{string(store.IOS): r.ProductID, string(store.Android): r.ProductID},
			})
		}
	}
	return out, nil
}
