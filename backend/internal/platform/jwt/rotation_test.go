package jwt

import (
	"strings"
	"testing"
	"time"

	jwtlib "github.com/golang-jwt/jwt/v5"
)

// TestSign_StampsAKeyIDHeader is the precondition everything else in §A3
// depends on: without a kid in the header there is nothing for a
// multiple-key verifier to route on.
func TestSign_StampsAKeyIDHeader(t *testing.T) {
	privPath, pubPath := generateTestKeypair(t)
	signer, err := NewSigner(privPath)
	if err != nil {
		t.Fatalf("NewSigner: %v", err)
	}
	verifier, err := NewVerifier(pubPath)
	if err != nil {
		t.Fatalf("NewVerifier: %v", err)
	}

	token, err := signer.Sign(Claims{UserID: "user-1", TrustLevel: 2})
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}

	parsed, _, err := jwtlib.NewParser().ParseUnverified(token, &Claims{})
	if err != nil {
		t.Fatalf("ParseUnverified: %v", err)
	}
	kid, ok := parsed.Header["kid"].(string)
	if !ok || kid == "" {
		t.Fatalf("token header has no usable kid: %#v", parsed.Header)
	}
	if kid != signer.KeyID() {
		t.Errorf("token kid = %q, signer reports %q", kid, signer.KeyID())
	}

	// The verifier derives the same id from the public half alone — this is
	// what makes the id self-consistent without being configured anywhere.
	ids := verifier.KeyIDs()
	if len(ids) != 1 || ids[0] != kid {
		t.Errorf("verifier key ids = %v, want exactly [%q]", ids, kid)
	}
}

// TestRotation_TokensFromThePreviousKeyStillVerify is the specific failure
// §A3 closes. Before this, deploying a new signing key invalidated every
// outstanding access token the instant it landed: users were logged out
// mid-session with no way to avoid it. The overlap window has to make a
// token signed by the OLD key verify against a gateway already signing with
// the NEW one.
func TestRotation_TokensFromThePreviousKeyStillVerify(t *testing.T) {
	oldPriv, oldPub := generateTestKeypair(t)
	newPriv, newPub := generateTestKeypair(t)

	oldSigner, err := NewSigner(oldPriv)
	if err != nil {
		t.Fatalf("NewSigner(old): %v", err)
	}
	newSigner, err := NewSigner(newPriv)
	if err != nil {
		t.Fatalf("NewSigner(new): %v", err)
	}

	// A token a user is already holding when the rotation deploys.
	tokenFromOldKey, err := oldSigner.Sign(Claims{UserID: "user-in-flight", TrustLevel: 3})
	if err != nil {
		t.Fatalf("Sign with old key: %v", err)
	}

	// Step 1 of the rotation: current = new, previous = old.
	rotating, err := NewVerifier(newPub, oldPub)
	if err != nil {
		t.Fatalf("NewVerifier(new, old): %v", err)
	}

	claims, err := rotating.Verify(tokenFromOldKey)
	if err != nil {
		t.Fatalf("a token signed by the previous key was rejected during the overlap window: %v", err)
	}
	if claims.UserID != "user-in-flight" || claims.TrustLevel != 3 {
		t.Errorf("claims = %+v, want UserID=user-in-flight TrustLevel=3", claims)
	}

	// And tokens minted by the new key verify on the same verifier.
	tokenFromNewKey, err := newSigner.Sign(Claims{UserID: "user-fresh", TrustLevel: 1})
	if err != nil {
		t.Fatalf("Sign with new key: %v", err)
	}
	if _, err := rotating.Verify(tokenFromNewKey); err != nil {
		t.Fatalf("a token signed by the current key was rejected: %v", err)
	}
}

// TestRotation_RetiredKeyStopsWorking pins the other half: the overlap is a
// window, not a permanent widening of what the gateway accepts. Step 3 of
// the procedure must actually retire the old key.
func TestRotation_RetiredKeyStopsWorking(t *testing.T) {
	oldPriv, oldPub := generateTestKeypair(t)
	_, newPub := generateTestKeypair(t)

	oldSigner, err := NewSigner(oldPriv)
	if err != nil {
		t.Fatalf("NewSigner(old): %v", err)
	}
	tokenFromOldKey, err := oldSigner.Sign(Claims{UserID: "user-1"})
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}

	retired, err := NewVerifier(newPub) // previous key no longer configured
	if err != nil {
		t.Fatalf("NewVerifier: %v", err)
	}
	if _, err := retired.Verify(tokenFromOldKey); err == nil {
		t.Fatal("a token signed by a fully retired key still verified — the old key was never actually retired")
	} else if !strings.Contains(err.Error(), "unknown key id") {
		t.Errorf("rejection reason = %q, want it to name the unknown key id (a retired key must not fall through to trying other keys)", err)
	}

	_ = oldPub
}

// TestRotation_ForeignKeyIsRejected guards the obvious attack on any
// kid-based scheme: a token whose kid names a key the verifier does hold,
// but which was actually signed by a different key, must still fail. The kid
// selects a key; it never authenticates anything by itself.
func TestRotation_ForeignKeyIsRejected(t *testing.T) {
	attackerPriv, _ := generateTestKeypair(t)
	_, realPub := generateTestKeypair(t)

	realVerifier, err := NewVerifier(realPub)
	if err != nil {
		t.Fatalf("NewVerifier: %v", err)
	}
	realKID := realVerifier.KeyIDs()[0]

	attackerSigner, err := NewSigner(attackerPriv)
	if err != nil {
		t.Fatalf("NewSigner: %v", err)
	}
	forged, err := attackerSigner.Sign(Claims{UserID: "victim", TrustLevel: 4})
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}

	// Re-stamp the forged token's header with a kid the verifier trusts.
	parsed, _, err := jwtlib.NewParser().ParseUnverified(forged, &Claims{})
	if err != nil {
		t.Fatalf("ParseUnverified: %v", err)
	}
	parsed.Header["kid"] = realKID
	// Re-signing with the attacker's key keeps the substituted kid in the
	// signed header, which is exactly the token an attacker would present.
	relabelled, err := parsed.SignedString(attackerSigner.privateKey)
	if err != nil {
		t.Fatalf("re-sign with substituted kid: %v", err)
	}

	if _, err := realVerifier.Verify(relabelled); err == nil {
		t.Fatal("a token signed by an unknown key but labelled with a trusted kid was accepted")
	}
}

// TestNewVerifier_RejectsTheSameKeyTwice catches the rotation that never
// happened — a previous-key path still pointing at the current key. Accepting
// it silently would let an operator believe a rotation completed when the
// old key is in fact still the only key.
func TestNewVerifier_RejectsTheSameKeyTwice(t *testing.T) {
	_, pub := generateTestKeypair(t)
	if _, err := NewVerifier(pub, pub); err == nil {
		t.Fatal("NewVerifier accepted the same key as both current and previous")
	}
}

// TestVerify_TokenWithNoKIDFallsBackToTheCurrentKey covers the documented
// upgrade path: access tokens minted before kid.go existed must keep working
// for the rest of their 15-minute life after the deploy that introduces it.
func TestVerify_TokenWithNoKIDFallsBackToTheCurrentKey(t *testing.T) {
	privPath, pubPath := generateTestKeypair(t)
	signer, err := NewSigner(privPath)
	if err != nil {
		t.Fatalf("NewSigner: %v", err)
	}
	verifier, err := NewVerifier(pubPath)
	if err != nil {
		t.Fatalf("NewVerifier: %v", err)
	}

	// Build a token the pre-§A3 way: no kid header at all.
	now := time.Now()
	legacy := jwtlib.NewWithClaims(jwtlib.SigningMethodRS256, &Claims{
		UserID:     "legacy-user",
		TrustLevel: 2,
		RegisteredClaims: jwtlib.RegisteredClaims{
			Issuer:    issuer,
			Subject:   "legacy-user",
			IssuedAt:  jwtlib.NewNumericDate(now),
			ExpiresAt: jwtlib.NewNumericDate(now.Add(AccessTokenTTL)),
		},
	})
	delete(legacy.Header, "kid")
	signed, err := legacy.SignedString(signer.privateKey)
	if err != nil {
		t.Fatalf("sign legacy token: %v", err)
	}

	got, err := verifier.Verify(signed)
	if err != nil {
		t.Fatalf("a pre-rotation token with no kid header was rejected: %v", err)
	}
	if got.UserID != "legacy-user" {
		t.Errorf("UserID = %q, want legacy-user", got.UserID)
	}
}
