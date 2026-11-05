package main

import (
	"errors"
	"testing"
)

func TestCheck(t *testing.T) {
	if err := check("v1", "terms", "privacy", false); err != nil {
		t.Errorf("finished text: %v", err)
	}
	if err := check("", "terms", "privacy", false); err == nil {
		t.Error("no version was accepted")
	}
	if err := check("v1", " ", "privacy", false); err == nil {
		t.Error("empty terms were accepted")
	}
	if err := check("v1", "a [FILL IN] gap", "privacy", false); !errors.Is(err, errUnfinished) {
		t.Errorf("a gap in the terms: %v", err)
	}
	if err := check("v1", "terms", "[FILL IN — x]", false); !errors.Is(err, errUnfinished) {
		t.Errorf("a gap in the policy: %v", err)
	}
	if err := check("v1", "a [FILL IN] gap", "privacy", true); err != nil {
		t.Errorf("a local draft: %v", err)
	}
}
