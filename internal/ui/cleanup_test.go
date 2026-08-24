package ui

import (
	"database/sql"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/callmeradical/sergeant/internal/store"

	_ "modernc.org/sqlite"
)

// cleanupFixture opens a store and points SERGEANT_FLEET_DIR at a fresh temp
// directory, so a test can build fake fleet worktrees without ever touching
// the real fleet root.
func cleanupFixture(t *testing.T) (srv *Server, st *store.Store, fleetRoot, dbPath string) {
	t.Helper()
	base := t.TempDir()
	fleetRoot = filepath.Join(base, "fleet")
	t.Setenv("SERGEANT_FLEET_DIR", fleetRoot)

	dbPath = filepath.Join(base, "t.db")
	var err error
	st, err = store.Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	return NewServer(st, 0), st, fleetRoot, dbPath
}

// backdateRun sets a run's updated_at directly, the way countRows reaches
// into the database directly elsewhere in this package: through a separate
// raw connection to the same file, since the store's public API only ever
// bumps updated_at to now.
func backdateRun(t *testing.T, dbPath, runID string, when time.Time) {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(`UPDATE runs SET updated_at = ? WHERE id = ?`, when, runID); err != nil {
		t.Fatalf("backdating run %q: %v", runID, err)
	}
}

// initDirtyGitRepo creates a real git repository at dir with one untracked
// file, so dirtyWorktreesUnder's `git status --porcelain` check reports it as
// dirty — the same signal a real agent worktree with unreviewed output would
// produce.
func initDirtyGitRepo(t *testing.T, dir string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	run := func(args ...string) {
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	run("init")
	run("config", "user.email", "test@example.com")
	run("config", "user.name", "Test")
	if err := os.WriteFile(filepath.Join(dir, "untracked.txt"), []byte("wip"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func mustExist(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Stat(path); err != nil {
		t.Errorf("expected %s to exist: %v", path, err)
	}
}

func mustNotExist(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Errorf("expected %s to be gone, stat err = %v", path, err)
	}
}

// An old terminal run's fleet worktree is removed by the automatic pass
// without any API call — reclaimEligibleFleetDirs is called directly, never
// through the /api/clean-worktrees handler, to prove the automatic path
// itself works.
func TestReclaimEligibleFleetDirsRemovesOldTerminalRunWorktree(t *testing.T) {
	srv, st, fleetRoot, dbPath := cleanupFixture(t)

	if err := st.CreateRun(&store.RunRecord{ID: "old-passed", Project: "p", TaskID: "old-passed", Status: "passed"}); err != nil {
		t.Fatal(err)
	}
	backdateRun(t, dbPath, "old-passed", time.Now().UTC().Add(-8*24*time.Hour))

	fleetDir := filepath.Join(fleetRoot, "old-passed")
	if err := os.MkdirAll(fleetDir, 0o755); err != nil {
		t.Fatal(err)
	}

	srv.reclaimEligibleFleetDirs()

	mustNotExist(t, fleetDir)
}

// A run that only recently went terminal has not sat idle long enough to be
// reclaimed yet.
func TestReclaimEligibleFleetDirsLeavesRecentlyTerminalRunWorktree(t *testing.T) {
	srv, st, fleetRoot, _ := cleanupFixture(t)

	if err := st.CreateRun(&store.RunRecord{ID: "recent-passed", Project: "p", TaskID: "recent-passed", Status: "passed"}); err != nil {
		t.Fatal(err)
	}
	// No backdating: CreateRun already stamped updated_at to now.

	fleetDir := filepath.Join(fleetRoot, "recent-passed")
	if err := os.MkdirAll(fleetDir, 0o755); err != nil {
		t.Fatal(err)
	}

	srv.reclaimEligibleFleetDirs()

	mustExist(t, fleetDir)
}

// A running run's worktree is never touched by the automatic pass, no matter
// how old it is — the fixture deliberately gives it an old updated_at to
// prove age alone cannot make a running run eligible.
func TestReclaimEligibleFleetDirsNeverTouchesARunningRun(t *testing.T) {
	srv, st, fleetRoot, dbPath := cleanupFixture(t)

	if err := st.CreateRun(&store.RunRecord{ID: "old-running", Project: "p", TaskID: "old-running", Status: "running"}); err != nil {
		t.Fatal(err)
	}
	backdateRun(t, dbPath, "old-running", time.Now().UTC().Add(-30*24*time.Hour))

	fleetDir := filepath.Join(fleetRoot, "old-running")
	if err := os.MkdirAll(fleetDir, 0o755); err != nil {
		t.Fatal(err)
	}

	srv.reclaimEligibleFleetDirs()

	mustExist(t, fleetDir)
}

// A worktree with uncommitted changes survives the automatic pass even when
// its run is old and terminal — automatic cleanup applies the same
// uncommitted-changes guard the on-demand handler enforces, never a relaxed
// version of it.
func TestReclaimEligibleFleetDirsLeavesADirtyWorktree(t *testing.T) {
	srv, st, fleetRoot, dbPath := cleanupFixture(t)

	if err := st.CreateRun(&store.RunRecord{ID: "old-dirty", Project: "p", TaskID: "old-dirty", Status: "passed"}); err != nil {
		t.Fatal(err)
	}
	backdateRun(t, dbPath, "old-dirty", time.Now().UTC().Add(-30*24*time.Hour))

	fleetDir := filepath.Join(fleetRoot, "old-dirty")
	repoWT := filepath.Join(fleetDir, "svc")
	initDirtyGitRepo(t, repoWT)

	srv.reclaimEligibleFleetDirs()

	mustExist(t, fleetDir)
	mustExist(t, repoWT)
}

// Reclaiming a fleet worktree must never delete or modify the run's database
// row or its phases and envelopes — only the on-disk directory is touched.
func TestReclaimEligibleFleetDirsLeavesDatabaseRecordsUntouched(t *testing.T) {
	srv, st, fleetRoot, dbPath := cleanupFixture(t)

	const runID = "old-with-history"
	if err := st.CreateRun(&store.RunRecord{ID: runID, Project: "p", TaskID: runID, Status: "passed"}); err != nil {
		t.Fatal(err)
	}
	if err := st.RecordPhase(&store.PhaseRecord{
		ID: "phase-1", RunID: runID, Repo: "svc", Name: "build", Kind: "agent", Status: "passed", DurationMs: 42,
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.RecordEnvelope(&store.EnvelopeRecord{
		ID: "env-1", RunID: runID, Repo: "svc", Stage: "build", Summary: "built it",
		Data: json.RawMessage(`{}`), Type: "phase.completed", SchemaVersion: "1",
		OccurredAt: time.Now().UTC(), Producer: "sergeant/test", CorrelationID: runID,
	}); err != nil {
		t.Fatal(err)
	}
	backdateRun(t, dbPath, runID, time.Now().UTC().Add(-30*24*time.Hour))

	beforeRun, err := st.GetRun(runID)
	if err != nil {
		t.Fatal(err)
	}
	beforePhases, err := st.ListPhasesForRun(runID)
	if err != nil {
		t.Fatal(err)
	}
	beforeEnvelopes, err := st.ListEnvelopesForRun(runID)
	if err != nil {
		t.Fatal(err)
	}

	fleetDir := filepath.Join(fleetRoot, runID)
	if err := os.MkdirAll(fleetDir, 0o755); err != nil {
		t.Fatal(err)
	}

	srv.reclaimEligibleFleetDirs()

	mustNotExist(t, fleetDir)

	afterRun, err := st.GetRun(runID)
	if err != nil {
		t.Fatalf("run vanished after reclaim: %v", err)
	}
	if afterRun.Status != beforeRun.Status || !afterRun.UpdatedAt.Equal(beforeRun.UpdatedAt) {
		t.Errorf("run record changed: before=%+v after=%+v", beforeRun, afterRun)
	}

	afterPhases, err := st.ListPhasesForRun(runID)
	if err != nil {
		t.Fatal(err)
	}
	if len(afterPhases) != len(beforePhases) {
		t.Fatalf("phase count changed: before=%d after=%d", len(beforePhases), len(afterPhases))
	}
	for i := range beforePhases {
		if afterPhases[i].Status != beforePhases[i].Status || afterPhases[i].ID != beforePhases[i].ID {
			t.Errorf("phase %d changed: before=%+v after=%+v", i, beforePhases[i], afterPhases[i])
		}
	}

	afterEnvelopes, err := st.ListEnvelopesForRun(runID)
	if err != nil {
		t.Fatal(err)
	}
	if len(afterEnvelopes) != len(beforeEnvelopes) {
		t.Fatalf("envelope count changed: before=%d after=%d", len(beforeEnvelopes), len(afterEnvelopes))
	}
	for i := range beforeEnvelopes {
		if afterEnvelopes[i].ID != beforeEnvelopes[i].ID || afterEnvelopes[i].Summary != beforeEnvelopes[i].Summary {
			t.Errorf("envelope %d changed: before=%+v after=%+v", i, beforeEnvelopes[i], afterEnvelopes[i])
		}
	}
}
