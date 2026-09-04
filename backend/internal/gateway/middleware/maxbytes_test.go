package middleware

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestMaxBytes_RejectsAnOversizedBody(t *testing.T) {
	handler := MaxBytes(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, "invalid request body", http.StatusBadRequest)
			return
		}
		w.WriteHeader(http.StatusOK)
	}))

	oversized := `{"full_name":"` + strings.Repeat("a", maxRequestBodyBytes+1) + `"}`
	req := httptest.NewRequest(http.MethodPost, "/anything", bytes.NewBufferString(oversized))
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want %d (oversized body must not decode successfully)", rec.Code, http.StatusBadRequest)
	}
}

func TestMaxBytes_AllowsAnOrdinaryBody(t *testing.T) {
	handler := MaxBytes(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, "invalid request body", http.StatusBadRequest)
			return
		}
		w.WriteHeader(http.StatusOK)
	}))

	req := httptest.NewRequest(http.MethodPost, "/anything", bytes.NewBufferString(`{"full_name":"Ada Lovelace"}`))
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Errorf("status = %d, want %d", rec.Code, http.StatusOK)
	}
}
