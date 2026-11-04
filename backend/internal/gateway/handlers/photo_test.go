package handlers

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"testing"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func (s *testServer) putPhoto(contentType string, body []byte, bearer string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(http.MethodPut, "/v1/users/me/photo", bytes.NewReader(body))
	r.Header.Set("Content-Type", contentType)
	if bearer != "" {
		r.Header.Set("Authorization", "Bearer "+bearer)
	}
	rec := httptest.NewRecorder()
	s.mux.ServeHTTP(rec, r)
	return rec
}

func TestPutPhoto(t *testing.T) {
	s := newTestServer(t)
	token := s.tokenFor(t, "user-1", 1)
	rec := s.putPhoto("image/jpeg", []byte("pic"), token)
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d", rec.Code)
	}
	if got := decodeBody(t, rec)["photo_url"]; got != "/v1/users/user-1/photo?v=e1" {
		t.Errorf("photo_url = %v", got)
	}
	if s.monolith.gotUserID != "user-1" || string(s.monolith.gotPhoto) != "pic" {
		t.Errorf("forwarded %q for %q", s.monolith.gotPhoto, s.monolith.gotUserID)
	}
	for _, ct := range []string{"image/png", "image/webp", "image/jpeg; charset=x"} {
		if rec := s.putPhoto(ct, []byte("pic"), token); rec.Code != http.StatusOK {
			t.Errorf("%s: %d", ct, rec.Code)
		}
	}
	if rec := s.putPhoto("image/gif", []byte("pic"), token); rec.Code != http.StatusUnsupportedMediaType {
		t.Errorf("a gif: %d", rec.Code)
	}
	if rec := s.putPhoto("image/jpeg", make([]byte, 300<<10+1), token); rec.Code != http.StatusRequestEntityTooLarge {
		t.Errorf("301 KB: %d", rec.Code)
	}
	if rec := s.putPhoto("image/jpeg", []byte("pic"), ""); rec.Code != http.StatusUnauthorized {
		t.Errorf("no token: %d", rec.Code)
	}
}

func TestDeletePhoto(t *testing.T) {
	s := newTestServer(t)
	rec := s.do(http.MethodDelete, "/v1/users/me/photo", "", s.tokenFor(t, "user-1", 1))
	if rec.Code != http.StatusNoContent || s.monolith.gotUserID != "user-1" {
		t.Errorf("status %d for %q", rec.Code, s.monolith.gotUserID)
	}
}

func TestGetPhoto(t *testing.T) {
	s := newTestServer(t)
	token := s.tokenFor(t, "viewer", 1)
	rec := s.do(http.MethodGet, "/v1/users/other/photo?v=e1", "", token)
	if rec.Code != http.StatusOK || rec.Body.String() != "jpeg bytes" {
		t.Fatalf("status %d, body %q", rec.Code, rec.Body.String())
	}
	for header, want := range map[string]string{
		"Content-Type":           "image/jpeg",
		"ETag":                   `"e1"`,
		"Cache-Control":          "private, max-age=86400",
		"X-Content-Type-Options": "nosniff",
	} {
		if got := rec.Header().Get(header); got != want {
			t.Errorf("%s = %q, want %q", header, got, want)
		}
	}

	r := httptest.NewRequest(http.MethodGet, "/v1/users/other/photo?v=e1", nil)
	r.Header.Set("Authorization", "Bearer "+token)
	r.Header.Set("If-None-Match", `"e1"`)
	conditional := httptest.NewRecorder()
	s.mux.ServeHTTP(conditional, r)
	if conditional.Code != http.StatusNotModified || conditional.Body.Len() != 0 {
		t.Errorf("a matching etag: %d with %d bytes", conditional.Code, conditional.Body.Len())
	}

	if rec := s.do(http.MethodGet, "/v1/users/other/photo", "", ""); rec.Code != http.StatusUnauthorized {
		t.Errorf("no token: %d", rec.Code)
	}
}

// Plan 2.1: a guest sees their own photo and no one else's.
func TestGetPhotoFollowsTheGuestRule(t *testing.T) {
	s := newTestServer(t)
	guest := s.tokenFor(t, "guest-1", 0)
	if rec := s.do(http.MethodGet, "/v1/users/other/photo", "", guest); rec.Code != http.StatusNotFound {
		t.Errorf("a guest asking for someone else: %d", rec.Code)
	}
	if rec := s.do(http.MethodGet, "/v1/users/guest-1/photo", "", guest); rec.Code != http.StatusOK {
		t.Errorf("a guest asking for their own: %d", rec.Code)
	}
}

func TestGetPhotoThatDoesNotExist(t *testing.T) {
	s := newTestServer(t)
	s.monolith.err = status.Error(codes.NotFound, "no photo")
	if rec := s.do(http.MethodGet, "/v1/users/other/photo", "", s.tokenFor(t, "viewer", 1)); rec.Code != http.StatusNotFound {
		t.Errorf("status %d", rec.Code)
	}
}

// No external address is ever served, even one left from before the backfill.
func TestPhotoPathOnlyPassesOurOwn(t *testing.T) {
	if got := photoPath("https://media.licdn.com/a.jpg"); got != "" {
		t.Errorf("an external address passed: %q", got)
	}
	if got := photoPath("/v1/users/u/photo?v=e"); got == "" {
		t.Error("our own path was dropped")
	}
}
