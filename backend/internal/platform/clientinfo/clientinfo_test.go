package clientinfo

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
)

func TestMiddlewareReadsAndSanitisesHeaders(t *testing.T) {
	tests := []struct {
		version, platform string
		want              Info
	}{
		{"1.4.0", "android", Info{AppVersion: "1.4.0", Platform: "android"}},
		{"1.0.0+6", "IOS", Info{AppVersion: "1.0.0+6", Platform: "ios"}},
		{"", "", Info{}},
		{"1.0.0; DROP TABLE", "android", Info{AppVersion: "", Platform: "android"}},
		{"1.0.0", "windows-phone", Info{AppVersion: "1.0.0", Platform: ""}},
	}
	for _, tt := range tests {
		var got Info
		h := Middleware(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
			got = From(r.Context())
		}))
		req := httptest.NewRequest(http.MethodGet, "/", nil)
		req.Header.Set(HeaderAppVersion, tt.version)
		req.Header.Set(HeaderPlatform, tt.platform)
		h.ServeHTTP(httptest.NewRecorder(), req)
		if got != tt.want {
			t.Errorf("headers %q/%q gave %+v, want %+v", tt.version, tt.platform, got, tt.want)
		}
	}
}

// The round trip the monolith depends on: what the gateway put into the
// context arrives in the handler's context on the other side.
func TestInterceptorsCarryInfoAcrossTheCall(t *testing.T) {
	ctx := With(context.Background(), Info{AppVersion: "2.1.0", Platform: "ios"})

	var outgoing metadata.MD
	invoker := func(ctx context.Context, _ string, _, _ any, _ *grpc.ClientConn, _ ...grpc.CallOption) error {
		outgoing, _ = metadata.FromOutgoingContext(ctx)
		return nil
	}
	if err := UnaryClientInterceptor()(ctx, "/m", nil, nil, nil, invoker); err != nil {
		t.Fatal(err)
	}

	serverCtx := metadata.NewIncomingContext(context.Background(), outgoing)
	var got Info
	_, _ = UnaryServerInterceptor()(serverCtx, nil, &grpc.UnaryServerInfo{}, func(ctx context.Context, _ any) (any, error) {
		got = From(ctx)
		return nil, nil
	})
	if got != (Info{AppVersion: "2.1.0", Platform: "ios"}) {
		t.Fatalf("server saw %+v", got)
	}
}

func TestServerInterceptorWithNoMetadataIsEmpty(t *testing.T) {
	var got Info
	_, _ = UnaryServerInterceptor()(context.Background(), nil, &grpc.UnaryServerInfo{}, func(ctx context.Context, _ any) (any, error) {
		got = From(ctx)
		return nil, nil
	})
	if got != (Info{}) {
		t.Fatalf("got %+v, want empty", got)
	}
}

// The requester is a hash: no address is carried, and anything else that
// arrives in its place is dropped.
func TestRequesterIsHashedAndSanitised(t *testing.T) {
	got := From(WithRequester(context.Background(), "203.0.113.7")).Requester
	if len(got) != 32 || strings.Contains(got, "203") {
		t.Errorf("requester = %q, want a 32-character hash", got)
	}
	if other := From(WithRequester(context.Background(), "198.51.100.9")).Requester; other == got {
		t.Error("two addresses gave the same requester")
	}
	if r := From(With(context.Background(), Info{Requester: "203.0.113.7"})).Requester; r != "" {
		t.Errorf("a raw address survived as %q", r)
	}
}
