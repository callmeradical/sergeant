package store

import (
	"testing"
	"time"
)

// backdateRun sets a run's updated_at directly, bypassing every write path
// that would otherwise bump it to now. Fixtures for the retention window need
// a run that has genuinely sat idle, which no public Store method can produce.
func backdateRun(t *testing.T, st *Store, runID string, when time.Time) {
	t.Helper()
	if _, err := st.db.Exec(`UPDATE runs SET updated_at = ? WHERE id = ?`, when, runID); err != nil {
		t.Fatalf("backdating run %q: %v", runID, err)
	}
}

// An old terminal run is exactly what automatic cleanup exists to find.
func TestRunsEligibleForCleanupFindsOldTerminalRuns(t *testing.T) {
	st, _ := openTestStore(t)

	if err := st.CreateRun(&RunRecord{ID: "old-passed", Project: "p", TaskID: "old-passed", Status: "passed"}); err != nil {
		t.Fatal(err)
	}
	old := time.Now().UTC().Add(-8 * 24 * time.Hour)
	backdateRun(t, st, "old-passed", old)

	cutoff := time.Now().UTC().Add(-7 * 24 * time.Hour)
	eligible, err := st.RunsEligibleForCleanup(cutoff)
	if err != nil {
		t.Fatalf("RunsEligibleForCleanup: %v", err)
	}
	if len(eligible) != 1 || eligible[0].ID != "old-passed" {
		t.Errorf("eligible = %+v, want [old-passed]", eligible)
	}
}

// A recently-terminal run has not sat idle long enough yet.
func TestRunsEligibleForCleanupExcludesRecentlyTerminalRuns(t *testing.T) {
	st, _ := openTestStore(t)

	if err := st.CreateRun(&RunRecord{ID: "recent-passed", Project: "p", TaskID: "recent-passed", Status: "passed"}); err != nil {
		t.Fatal(err)
	}
	// CreateRun already stamped updated_at to "now", which is within any
	// sensible retention window — no backdating needed.

	cutoff := time.Now().UTC().Add(-7 * 24 * time.Hour)
	eligible, err := st.RunsEligibleForCleanup(cutoff)
	if err != nil {
		t.Fatalf("RunsEligibleForCleanup: %v", err)
	}
	if len(eligible) != 0 {
		t.Errorf("eligible = %+v, want none", eligible)
	}
}

// A running run is never eligible, no matter how old — the query itself must
// enforce this, not merely a caller convention.
func TestRunsEligibleForCleanupExcludesRunningRunsRegardlessOfAge(t *testing.T) {
	st, _ := openTestStore(t)

	if err := st.CreateRun(&RunRecord{ID: "old-running", Project: "p", TaskID: "old-running", Status: "running"}); err != nil {
		t.Fatal(err)
	}
	backdateRun(t, st, "old-running", time.Now().UTC().Add(-30*24*time.Hour))

	cutoff := time.Now().UTC().Add(-7 * 24 * time.Hour)
	eligible, err := st.RunsEligibleForCleanup(cutoff)
	if err != nil {
		t.Fatalf("RunsEligibleForCleanup: %v", err)
	}
	if len(eligible) != 0 {
		t.Errorf("eligible = %+v, want none — a running run must never be eligible", eligible)
	}
}

// Every terminal status the spec names must be found, not just "passed".
func TestRunsEligibleForCleanupCoversEveryTerminalStatus(t *testing.T) {
	st, _ := openTestStore(t)

	statuses := []string{"passed", "failed", "cancelled", "interrupted"}
	old := time.Now().UTC().Add(-30 * 24 * time.Hour)
	for _, status := range statuses {
		id := "old-" + status
		if err := st.CreateRun(&RunRecord{ID: id, Project: "p", TaskID: id, Status: status}); err != nil {
			t.Fatalf("creating %s run: %v", status, err)
		}
		backdateRun(t, st, id, old)
	}

	cutoff := time.Now().UTC().Add(-7 * 24 * time.Hour)
	eligible, err := st.RunsEligibleForCleanup(cutoff)
	if err != nil {
		t.Fatalf("RunsEligibleForCleanup: %v", err)
	}
	if len(eligible) != len(statuses) {
		t.Fatalf("got %d eligible runs, want %d: %+v", len(eligible), len(statuses), eligible)
	}
	seen := map[string]bool{}
	for _, r := range eligible {
		seen[r.Status] = true
	}
	for _, status := range statuses {
		if !seen[status] {
			t.Errorf("status %q not found eligible", status)
		}
	}
}
