package meetup

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"testing"

	"professional-meetups-monolith/backend/internal/platform/geo"
)

// Plan 30B, 3.3: one radius. The SQL cannot import the Go constant, so
// every ST_DWithin distance in this module's queries must equal it.
func TestEveryQueryUsesTheOneBrowseRadius(t *testing.T) {
	files, err := filepath.Glob(filepath.Join("repository", "queries", "*.sql"))
	if err != nil {
		t.Fatal(err)
	}
	// ST_DWithin(a, b, <meters>): the number after the second argument.
	distance := regexp.MustCompile(`(?s)ST_DWithin\(.*?::geography,\s*(\d+)\s*\)`)
	found := 0
	for _, f := range files {
		body, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		for _, m := range distance.FindAllSubmatch(body, -1) {
			found++
			if n, _ := strconv.Atoi(string(m[1])); n != geo.BrowseRadiusMeters {
				t.Errorf("%s uses a %d m radius, want geo.BrowseRadiusMeters (%d)", f, n, geo.BrowseRadiusMeters)
			}
		}
	}
	if found < 3 {
		t.Fatalf("found %d radius uses; the parse is broken", found)
	}
}
