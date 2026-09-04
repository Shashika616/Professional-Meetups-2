package middleware

import "net/http"

// maxRequestBodyBytes bounds every request body this gateway will read —
// 1 MiB is generous for any JSON body this API actually accepts (the
// largest legitimate payload is a handful of short strings, e.g. full
// name/company name/address on the verification routes), but rules out a
// caller streaming an arbitrarily large body at a handler that would
// otherwise buffer all of it via json.NewDecoder before any field-level
// validation runs.
const maxRequestBodyBytes = 1 << 20 // 1 MiB

// MaxBytes wraps every request body in an http.MaxBytesReader, so reading
// past the limit fails fast with an error instead of a handler's
// json.Decoder buffering an unbounded body into memory. Applied globally
// (main.go's middleware chain), like RateLimit/Recover — this is a body-size
// floor every route shares, not a per-route concern.
func MaxBytes(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, maxRequestBodyBytes)
		next.ServeHTTP(w, r)
	})
}
