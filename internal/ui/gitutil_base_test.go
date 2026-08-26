package ui

import (
	"path/filepath"
	"testing"
)

// Scenario: "defaultBase returns the recorded value immediately when one is
// present, without shelling out to git at all" (tasks.md, Task 2). Proven
// against a directory that is not even a git repo: if defaultBase tried its
// old fallback chain against it, every candidate would fail and it would
// fall all the way through to the literal "HEAD" — so getting the recorded
// value back instead proves the fallback chain never ran.
func TestDefaultBaseShortCircuitsOnARecordedValue(t *testing.T) {
	notAGitRepo := filepath.Join(t.TempDir(), "does-not-exist")
	got := defaultBase(notAGitRepo, "develop")
	if got != "develop" {
		t.Errorf("defaultBase(%q, %q) = %q, want %q — a recorded value must short-circuit every guess", notAGitRepo, "develop", got, "develop")
	}
}

// Scenario: "A run with no recorded BaseBranch (predates this change) still
// gets an answer from defaultBase's existing fallback chain, unchanged."
func TestDefaultBaseFallsBackToItsGuessChainWhenNothingIsRecorded(t *testing.T) {
	dir := t.TempDir()
	initGitRepo(t, dir)

	got := defaultBase(dir, "")
	if got != "main" {
		t.Errorf(`defaultBase(dir, "") = %q, want %q from the existing main/master fallback chain`, got, "main")
	}
}
