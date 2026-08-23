package store

import (
	"testing"
)

// TestReconcileOrphanedRunsMovesRunningRunToInterrupted is the primary scenario
// from the spec: a run left running by a crash is reconciled to interrupted.
func TestReconcileOrphanedRunsMovesRunningRunToInterrupted(t *testing.T) {
	st, _ := openTestStore(t)

	if err := st.CreateRun(&RunRecord{
		ID: "orphan-1", Project: "p", TaskID: "orphan-1", Status: "running",
	}); err != nil {
		t.Fatal(err)
	}

	result, err := st.ReconcileOrphanedRuns()
	if err != nil {
		t.Fatalf("ReconcileOrphanedRuns: %v", err)
	}

	if result.RunsReconciled != 1 {
		t.Errorf("RunsReconciled = %d, want 1", result.RunsReconciled)
	}

	run, err := st.GetRun("orphan-1")
	if err != nil {
		t.Fatal(err)
	}
	if run.Status != "interrupted" {
		t.Errorf("run status = %q, want interrupted", run.Status)
	}
}

// TestReconcileOrphanedRunsLeavesTerminalRunsUntouched: passed, failed,
// cancelled, timed_out, and interrupted runs must not be touched.
func TestReconcileOrphanedRunsLeavesTerminalRunsUntouched(t *testing.T) {
	st, _ := openTestStore(t)

	terminals := []string{"passed", "failed", "cancelled", "timed_out", "interrupted"}
	for _, status := range terminals {
		if err := st.CreateRun(&RunRecord{
			ID: "run-" + status, Project: "p", TaskID: "run-" + status, Status: status,
		}); err != nil {
			t.Fatalf("creating %s run: %v", status, err)
		}
	}

	result, err := st.ReconcileOrphanedRuns()
	if err != nil {
		t.Fatalf("ReconcileOrphanedRuns: %v", err)
	}

	if result.RunsReconciled != 0 {
		t.Errorf("RunsReconciled = %d, want 0; terminal runs must not be touched", result.RunsReconciled)
	}

	for _, status := range terminals {
		run, err := st.GetRun("run-" + status)
		if err != nil {
			t.Fatal(err)
		}
		if run.Status != status {
			t.Errorf("run-%s status = %q, want %q (terminal runs must not be touched)", status, run.Status, status)
		}
	}
}

// TestReconcileOrphanedRunsReconcilesPhasesAlongsideTheirRun: a phase stuck at
// running must be reconciled with its run. Resume skips only passed phases; a
// running phase is neither passed nor re-run and silently drops work.
func TestReconcileOrphanedRunsReconcilesPhasesAlongsideTheirRun(t *testing.T) {
	st, _ := openTestStore(t)

	if err := st.CreateRun(&RunRecord{
		ID: "orphan-2", Project: "p", TaskID: "orphan-2", Status: "running",
	}); err != nil {
		t.Fatal(err)
	}
	// A phase left running by the crash.
	if err := st.RecordPhase(&PhaseRecord{
		ID: "phase-running", RunID: "orphan-2", Repo: "api",
		Name: "build", Kind: "agent", Status: "running",
	}); err != nil {
		t.Fatal(err)
	}
	// A passed phase must not be changed — resume will skip it.
	if err := st.RecordPhase(&PhaseRecord{
		ID: "phase-passed", RunID: "orphan-2", Repo: "api",
		Name: "test", Kind: "code", Status: "passed",
	}); err != nil {
		t.Fatal(err)
	}

	result, err := st.ReconcileOrphanedRuns()
	if err != nil {
		t.Fatalf("ReconcileOrphanedRuns: %v", err)
	}

	if result.PhasesReconciled != 1 {
		t.Errorf("PhasesReconciled = %d, want 1", result.PhasesReconciled)
	}

	phases, err := st.ListPhasesForRun("orphan-2")
	if err != nil {
		t.Fatal(err)
	}
	statusByID := map[string]string{}
	for _, p := range phases {
		statusByID[p.ID] = p.Status
	}
	if got := statusByID["phase-running"]; got != "interrupted" {
		t.Errorf("phase-running status = %q, want interrupted", got)
	}
	if got := statusByID["phase-passed"]; got != "passed" {
		t.Errorf("phase-passed status = %q, want passed (must not be changed)", got)
	}
}

// TestReconcileOrphanedRunsAppendsToChangeSequenceWhenNonZero: reconciliation
// must be visible in the change sequence so an operator can see it.
func TestReconcileOrphanedRunsAppendsToChangeSequenceWhenNonZero(t *testing.T) {
	st, _ := openTestStore(t)

	if err := st.CreateRun(&RunRecord{
		ID: "orphan-3", Project: "p", TaskID: "orphan-3", Status: "running",
	}); err != nil {
		t.Fatal(err)
	}

	seqBefore, err := st.CurrentSequence()
	if err != nil {
		t.Fatal(err)
	}

	if _, err := st.ReconcileOrphanedRuns(); err != nil {
		t.Fatalf("ReconcileOrphanedRuns: %v", err)
	}

	seqAfter, err := st.CurrentSequence()
	if err != nil {
		t.Fatal(err)
	}
	if seqAfter <= seqBefore {
		t.Errorf("sequence did not advance after reconciliation (was %d, still %d); transitions must be recorded",
			seqBefore, seqAfter)
	}
}

// TestReconcileOrphanedRunsIsQuietWhenNothingReconciled: no change is appended
// and RunsReconciled is zero when there is nothing to do.
// A permanent "0 runs recovered" line at every start trains operators to stop reading.
func TestReconcileOrphanedRunsIsQuietWhenNothingReconciled(t *testing.T) {
	st, _ := openTestStore(t)

	// Only a terminal run — nothing to reconcile.
	if err := st.CreateRun(&RunRecord{
		ID: "done", Project: "p", TaskID: "done", Status: "passed",
	}); err != nil {
		t.Fatal(err)
	}

	seqBefore, err := st.CurrentSequence()
	if err != nil {
		t.Fatal(err)
	}

	result, err := st.ReconcileOrphanedRuns()
	if err != nil {
		t.Fatalf("ReconcileOrphanedRuns: %v", err)
	}

	if result.RunsReconciled != 0 {
		t.Errorf("RunsReconciled = %d, want 0", result.RunsReconciled)
	}

	seqAfter, err := st.CurrentSequence()
	if err != nil {
		t.Fatal(err)
	}
	if seqAfter != seqBefore {
		t.Errorf("sequence advanced by %d when nothing was reconciled; no change must be appended when there is nothing to report",
			seqAfter-seqBefore)
	}
}

// TestInterruptedIsInResumableRunStatuses: an interrupted run must be resumable
// so the normal recovery path applies without operator archaeology.
func TestInterruptedIsInResumableRunStatuses(t *testing.T) {
	for _, s := range ResumableRunStatuses() {
		if s == "interrupted" {
			return
		}
	}
	t.Error("interrupted is not in ResumableRunStatuses(); it must be resumable so an orphaned run can be recovered")
}

// TestInterruptedIsAbsentFromBulletProgression: an interruption is the absence
// of progress, not a stage of it.
func TestInterruptedIsAbsentFromBulletProgression(t *testing.T) {
	for _, s := range BulletProgression() {
		if s == "interrupted" {
			t.Error("interrupted must not appear in BulletProgression(); it is not a step toward delivery")
			return
		}
	}
}

// TestInterruptedIsTerminal: resume writes "running" and then drives the run.
// If interrupted is not terminal, waiters block forever on an orphaned run.
func TestInterruptedIsTerminal(t *testing.T) {
	if !IsTerminalRunStatus("interrupted") {
		t.Error("interrupted must be a terminal run status so waiters and slug assignment treat it as finished")
	}
}

// TestReconcileOrphanedRunsMultipleRuns: every running run is reconciled, not
// just the first one found.
func TestReconcileOrphanedRunsMultipleRuns(t *testing.T) {
	st, _ := openTestStore(t)

	for _, id := range []string{"orphan-a", "orphan-b", "orphan-c"} {
		if err := st.CreateRun(&RunRecord{
			ID: id, Project: "p", TaskID: id, Status: "running",
		}); err != nil {
			t.Fatalf("creating %s: %v", id, err)
		}
	}
	// A finished run that must not be touched.
	if err := st.CreateRun(&RunRecord{
		ID: "done-x", Project: "p", TaskID: "done-x", Status: "passed",
	}); err != nil {
		t.Fatal(err)
	}

	result, err := st.ReconcileOrphanedRuns()
	if err != nil {
		t.Fatalf("ReconcileOrphanedRuns: %v", err)
	}

	if result.RunsReconciled != 3 {
		t.Errorf("RunsReconciled = %d, want 3", result.RunsReconciled)
	}

	for _, id := range []string{"orphan-a", "orphan-b", "orphan-c"} {
		run, err := st.GetRun(id)
		if err != nil {
			t.Fatal(err)
		}
		if run.Status != "interrupted" {
			t.Errorf("%s status = %q, want interrupted", id, run.Status)
		}
	}

	doneRun, err := st.GetRun("done-x")
	if err != nil {
		t.Fatal(err)
	}
	if doneRun.Status != "passed" {
		t.Errorf("done-x status = %q, want passed (must not be touched)", doneRun.Status)
	}
}

// TestReconcileOrphanedRunsOnlyReconcilesPhasesOfRunningRuns: phases belonging
// to a terminal run must not be touched, even if they somehow still read running.
func TestReconcileOrphanedRunsOnlyReconcilesPhasesOfRunningRuns(t *testing.T) {
	st, _ := openTestStore(t)

	// A passed run with an anomalous running phase — must not be touched.
	if err := st.CreateRun(&RunRecord{
		ID: "done-run", Project: "p", TaskID: "done-run", Status: "passed",
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.RecordPhase(&PhaseRecord{
		ID: "stale-phase", RunID: "done-run", Repo: "api",
		Name: "build", Kind: "agent", Status: "running",
	}); err != nil {
		t.Fatal(err)
	}

	result, err := st.ReconcileOrphanedRuns()
	if err != nil {
		t.Fatalf("ReconcileOrphanedRuns: %v", err)
	}

	if result.RunsReconciled != 0 {
		t.Errorf("RunsReconciled = %d, want 0", result.RunsReconciled)
	}
	if result.PhasesReconciled != 0 {
		t.Errorf("PhasesReconciled = %d, want 0; phases of terminal runs must not be touched", result.PhasesReconciled)
	}
}
