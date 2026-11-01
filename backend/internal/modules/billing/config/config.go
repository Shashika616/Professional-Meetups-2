// Package config loads the billing module's environment settings. Prices,
// limits, the welcome grant and the refund policy are NOT here: they are data
// in billing.price_rules, changeable without a deploy (plan 29 §3.3).
package config

import (
	"errors"
	"fmt"
	"net/url"
	"os"
	"strconv"

	"professional-meetups-monolith/backend/internal/platform/flags"
)

// The app's identifiers in the two stores. Defaults so a deploy that sets
// only the credentials still checks the right app.
const (
	DefaultAppleBundleID     = "com.profconn.professionalConnectionsPlatform"
	DefaultGooglePackageName = "com.profconn.professional_connections_platform"
)

// StoreFake selects the fake store (BILLING_STORE=fake). Never on Cloud Run.
const StoreFake = "fake"

// Config is the billing module's settings.
type Config struct {
	// MinCreditsAppVersion is the first app version with the credits UI.
	// Creating a meetup from an older build is refused with 426 "Update
	// TieHere to host a meetup." rather than charged without the user ever
	// seeing a price (plan 29 §2, D11).
	MinCreditsAppVersion string
	// CatalogVersion is reported by /v1/app-config and the catalog so the
	// app knows when to refetch the catalog.
	CatalogVersion int

	// Production is true on Cloud Run (K_SERVICE is set). Off it, sandbox
	// purchases are accepted from anyone and the fake store may be chosen.
	Production bool
	// Store is "" for the real stores, StoreFake for the fake one.
	Store string

	// Apple: the App Store Connect API key (plan 29 §9). All four, or
	// iOS purchases fail closed with 503.
	AppleBundleID   string
	AppleIssuerID   string
	AppleKeyID      string
	ApplePrivateKey string `json:"-"`

	// Google: the Android Publisher service account, and the Pub/Sub push
	// subscription RTDN arrives through.
	GooglePackageName        string
	GoogleServiceAccountJSON string `json:"-"`
	GooglePushAudience       string
	GooglePushServiceAccount string

	// The legal links the catalog carries for the subscription screens
	// (App Review Guideline 3.1.2). Empty until set.
	TermsURL   string
	PrivacyURL string
}

// AppleConfigured reports whether every Apple credential is set.
func (c Config) AppleConfigured() bool {
	return c.AppleBundleID != "" && c.AppleIssuerID != "" && c.AppleKeyID != "" && c.ApplePrivateKey != ""
}

// GoogleConfigured reports whether the Google service account is set.
func (c Config) GoogleConfigured() bool {
	return c.GooglePackageName != "" && c.GoogleServiceAccountJSON != ""
}

// ErrFakeStoreInProduction refuses to start a production process that
// would believe any purchase token it is sent.
var ErrFakeStoreInProduction = errors.New("config: BILLING_STORE=fake is refused on Cloud Run (K_SERVICE is set)")

// Load reads the settings from the environment.
func Load() (Config, error) { return LoadFrom(os.Getenv) }

// LoadFrom reads the settings through getenv, with defaults that are safe
// to run on.
func LoadFrom(getenv func(string) string) (Config, error) {
	cfg := Config{
		MinCreditsAppVersion: "1.1.0", CatalogVersion: 1,
		Production:               getenv("K_SERVICE") != "",
		Store:                    getenv("BILLING_STORE"),
		AppleBundleID:            orDefault(getenv("APPLE_BUNDLE_ID"), DefaultAppleBundleID),
		AppleIssuerID:            getenv("APPLE_APP_STORE_ISSUER_ID"),
		AppleKeyID:               getenv("APPLE_APP_STORE_KEY_ID"),
		ApplePrivateKey:          getenv("APPLE_APP_STORE_PRIVATE_KEY"),
		GooglePackageName:        orDefault(getenv("GOOGLE_PLAY_PACKAGE_NAME"), DefaultGooglePackageName),
		GoogleServiceAccountJSON: getenv("GOOGLE_PLAY_SERVICE_ACCOUNT_JSON"),
		GooglePushAudience:       getenv("GOOGLE_PUBSUB_PUSH_AUDIENCE"),
		GooglePushServiceAccount: getenv("GOOGLE_PUBSUB_PUSH_SERVICE_ACCOUNT"),
		TermsURL:                 getenv("BILLING_TERMS_URL"),
		PrivacyURL:               getenv("BILLING_PRIVACY_URL"),
	}
	if v := getenv("MIN_CREDITS_APP_VERSION"); v != "" {
		if flags.CompareVersions(v, "0.0.0") < 0 {
			return Config{}, fmt.Errorf("config: MIN_CREDITS_APP_VERSION %q is not a version", v)
		}
		cfg.MinCreditsAppVersion = v
	}
	if v := getenv("BILLING_CATALOG_VERSION"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 {
			return Config{}, fmt.Errorf("config: BILLING_CATALOG_VERSION %q is not a positive integer", v)
		}
		cfg.CatalogVersion = n
	}
	switch cfg.Store {
	case "":
	case StoreFake:
		if cfg.Production {
			return Config{}, ErrFakeStoreInProduction
		}
	default:
		return Config{}, fmt.Errorf("config: BILLING_STORE %q is not known (leave it unset, or %q off Cloud Run)", cfg.Store, StoreFake)
	}
	for name, v := range map[string]string{"BILLING_TERMS_URL": cfg.TermsURL, "BILLING_PRIVACY_URL": cfg.PrivacyURL} {
		if v == "" {
			continue
		}
		if u, err := url.Parse(v); err != nil || u.Scheme != "https" || u.Host == "" {
			return Config{}, fmt.Errorf("config: %s must be an https URL", name)
		}
	}
	return cfg, nil
}

func orDefault(v, d string) string {
	if v == "" {
		return d
	}
	return v
}
