package handlers

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

type okHealth struct{}

func (okHealth) CheckHealth(context.Context) error { return nil }

func getMetrics(t *testing.T, access MetricsAccess, authorization string) int {
	t.Helper()
	mux := http.NewServeMux()
	RegisterObservability(mux, okHealth{}, access)
	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	if authorization != "" {
		req.Header.Set("Authorization", authorization)
	}
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	return rec.Code
}

// #93: /metrics was readable by anyone on the production URL. The
// production configuration — on Cloud Run, no token — must not serve it.
func TestMetrics_NotServedInProductionWithoutAToken(t *testing.T) {
	if code := getMetrics(t, MetricsAccess{Public: false}, ""); code != http.StatusNotFound {
		t.Errorf("status %d, want 404: /metrics is reachable in the "+
			"production configuration", code)
	}
}

func TestMetrics_RequiresTheBearerTokenWhenOneIsSet(t *testing.T) {
	access := MetricsAccess{Token: "s3cret-metrics"}
	for _, tc := range []struct {
		name, auth string
		want       int
	}{
		{"no header", "", http.StatusNotFound},
		{"wrong token", "Bearer nope", http.StatusNotFound},
		{"token without the scheme", "s3cret-metrics", http.StatusNotFound},
		{"right token", "Bearer s3cret-metrics", http.StatusOK},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if code := getMetrics(t, access, tc.auth); code != tc.want {
				t.Errorf("status %d, want %d", code, tc.want)
			}
		})
	}
}

// Local and test stacks keep an open /metrics: there the caller is the
// developer and nothing is exposed.
func TestMetrics_OpenOnLocalStacks(t *testing.T) {
	if code := getMetrics(t, MetricsAccess{Public: true}, ""); code != http.StatusOK {
		t.Errorf("status %d, want 200 on a local stack", code)
	}
}

// The health probes are untouched by any of this: a probe that needs a
// token is a probe that cannot run.
func TestReadyz_StillNeedsNoCredential(t *testing.T) {
	mux := http.NewServeMux()
	RegisterObservability(mux, okHealth{}, MetricsAccess{})
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if rec.Code != http.StatusOK {
		t.Errorf("/readyz status %d, want 200", rec.Code)
	}
}
