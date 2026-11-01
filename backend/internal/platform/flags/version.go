package flags

import (
	"strconv"
	"strings"
)

// CompareVersions compares two dotted numeric versions ("1.4", "1.4.0",
// "2.0.1+7"): -1, 0 or 1. A build suffix after '+' or a pre-release after
// '-' is ignored, and missing segments count as 0, so "1.4" == "1.4.0".
//
// An unreadable version compares as the oldest possible one. Every caller
// uses this to ask "is this client new enough?", and the safe answer for a
// version nobody can read is no.
func CompareVersions(a, b string) int {
	va, okA := parseVersion(a)
	vb, okB := parseVersion(b)
	switch {
	case !okA && !okB:
		return 0
	case !okA:
		return -1
	case !okB:
		return 1
	}
	for i := 0; i < 3; i++ {
		if va[i] != vb[i] {
			if va[i] < vb[i] {
				return -1
			}
			return 1
		}
	}
	return 0
}

// AtLeast reports whether version is min or newer. An empty or unreadable
// version is never at least anything.
func AtLeast(version, min string) bool {
	if _, ok := parseVersion(version); !ok {
		return false
	}
	return CompareVersions(version, min) >= 0
}

func parseVersion(v string) ([3]int, bool) {
	var out [3]int
	v = strings.TrimSpace(strings.TrimPrefix(v, "v"))
	if i := strings.IndexAny(v, "+-"); i >= 0 {
		v = v[:i]
	}
	if v == "" {
		return out, false
	}
	parts := strings.Split(v, ".")
	if len(parts) > 3 {
		return out, false
	}
	for i, p := range parts {
		n, err := strconv.Atoi(p)
		if err != nil || n < 0 || n > 1_000_000 {
			return out, false
		}
		out[i] = n
	}
	return out, true
}
