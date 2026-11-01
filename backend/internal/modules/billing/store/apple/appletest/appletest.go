// Package appletest builds a real certificate chain shaped like Apple's
// (root, intermediate and leaf, with Apple's App Store marker extensions)
// under a locally generated root, so tests exercise the real chain and
// signature checks without Apple's key. Ported from the source's
// webhookauth test helper, exported so the billing module's webhook tests
// can sign notifications too.
package appletest

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/base64"
	"math/big"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// Chain is a test trust root and a leaf that signs under it.
type Chain struct {
	Roots        *x509.CertPool
	leafB64      string
	interB64     string
	leafKey      *ecdsa.PrivateKey
	withoutMarks bool
}

var (
	leafMarker         = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 11, 1}
	intermediateMarker = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 2, 1}
)

// New builds a chain carrying Apple's marker extensions.
func New(t testing.TB) Chain { return build(t, true) }

// NewWithoutMarkers builds a chain that verifies cryptographically but lacks
// Apple's App Store markers.
func NewWithoutMarkers(t testing.TB) Chain { return build(t, false) }

func build(t testing.TB, marks bool) Chain {
	t.Helper()
	key := func() *ecdsa.PrivateKey {
		k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			t.Fatalf("generate key: %v", err)
		}
		return k
	}
	ext := func(oid asn1.ObjectIdentifier) []pkix.Extension {
		if !marks {
			return nil
		}
		return []pkix.Extension{{Id: oid, Value: []byte{0x05, 0x00}}}
	}
	create := func(tmpl, parent *x509.Certificate, pub *ecdsa.PublicKey, signer *ecdsa.PrivateKey) *x509.Certificate {
		der, err := x509.CreateCertificate(rand.Reader, tmpl, parent, pub, signer)
		if err != nil {
			t.Fatalf("create cert: %v", err)
		}
		c, err := x509.ParseCertificate(der)
		if err != nil {
			t.Fatalf("parse cert: %v", err)
		}
		return c
	}
	now := time.Now()
	rootKey, interKey, leafKey := key(), key(), key()
	rootTmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "Test Root CA"},
		NotBefore: now.Add(-time.Hour), NotAfter: now.Add(24 * time.Hour),
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
	}
	root := create(rootTmpl, rootTmpl, &rootKey.PublicKey, rootKey)
	inter := create(&x509.Certificate{
		SerialNumber: big.NewInt(2), Subject: pkix.Name{CommonName: "Test Intermediate CA"},
		NotBefore: now.Add(-time.Hour), NotAfter: now.Add(24 * time.Hour),
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
		ExtraExtensions: ext(intermediateMarker),
	}, root, &interKey.PublicKey, rootKey)
	leaf := create(&x509.Certificate{
		SerialNumber: big.NewInt(3), Subject: pkix.Name{CommonName: "Test Leaf (App Store)"},
		NotBefore: now.Add(-time.Hour), NotAfter: now.Add(24 * time.Hour),
		KeyUsage: x509.KeyUsageDigitalSignature, ExtraExtensions: ext(leafMarker),
	}, inter, &leafKey.PublicKey, interKey)

	pool := x509.NewCertPool()
	pool.AddCert(root)
	return Chain{
		Roots:   pool,
		leafB64: base64.StdEncoding.EncodeToString(leaf.Raw), interB64: base64.StdEncoding.EncodeToString(inter.Raw),
		leafKey: leafKey, withoutMarks: !marks,
	}
}

// Sign makes a JWS over claims with the chain in its x5c header.
func (c Chain) Sign(t testing.TB, claims jwt.MapClaims) string {
	t.Helper()
	tok := jwt.NewWithClaims(jwt.SigningMethodES256, claims)
	tok.Header["x5c"] = []any{c.leafB64, c.interB64}
	s, err := tok.SignedString(c.leafKey)
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	return s
}

// SignWithoutX5C signs with the leaf key but no chain at all.
func (c Chain) SignWithoutX5C(t testing.TB, claims jwt.MapClaims) string {
	t.Helper()
	s, err := jwt.NewWithClaims(jwt.SigningMethodES256, claims).SignedString(c.leafKey)
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	return s
}

// Transaction is a signed StoreKit 2 transaction's claims.
func Transaction(transactionID, originalID, bundleID, productID, typ, accountToken, environment string, expires *time.Time) jwt.MapClaims {
	c := jwt.MapClaims{
		"transactionId": transactionID, "originalTransactionId": originalID, "bundleId": bundleID,
		"productId": productID, "type": typ, "purchaseDate": time.Now().Add(-time.Minute).UnixMilli(),
		"quantity": 1, "appAccountToken": accountToken, "environment": environment,
		"inAppOwnershipType": "PURCHASED", "signedDate": time.Now().UnixMilli(),
	}
	if expires != nil {
		c["expiresDate"] = expires.UnixMilli()
	}
	return c
}
