// Command analyticsgen writes the app's analytics constants from the event
// registry, so the app and the server share one source. Run it through
// `go generate ./internal/modules/analytics/registry`; a test in that
// package fails when the checked-in Dart file is out of date.
package main

import (
	"flag"
	"log"
	"os"

	"professional-meetups-monolith/backend/internal/modules/analytics/registry"
)

func main() {
	out := flag.String("out", "", "the Dart file to write")
	flag.Parse()
	if *out == "" {
		log.Fatal("analyticsgen: -out is required")
	}
	// A generated source file in the repository, meant to be readable.
	err := os.WriteFile(*out, registry.Default().Dart(), 0o644) // #nosec G306 -- a generated source file, not a secret
	if err != nil {
		log.Fatalf("analyticsgen: %v", err)
	}
}
