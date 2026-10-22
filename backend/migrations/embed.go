// Package migrations embeds this directory's migration files, so a binary
// knows which schema version it was built for (#95).
package migrations

import (
	"embed"
	"strconv"
	"strings"
)

//go:embed *.up.sql
var files embed.FS

// Latest is the highest migration number in this build: the schema version
// the code expects to find.
func Latest() uint {
	entries, err := files.ReadDir(".")
	if err != nil {
		// Embedded at compile time; unreadable means a broken build.
		panic("migrations: read embedded files: " + err.Error())
	}
	var latest uint
	for _, e := range entries {
		prefix, _, ok := strings.Cut(e.Name(), "_")
		if !ok {
			continue
		}
		n, err := strconv.ParseUint(prefix, 10, 32)
		if err != nil {
			continue
		}
		if uint(n) > latest {
			latest = uint(n)
		}
	}
	return latest
}
