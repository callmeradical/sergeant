package store

import "testing"

// SetRunBaseBranch is the write path dag.Engine.prepareWorktree uses to
// durably record the branch a run's worktree actually branched from. This
// proves the store-layer mechanics: written once, read back via GetRun and
// every other run listing (runColumns/scanRun agreeing).
func TestSetRunBaseBranchIsReadableFromGetRun(t *testing.T) {
	st, _ := openTestStore(t)

	if err := st.CreateRun(&RunRecord{
		ID: "run-bb-1", Project: "p", TaskID: "run-bb-1", Status: "running",
	}); err != nil {
		t.Fatal(err)
	}

	got, err := st.GetRun("run-bb-1")
	if err != nil {
		t.Fatal(err)
	}
	if got.BaseBranch != "" {
		t.Errorf("BaseBranch = %q before SetRunBaseBranch, want empty", got.BaseBranch)
	}

	if err := st.SetRunBaseBranch("run-bb-1", "develop"); err != nil {
		t.Fatalf("SetRunBaseBranch: %v", err)
	}

	got, err = st.GetRun("run-bb-1")
	if err != nil {
		t.Fatal(err)
	}
	if got.BaseBranch != "develop" {
		t.Errorf("GetRun.BaseBranch = %q, want %q", got.BaseBranch, "develop")
	}

	listed, err := st.ListRunsForProject("p", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(listed) != 1 || listed[0].BaseBranch != "develop" {
		t.Errorf("ListRunsForProject = %+v, want one run with BaseBranch=develop", listed)
	}
}

// SetRunBaseBranch reports an error for an id that names no run, the same
// convention every other bullet/run setter (UpdateBulletStatus,
// UpdateIntentStatus) already follows — a silent no-op would let a caller
// believe it had recorded a base branch that was never written.
func TestSetRunBaseBranchOnUnknownRunIsAnError(t *testing.T) {
	st, _ := openTestStore(t)
	if err := st.SetRunBaseBranch("no-such-run", "main"); err == nil {
		t.Error("SetRunBaseBranch on an unknown run id = nil error, want an error")
	}
}
