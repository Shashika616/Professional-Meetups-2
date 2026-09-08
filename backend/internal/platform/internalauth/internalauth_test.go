package internalauth

import (
	"context"
	"net"
	"testing"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"

	authv1 "professional-meetups-monolith/backend/internal/proto/auth/v1"
)

const testSecret = "s3cr3t-shared-value"

// --- interceptor unit tests -------------------------------------------

func TestUnaryServerInterceptor(t *testing.T) {
	tests := []struct {
		name         string
		md           metadata.MD
		wantHandler  bool
		wantRejected bool
	}{
		{
			name:        "correct secret",
			md:          metadata.Pairs(MetadataKey, testSecret),
			wantHandler: true,
		},
		{
			name:         "no metadata at all",
			md:           nil,
			wantRejected: true,
		},
		{
			name:         "metadata present but key missing",
			md:           metadata.Pairs("some-other-key", "value"),
			wantRejected: true,
		},
		{
			name:         "empty value",
			md:           metadata.Pairs(MetadataKey, ""),
			wantRejected: true,
		},
		{
			name:         "wrong secret",
			md:           metadata.Pairs(MetadataKey, "not-the-secret"),
			wantRejected: true,
		},
		{
			name:         "right secret with the wrong case",
			md:           metadata.Pairs(MetadataKey, "S3CR3T-SHARED-VALUE"),
			wantRejected: true,
		},
		{
			name:         "correct secret as a prefix of a longer value",
			md:           metadata.Pairs(MetadataKey, testSecret+"extra"),
			wantRejected: true,
		},
		{
			// Several values would let one call carry several guesses.
			name:         "multiple values, one of them correct",
			md:           metadata.Pairs(MetadataKey, "wrong", MetadataKey, testSecret),
			wantRejected: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			handlerRan := false
			handler := func(context.Context, any) (any, error) {
				handlerRan = true
				return "ok", nil
			}

			ctx := context.Background()
			if tt.md != nil {
				ctx = metadata.NewIncomingContext(ctx, tt.md)
			}

			_, err := UnaryServerInterceptor([]string{testSecret})(ctx, nil, &grpc.UnaryServerInfo{}, handler)

			if tt.wantRejected {
				if err == nil {
					t.Fatal("call was accepted, want rejection")
				}
				if code := status.Code(err); code != codes.Unauthenticated {
					t.Errorf("code = %v, want %v", code, codes.Unauthenticated)
				}
				if handlerRan {
					t.Error("the handler ran anyway — rejection must happen BEFORE the handler")
				}
				return
			}

			if err != nil {
				t.Fatalf("call was rejected: %v", err)
			}
			if !handlerRan {
				t.Error("handler did not run")
			}
		})
	}
}

func TestUnaryClientInterceptor_AttachesTheSecret(t *testing.T) {
	var seen []string
	invoker := func(ctx context.Context, _ string, _, _ any, _ *grpc.ClientConn, _ ...grpc.CallOption) error {
		md, ok := metadata.FromOutgoingContext(ctx)
		if !ok {
			t.Fatal("no outgoing metadata")
		}
		seen = md.Get(MetadataKey)
		return nil
	}

	if err := UnaryClientInterceptor(testSecret)(context.Background(), "/svc/Method", nil, nil, nil, invoker); err != nil {
		t.Fatalf("interceptor returned error: %v", err)
	}
	if len(seen) != 1 || seen[0] != testSecret {
		t.Errorf("outgoing %s = %v, want exactly [%q]", MetadataKey, seen, testSecret)
	}
}

// --- end-to-end over a real gRPC connection ---------------------------

// recordingAuthServer stands in for the real auth module and records whether
// it was ever reached. The whole point of the tests below is that an
// unauthenticated call must NOT reach it.
type recordingAuthServer struct {
	authv1.UnimplementedAuthServiceServer
	called bool
}

func (s *recordingAuthServer) GetProfile(context.Context, *authv1.GetProfileRequest) (*authv1.ProfileResponse, error) {
	s.called = true
	return &authv1.ProfileResponse{UserId: "user-1"}, nil
}

// newTestServer starts a real gRPC server with the interceptor installed the
// same way cmd/monolith installs it, and returns a client dialled with
// whatever secret the caller wants to present.
func newTestServer(t *testing.T, serverSecret, clientSecret string) (*recordingAuthServer, authv1.AuthServiceClient) {
	t.Helper()

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}

	svc := &recordingAuthServer{}
	server := grpc.NewServer(grpc.ChainUnaryInterceptor(UnaryServerInterceptor([]string{serverSecret})))
	authv1.RegisterAuthServiceServer(server, svc)
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(server.Stop)

	opts := []grpc.DialOption{grpc.WithTransportCredentials(insecure.NewCredentials())}
	if clientSecret != "" {
		opts = append(opts, grpc.WithUnaryInterceptor(UnaryClientInterceptor(clientSecret)))
	}
	conn, err := grpc.NewClient(listener.Addr().String(), opts...)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })

	return svc, authv1.NewAuthServiceClient(conn)
}

// TestGRPCCallWithoutTheSecretNeverReachesTheModule is the finding this fix
// closes: before it, anything that could reach the monolith's port could call
// any method as any user. A caller with no secret must be stopped at the
// interceptor, not inside the module.
func TestGRPCCallWithoutTheSecretNeverReachesTheModule(t *testing.T) {
	svc, client := newTestServer(t, testSecret, "") // no client interceptor at all

	_, err := client.GetProfile(context.Background(), &authv1.GetProfileRequest{UserId: "victim"})

	if err == nil {
		t.Fatal("an unauthenticated gRPC call succeeded")
	}
	if code := status.Code(err); code != codes.Unauthenticated {
		t.Errorf("code = %v, want %v", code, codes.Unauthenticated)
	}
	if svc.called {
		t.Error("the call reached the auth module — authentication must reject it before any business logic runs")
	}
}

func TestGRPCCallWithTheWrongSecretNeverReachesTheModule(t *testing.T) {
	svc, client := newTestServer(t, testSecret, "a-different-secret")

	_, err := client.GetProfile(context.Background(), &authv1.GetProfileRequest{UserId: "victim"})

	if err == nil {
		t.Fatal("a gRPC call with the wrong secret succeeded")
	}
	if code := status.Code(err); code != codes.Unauthenticated {
		t.Errorf("code = %v, want %v", code, codes.Unauthenticated)
	}
	if svc.called {
		t.Error("the call reached the auth module despite a wrong secret")
	}
}

// TestGRPCCallWithTheCorrectSecretReachesTheModule is the other half: the
// real gateway path must still work, or this check would be a very effective
// outage.
func TestGRPCCallWithTheCorrectSecretReachesTheModule(t *testing.T) {
	svc, client := newTestServer(t, testSecret, testSecret)

	resp, err := client.GetProfile(context.Background(), &authv1.GetProfileRequest{UserId: "user-1"})
	if err != nil {
		t.Fatalf("an authenticated call was rejected: %v", err)
	}
	if !svc.called {
		t.Error("the handler never ran")
	}
	if resp.GetUserId() != "user-1" {
		t.Errorf("user_id = %q, want user-1", resp.GetUserId())
	}
}

// --- §A2: rotation window -------------------------------------------------

// TestParseSecrets covers the configuration parsing that gates rotation. The
// empty-element case is the one that actually matters for security: without
// the check, "old," (a trailing comma, trivially easy to leave behind while
// editing a .env) would add "" to the accepted set, and every unauthenticated
// caller sends an empty or absent value.
func TestParseSecrets(t *testing.T) {
	tests := []struct {
		name    string
		raw     string
		want    []string
		wantErr bool
	}{
		{name: "single secret", raw: "abc", want: []string{"abc"}},
		{name: "old and new during rotation", raw: "old-secret,new-secret", want: []string{"old-secret", "new-secret"}},
		{name: "surrounding whitespace is trimmed", raw: " old-secret , new-secret ", want: []string{"old-secret", "new-secret"}},
		{name: "empty value is rejected", raw: "", wantErr: true},
		{name: "whitespace-only value is rejected", raw: "   ", wantErr: true},
		{name: "trailing comma is rejected, not treated as an empty accepted secret", raw: "abc,", wantErr: true},
		{name: "leading comma is rejected", raw: ",abc", wantErr: true},
		{name: "interior empty element is rejected", raw: "abc,,def", wantErr: true},
		{name: "duplicate entries are rejected as a config mistake", raw: "abc,abc", wantErr: true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := ParseSecrets(tc.raw)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("ParseSecrets(%q) = %v, want an error", tc.raw, got)
				}
				return
			}
			if err != nil {
				t.Fatalf("ParseSecrets(%q) error: %v", tc.raw, err)
			}
			if len(got) != len(tc.want) {
				t.Fatalf("ParseSecrets(%q) = %v, want %v", tc.raw, got, tc.want)
			}
			for i := range got {
				if got[i] != tc.want[i] {
					t.Fatalf("ParseSecrets(%q) = %v, want %v", tc.raw, got, tc.want)
				}
			}
		})
	}
}

// TestUnaryServerInterceptor_AcceptsAnyConfiguredSecret is the actual
// rotation guarantee: during step 1 of the procedure the monolith accepts
// both, so a gateway still on the old secret and a gateway already on the
// new one are both served. Without this there is a window where one of them
// gets Unauthenticated on every call.
func TestUnaryServerInterceptor_AcceptsAnyConfiguredSecret(t *testing.T) {
	const oldSecret, newSecret = "old-shared-secret", "new-shared-secret"
	interceptor := UnaryServerInterceptor([]string{oldSecret, newSecret})

	handler := func(context.Context, any) (any, error) { return "ok", nil }

	for _, presented := range []string{oldSecret, newSecret} {
		ctx := metadata.NewIncomingContext(context.Background(), metadata.Pairs(MetadataKey, presented))
		if _, err := interceptor(ctx, nil, &grpc.UnaryServerInfo{}, handler); err != nil {
			t.Errorf("a caller presenting a configured secret was rejected: %v", err)
		}
	}

	// A secret that has been rotated OUT (step 3 of the procedure) must stop
	// working — the overlap is a window, not a permanent widening.
	retired := UnaryServerInterceptor([]string{newSecret})
	ctx := metadata.NewIncomingContext(context.Background(), metadata.Pairs(MetadataKey, oldSecret))
	if _, err := retired(ctx, nil, &grpc.UnaryServerInfo{}, handler); err == nil {
		t.Error("a secret removed from the accepted set was still accepted — rotation never actually retires the old value")
	}
}

// TestUnaryServerInterceptor_MultipleSecretsStillRejectAnEmptyPresentedValue
// guards the same hole ParseSecrets guards, one layer lower: even if a bad
// configuration ever reached the interceptor, an empty presented value must
// not match a real secret.
func TestUnaryServerInterceptor_MultipleSecretsStillRejectAnEmptyPresentedValue(t *testing.T) {
	interceptor := UnaryServerInterceptor([]string{"a-real-secret", "another-real-secret"})
	handler := func(context.Context, any) (any, error) { return "ok", nil }

	ctx := metadata.NewIncomingContext(context.Background(), metadata.Pairs(MetadataKey, ""))
	if _, err := interceptor(ctx, nil, &grpc.UnaryServerInfo{}, handler); err == nil {
		t.Error("an empty presented secret was accepted against a non-empty accepted set")
	}
}
