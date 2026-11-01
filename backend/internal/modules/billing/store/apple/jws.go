package apple

import (
	"crypto/x509"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/golang-jwt/jwt/v5"
)

// RootCAG3PEM is Apple's published root certificate (Apple Root CA - G3),
// the trust anchor for the x5c chain on every JWS Apple signs: StoreKit 2
// transactions, App Store Server API answers and Server Notifications V2.
// Public and stable (valid 2014-2039), not a secret. Ported unchanged from
// the source's webhookauth.AppleRootCAG3PEM, which was fetched from
// https://www.apple.com/certificateauthority/AppleRootCA-G3.cer; its SHA-256
// fingerprint is pinned in TestRootIsAppleRootCAG3.
const RootCAG3PEM = `-----BEGIN CERTIFICATE-----
MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwS
QXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9u
IEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcN
MTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBS
b290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9y
aXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49
AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtf
TjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517
IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySr
MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gA
MGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4
at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM
6BgD56KyKA==
-----END CERTIFICATE-----
`

// TrustedRoots is a pool holding only the embedded Apple root. Verify takes
// the pool as a parameter so a test can substitute its own root.
func TrustedRoots() (*x509.CertPool, error) {
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM([]byte(RootCAG3PEM)) {
		return nil, errors.New("apple: failed to parse the embedded Apple Root CA G3 certificate")
	}
	return pool, nil
}

// The marker extensions Apple puts on the certificates that sign App Store
// JWS: the leaf (Mac App Store receipt signing) and the intermediate (Apple
// Worldwide Developer Relations). Apple's own server library requires both;
// without the check, any certificate Apple ever issued under G3 for some
// other purpose would chain, too. Added on top of the source's port.
var (
	leafMarkerOID         = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 11, 1}
	intermediateMarkerOID = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 2, 1}
)

// VerifyJWS verifies an Apple-signed JWS against roots and returns its
// claims. The chain check (leaf to intermediate to roots) is the
// authenticity check: a forged payload cannot produce a leaf that chains to
// Apple's root. Ported from the source's webhookauth.VerifyAppleJWS.
func VerifyJWS(signed string, roots *x509.CertPool) (jwt.MapClaims, error) {
	var claims jwt.MapClaims
	parser := jwt.NewParser(jwt.WithValidMethods([]string{"ES256"}))
	token, err := parser.ParseWithClaims(signed, &claims, func(token *jwt.Token) (any, error) {
		return leafPublicKey(token, roots)
	})
	if err != nil {
		return nil, fmt.Errorf("apple: verify JWS: %w", err)
	}
	if !token.Valid {
		return nil, errors.New("apple: JWS failed validation")
	}
	return claims, nil
}

// Decode verifies signed and decodes its claims into T.
func Decode[T any](signed string, roots *x509.CertPool) (T, error) {
	var out T
	claims, err := VerifyJWS(signed, roots)
	if err != nil {
		return out, err
	}
	raw, err := json.Marshal(claims)
	if err != nil {
		return out, fmt.Errorf("apple: marshal claims: %w", err)
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return out, fmt.Errorf("apple: decode claims: %w", err)
	}
	return out, nil
}

// leafPublicKey verifies the x5c chain in the token header against roots
// and returns the leaf's key. It runs before the signature check, so a
// chain that does not reach roots never gets as far as "is the signature
// valid".
func leafPublicKey(token *jwt.Token, roots *x509.CertPool) (any, error) {
	rawChain, ok := token.Header["x5c"].([]any)
	if !ok || len(rawChain) == 0 {
		return nil, errors.New("apple: JWS header has no x5c certificate chain")
	}
	certs := make([]*x509.Certificate, 0, len(rawChain))
	for i, entry := range rawChain {
		s, ok := entry.(string)
		if !ok {
			return nil, fmt.Errorf("apple: x5c[%d] is not a string", i)
		}
		der, err := base64.StdEncoding.DecodeString(s)
		if err != nil {
			return nil, fmt.Errorf("apple: decode x5c[%d]: %w", i, err)
		}
		cert, err := x509.ParseCertificate(der)
		if err != nil {
			return nil, fmt.Errorf("apple: parse x5c[%d]: %w", i, err)
		}
		certs = append(certs, cert)
	}
	if len(certs) < 2 {
		return nil, errors.New("apple: x5c chain has no intermediate")
	}
	leaf := certs[0]
	intermediates := x509.NewCertPool()
	for _, c := range certs[1:] {
		intermediates.AddCert(c)
	}
	if _, err := leaf.Verify(x509.VerifyOptions{
		Roots:         roots,
		Intermediates: intermediates,
		// Apple's signing leaves carry no TLS key usage; chain of trust and
		// validity window are what matter here.
		KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageAny},
	}); err != nil {
		return nil, fmt.Errorf("apple: x5c chain does not verify against the trusted roots: %w", err)
	}
	if !hasExtension(leaf, leafMarkerOID) || !hasExtension(certs[1], intermediateMarkerOID) {
		return nil, errors.New("apple: x5c chain lacks Apple's App Store signing markers")
	}
	return leaf.PublicKey, nil
}

func hasExtension(c *x509.Certificate, oid asn1.ObjectIdentifier) bool {
	for _, e := range c.Extensions {
		if e.Id.Equal(oid) {
			return true
		}
	}
	return false
}
