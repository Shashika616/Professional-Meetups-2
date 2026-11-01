package apple_test

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/pem"
	"strings"
	"testing"

	"github.com/golang-jwt/jwt/v5"

	"professional-meetups-monolith/backend/internal/modules/billing/store/apple"
	"professional-meetups-monolith/backend/internal/modules/billing/store/apple/appletest"
)

// Ported from the source's webhookauth/apple_test.go, plus the marker check
// and the root pin.

func TestVerifyJWSValidChainAndSignature(t *testing.T) {
	chain := appletest.New(t)
	signed := chain.Sign(t, jwt.MapClaims{"notificationType": "SUBSCRIBED", "notificationUUID": "u-1"})
	claims, err := apple.VerifyJWS(signed, chain.Roots)
	if err != nil {
		t.Fatalf("a valid chain and signature did not verify: %v", err)
	}
	if claims["notificationType"] != "SUBSCRIBED" || claims["notificationUUID"] != "u-1" {
		t.Fatalf("claims = %v", claims)
	}
}

func TestVerifyJWSRejectsAnUntrustedChain(t *testing.T) {
	signed := appletest.New(t).Sign(t, jwt.MapClaims{"notificationType": "SUBSCRIBED"})
	if _, err := apple.VerifyJWS(signed, appletest.New(t).Roots); err == nil {
		t.Fatal("a chain under another root verified")
	}
}

func TestVerifyJWSRejectsATamperedPayload(t *testing.T) {
	chain := appletest.New(t)
	parts := strings.Split(chain.Sign(t, jwt.MapClaims{"notificationType": "SUBSCRIBED"}), ".")
	payload := []byte(parts[1])
	if payload[len(payload)-1] == 'A' {
		payload[len(payload)-1] = 'B'
	} else {
		payload[len(payload)-1] = 'A'
	}
	parts[1] = string(payload)
	if _, err := apple.VerifyJWS(strings.Join(parts, "."), chain.Roots); err == nil {
		t.Fatal("a tampered payload verified")
	}
}

func TestVerifyJWSRejectsMissingX5C(t *testing.T) {
	chain := appletest.New(t)
	if _, err := apple.VerifyJWS(chain.SignWithoutX5C(t, jwt.MapClaims{"a": 1}), chain.Roots); err == nil {
		t.Fatal("a JWS without an x5c chain verified")
	}
}

// A certificate that chains to the root but is not one of Apple's App Store
// signing certificates must not be accepted.
func TestVerifyJWSRejectsAChainWithoutAppleMarkers(t *testing.T) {
	chain := appletest.NewWithoutMarkers(t)
	if _, err := apple.VerifyJWS(chain.Sign(t, jwt.MapClaims{"a": 1}), chain.Roots); err == nil {
		t.Fatal("a chain without Apple's marker extensions verified")
	}
}

func TestVerifyJWSRejectsOtherAlgorithms(t *testing.T) {
	chain := appletest.New(t)
	hs, err := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{"a": 1}).SignedString([]byte("k"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := apple.VerifyJWS(hs, chain.Roots); err == nil {
		t.Fatal("an HS256 token verified")
	}
}

// The embedded root is Apple Root CA - G3, byte for byte.
func TestRootIsAppleRootCAG3(t *testing.T) {
	if _, err := apple.TrustedRoots(); err != nil {
		t.Fatal(err)
	}
	block, _ := pem.Decode([]byte(apple.RootCAG3PEM))
	sum := sha256.Sum256(block.Bytes)
	const want = "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179"
	if got := hex.EncodeToString(sum[:]); got != want {
		t.Fatalf("root fingerprint = %s, want Apple Root CA - G3 (%s)", got, want)
	}
}
