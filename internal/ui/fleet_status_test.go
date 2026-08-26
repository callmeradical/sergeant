package ui

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/callmeradical/sergeant/internal/store"
)

// initCleanGitRepoOnBranch creates a real git repository at dir, checked out
// on branch, with no uncommitted changes — the counterpart to
// initDirtyGitRepo (cleanup_test.go), used here to prove a lease reports the
// real branch name and a clean dirty=false, not just a dirty=true signal.
func initCleanGitRepoOnBranch(t *testing.T, dir, branch string) {
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
	run("init", "-b", branch)
	run("config", "user.email", "test@example.com")
	run("config", "user.name", "Test")
	if err := os.WriteFile(filepath.Join(dir, "README.md"), []byte("hi"), 0o644); err != nil {
		t.Fatal(err)
	}
	run("add", ".")
	run("commit", "-m", "initial")
}

func fetchFleetLeases(t *testing.T, srv *Server) []WorktreeLease {
	t.Helper()
	var body struct {
		Leases []WorktreeLease `json:"leases"`
	}
	getJSON(t, srv.Handler(), "GET", "/api/fleet", nil, &body)
	return body.Leases
}

func leaseFor(leases []WorktreeLease, taskID, repo string) (WorktreeLease, bool) {
	for _, l := range leases {
		if l.TaskID == taskID && l.Repo == repo {
			return l, true
		}
	}
	return WorktreeLease{}, false
}

// TestFleetLeaseReportsRealBranchAndCleanState covers the "what state is
// this worktree in" half of the fleet drawer's job: a lease's Branch/Dirty
// fields must reflect the worktree's actual git state, not be left empty.
func TestFleetLeaseReportsRealBranchAndCleanState(t *testing.T) {
	srv, _, fleetRoot, _ := cleanupFixture(t)
	initCleanGitRepoOnBranch(t, filepath.Join(fleetRoot, "run-clean", "svc"), "feat/widget")

	leases := fetchFleetLeases(t, srv)
	lease, ok := leaseFor(leases, "run-clean", "svc")
	if !ok {
		t.Fatalf("no lease for run-clean/svc: %+v", leases)
	}
	if lease.Branch != "feat/widget" {
		t.Errorf("Branch = %q, want %q", lease.Branch, "feat/widget")
	}
	if lease.Dirty {
		t.Errorf("Dirty = true for a freshly committed worktree, want false")
	}
}

// TestFleetLeaseReportsDirtyState is the mirror scenario: an actually dirty
// worktree must be reported as such.
func TestFleetLeaseReportsDirtyState(t *testing.T) {
	srv, _, fleetRoot, _ := cleanupFixture(t)
	initDirtyGitRepo(t, filepath.Join(fleetRoot, "run-dirty", "svc"))

	leases := fetchFleetLeases(t, srv)
	lease, ok := leaseFor(leases, "run-dirty", "svc")
	if !ok {
		t.Fatalf("no lease for run-dirty/svc: %+v", leases)
	}
	if !lease.Dirty {
		t.Errorf("Dirty = false for a worktree with an untracked file, want true")
	}
}

// TestFleetListsOneLeasePerRepoInAMultiRepoRun covers the other half of the
// gap: a multi-repo run's fleet directory holds one worktree per repo, and
// the drawer must list each one, not collapse them into a single entry for
// the run.
func TestFleetListsOneLeasePerRepoInAMultiRepoRun(t *testing.T) {
	srv, _, fleetRoot, _ := cleanupFixture(t)
	initCleanGitRepoOnBranch(t, filepath.Join(fleetRoot, "run-multi", "api"), "feat/x")
	initCleanGitRepoOnBranch(t, filepath.Join(fleetRoot, "run-multi", "web"), "feat/x")

	leases := fetchFleetLeases(t, srv)
	if _, ok := leaseFor(leases, "run-multi", "api"); !ok {
		t.Errorf("missing lease for run-multi/api: %+v", leases)
	}
	if _, ok := leaseFor(leases, "run-multi", "web"); !ok {
		t.Errorf("missing lease for run-multi/web: %+v", leases)
	}
}

// TestFleetLeaseReportsItsBulletStatus covers "what is using this worktree":
// a lease for a repo with a recorded bullet reports that bullet's real
// status, not just the coarse run-level status every repo of the run shares.
func TestFleetLeaseReportsItsBulletStatus(t *testing.T) {
	srv, st, fleetRoot, _ := cleanupFixture(t)

	const runID = "run-with-bullet"
	intentID := runID + "-intent"
	if err := st.CreateIntent(&store.IntentRecord{ID: intentID, Project: "p", Statement: "s", Status: "in_progress"}); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateRun(&store.RunRecord{ID: runID, Project: "p", TaskID: runID, Status: "running", IntentID: intentID}); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateBullet(&store.BulletRecord{ID: runID + "-b1", IntentID: intentID, Repo: "svc", Position: 1, Status: "green"}); err != nil {
		t.Fatal(err)
	}
	initCleanGitRepoOnBranch(t, filepath.Join(fleetRoot, runID, "svc"), "feat/x")

	leases := fetchFleetLeases(t, srv)
	lease, ok := leaseFor(leases, runID, "svc")
	if !ok {
		t.Fatalf("no lease for %s/svc: %+v", runID, leases)
	}
	if lease.BulletStatus != "green" {
		t.Errorf("BulletStatus = %q, want %q", lease.BulletStatus, "green")
	}
	if lease.Status != "running" {
		t.Errorf("Status = %q, want the run's own status %q", lease.Status, "running")
	}
}
