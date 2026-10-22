package migrations

import (
	"os"
	"strconv"
	"strings"
	"testing"
)

// Latest must be the highest-numbered migration in this directory, or the
// startup check compares against the wrong version.
func TestLatestIsTheHighestMigrationOnDisk(t *testing.T) {
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	var want uint
	for _, e := range entries {
		if !strings.HasSuffix(e.Name(), ".up.sql") {
			continue
		}
		prefix, _, _ := strings.Cut(e.Name(), "_")
		n, err := strconv.ParseUint(prefix, 10, 32)
		if err != nil {
			t.Fatalf("%s: not a numbered migration", e.Name())
		}
		if uint(n) > want {
			want = uint(n)
		}
	}
	if got := Latest(); got != want || got == 0 {
		t.Errorf("Latest() = %d, want %d", got, want)
	}
}
