package linkedin

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
)

func TestExchangeCode(t *testing.T) {
	tests := []struct {
		name       string
		statusCode int
		body       string
		wantErr    bool
		wantToken  Token
	}{
		{
			name:       "success",
			statusCode: http.StatusOK,
			body:       `{"access_token":"li-access-token","expires_in":5184000}`,
			wantToken:  Token{AccessToken: "li-access-token", ExpiresIn: 5184000},
		},
		{
			name:       "linkedin rejects the code",
			statusCode: http.StatusBadRequest,
			body:       `{"error":"invalid_grant","error_description":"expired or already used code"}`,
			wantErr:    true,
		},
		{
			name:       "malformed json",
			statusCode: http.StatusOK,
			body:       `not json`,
			wantErr:    true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var gotForm url.Values
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method != http.MethodPost {
					t.Errorf("method = %s, want POST", r.Method)
				}
				if ct := r.Header.Get("Content-Type"); ct != "application/x-www-form-urlencoded" {
					t.Errorf("Content-Type = %q, want form-urlencoded", ct)
				}
				if err := r.ParseForm(); err != nil {
					t.Fatalf("parse form: %v", err)
				}
				gotForm = r.PostForm

				w.WriteHeader(tt.statusCode)
				_, _ = w.Write([]byte(tt.body))
			}))
			defer server.Close()

			client := New(Config{ClientID: "cid", ClientSecret: "csecret"}, WithTokenURL(server.URL))

			got, err := client.ExchangeCode(context.Background(), "auth-code", "app://callback")
			if tt.wantErr {
				if err == nil {
					t.Fatal("ExchangeCode() returned nil error, want error")
				}
				return
			}
			if err != nil {
				t.Fatalf("ExchangeCode() returned error: %v", err)
			}
			if got != tt.wantToken {
				t.Errorf("ExchangeCode() = %+v, want %+v", got, tt.wantToken)
			}

			if gotForm.Get("grant_type") != "authorization_code" {
				t.Errorf("grant_type = %q, want authorization_code", gotForm.Get("grant_type"))
			}
			if gotForm.Get("code") != "auth-code" {
				t.Errorf("code = %q, want auth-code", gotForm.Get("code"))
			}
			// Regression guard: LinkedIn's Sign In with LinkedIn / OpenID
			// Connect product rejects the exchange with 401 invalid_client
			// when a code_verifier is present (confirmed via direct testing
			// against LinkedIn's real endpoint) — this must never be sent.
			if gotForm.Has("code_verifier") {
				t.Errorf("code_verifier was sent (%q) — LinkedIn rejects this product's exchange when it's present", gotForm.Get("code_verifier"))
			}
			if gotForm.Get("redirect_uri") != "app://callback" {
				t.Errorf("redirect_uri = %q, want app://callback", gotForm.Get("redirect_uri"))
			}
			if gotForm.Get("client_id") != "cid" {
				t.Errorf("client_id = %q, want cid", gotForm.Get("client_id"))
			}
			if gotForm.Get("client_secret") != "csecret" {
				t.Errorf("client_secret = %q, want csecret", gotForm.Get("client_secret"))
			}
		})
	}
}

func TestFetchUserInfo(t *testing.T) {
	tests := []struct {
		name       string
		statusCode int
		body       string
		wantErr    bool
		wantInfo   UserInfo
	}{
		{
			name:       "success",
			statusCode: http.StatusOK,
			body:       `{"sub":"abc123","name":"Ada Lovelace","picture":"https://example.com/p.jpg","email":"ada@example.com"}`,
			wantInfo:   UserInfo{Sub: "abc123", Name: "Ada Lovelace", Picture: "https://example.com/p.jpg"},
		},
		{
			name:       "expired token",
			statusCode: http.StatusUnauthorized,
			body:       `{"error":"invalid_token"}`,
			wantErr:    true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var gotAuthHeader string
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				gotAuthHeader = r.Header.Get("Authorization")
				w.WriteHeader(tt.statusCode)
				_, _ = w.Write([]byte(tt.body))
			}))
			defer server.Close()

			client := New(Config{ClientID: "cid", ClientSecret: "csecret"}, WithUserInfoURL(server.URL))

			got, err := client.FetchUserInfo(context.Background(), Token{AccessToken: "li-token"})
			if tt.wantErr {
				if err == nil {
					t.Fatal("FetchUserInfo() returned nil error, want error")
				}
				return
			}
			if err != nil {
				t.Fatalf("FetchUserInfo() returned error: %v", err)
			}
			if got != tt.wantInfo {
				t.Errorf("FetchUserInfo() = %+v, want %+v", got, tt.wantInfo)
			}
			if gotAuthHeader != "Bearer li-token" {
				t.Errorf("Authorization header = %q, want %q", gotAuthHeader, "Bearer li-token")
			}
		})
	}
}
