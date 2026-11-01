// Package clientinfo carries which app build made a request — its version
// and platform — from the HTTP edge to the module code that needs it (plan
// 29 §2).
//
// The client sends X-App-Version and X-Platform. The gateway middleware reads
// them into the request context; the monolith client's interceptor copies
// them onto every outgoing gRPC call as metadata; the monolith's server
// interceptor puts them back into the context. Module code calls From(ctx).
//
// Carried as metadata rather than as fields on each RPC so every route has
// them without forty proto changes, and so a route added later cannot forget
// them.
//
// Neither value is trusted for anything that grants access. They decide
// whether an old build gets "please update" instead of being silently
// charged (plan 29 §2); a client lying about its version only gets the
// newer behaviour it claims to support.
package clientinfo

import (
	"context"
	"net/http"
	"regexp"
	"strings"

	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
)

// Header and metadata names.
const (
	HeaderAppVersion   = "X-App-Version"
	HeaderPlatform     = "X-Platform"
	metadataAppVersion = "x-app-version"
	metadataPlatform   = "x-platform"
)

// Info is one request's client build. Both fields are empty for a client
// that sent no headers, which is every app build older than plan 29C.
type Info struct {
	AppVersion string
	Platform   string
}

type ctxKey struct{}

// With returns ctx carrying info, after sanitising it.
func With(ctx context.Context, info Info) context.Context {
	return context.WithValue(ctx, ctxKey{}, sanitize(info))
}

// From returns the request's client build, or the zero Info.
func From(ctx context.Context) Info {
	info, _ := ctx.Value(ctxKey{}).(Info)
	return info
}

// versionPattern accepts "1", "1.4", "1.4.0", optionally with "+build" —
// what Flutter's package_info reports — and nothing a log line or a metric
// label could be abused with.
var versionPattern = regexp.MustCompile(`^[0-9]{1,6}(\.[0-9]{1,6}){0,2}(\+[0-9A-Za-z.]{1,16})?$`)

func sanitize(info Info) Info {
	v := strings.TrimSpace(info.AppVersion)
	if !versionPattern.MatchString(v) {
		v = ""
	}
	p := strings.ToLower(strings.TrimSpace(info.Platform))
	switch p {
	case "ios", "android", "web":
	default:
		p = ""
	}
	return Info{AppVersion: v, Platform: p}
}

// Middleware reads the two headers into the request context. Applied to the
// whole gateway mux, before routing.
func Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx := With(r.Context(), Info{
			AppVersion: r.Header.Get(HeaderAppVersion),
			Platform:   r.Header.Get(HeaderPlatform),
		})
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// UnaryClientInterceptor copies the context's client build onto the
// outgoing call. Empty values are not sent.
func UnaryClientInterceptor() grpc.UnaryClientInterceptor {
	return func(ctx context.Context, method string, req, reply any, cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
		info := From(ctx)
		if info.AppVersion != "" {
			ctx = metadata.AppendToOutgoingContext(ctx, metadataAppVersion, info.AppVersion)
		}
		if info.Platform != "" {
			ctx = metadata.AppendToOutgoingContext(ctx, metadataPlatform, info.Platform)
		}
		return invoker(ctx, method, req, reply, cc, opts...)
	}
}

// UnaryServerInterceptor puts the incoming call's client build into the
// handler's context.
func UnaryServerInterceptor() grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, _ *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		md, _ := metadata.FromIncomingContext(ctx)
		first := func(key string) string {
			if v := md.Get(key); len(v) > 0 {
				return v[0]
			}
			return ""
		}
		ctx = With(ctx, Info{AppVersion: first(metadataAppVersion), Platform: first(metadataPlatform)})
		return handler(ctx, req)
	}
}
