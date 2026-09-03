package logging

import "net/http"

// RequestIDHeader is the HTTP header used to propagate the request ID
// between client and server, and between the gateway and any upstream proxy
// in front of it.
const RequestIDHeader = "X-Request-ID"

// HTTPMiddleware generates or propagates an X-Request-ID for every request:
// it reuses an incoming header value if present, otherwise generates one,
// stores it in the request context (retrievable via RequestIDFromContext /
// FromContext so handlers attach it to their log lines), and echoes it back
// on the response.
func HTTPMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := r.Header.Get(RequestIDHeader)
		if id == "" {
			id = NewRequestID()
		}

		w.Header().Set(RequestIDHeader, id)
		ctx := WithRequestID(r.Context(), id)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}
