package handlers

import (
	"net/http"
	"testing"

	"professional-meetups-monolith/backend/internal/gateway/monolithclient"
)

func TestLegalDocumentsAreOpenToEveryone(t *testing.T) {
	s := newTestServer(t)
	s.monolith.legalDocuments = monolithclient.LegalDocuments{Version: "v1", Terms: "t", Privacy: "p"}
	rec := s.do(http.MethodGet, "/v1/legal", "", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d: %s", rec.Code, rec.Body)
	}
	body := decodeBody(t, rec)
	if body["version"] != "v1" || body["terms"] != "t" || body["privacy"] != "p" {
		t.Errorf("body = %v", body)
	}
}

func TestLegalAcceptanceNeedsSignIn(t *testing.T) {
	s := newTestServer(t)
	for _, method := range []string{http.MethodGet, http.MethodPost} {
		if rec := s.do(method, "/v1/legal/acceptance", `{"version":"x"}`, ""); rec.Code != http.StatusUnauthorized {
			t.Errorf("%s status = %d", method, rec.Code)
		}
	}
}

func TestAcceptLegalRecordsTheCaller(t *testing.T) {
	s := newTestServer(t)
	rec := s.do(http.MethodPost, "/v1/legal/acceptance", `{"version":"v1"}`, s.tokenFor(t, "user-1", 1))
	if rec.Code != http.StatusNoContent {
		t.Fatalf("status = %d: %s", rec.Code, rec.Body)
	}
	if s.monolith.gotViewerID != "user-1" || s.monolith.acceptedLegalVersion != "v1" {
		t.Errorf("recorded %q for %q", s.monolith.acceptedLegalVersion, s.monolith.gotViewerID)
	}
	if rec := s.do(http.MethodPost, "/v1/legal/acceptance", `{}`, s.tokenFor(t, "user-1", 1)); rec.Code != http.StatusBadRequest {
		t.Errorf("empty version status = %d", rec.Code)
	}
}

func TestLegalAcceptanceStatus(t *testing.T) {
	s := newTestServer(t)
	s.monolith.legalAccepted = true
	rec := s.do(http.MethodGet, "/v1/legal/acceptance", "", s.tokenFor(t, "user-1", 1))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
	if body := decodeBody(t, rec); body["accepted"] != true {
		t.Errorf("body = %v", body)
	}
}
