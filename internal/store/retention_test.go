package store

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// backdateRunCreatedAt sets a run's created_at directly, bypassing every
// write path that would otherwise stamp it to now. RotateProject's
// eligibility rule is keyed on created_at (design.md), not updated_at, so
// fixtures for it need this rather than cleanup_test.go's backdateRun.
func backdateRunCreatedAt(t *testing.T, st *Store, runID string, when time.Time) {
	t.Helper()
	if _, err := st.db.Exec(`UPDATE runs SET created_at = ? WHERE id = ?`, when, runID); err != nil {
		t.Fatalf("backdating run %q created_at: %v", runID, err)
	}
}

// --- Task 1: GetRetentionRollup -----------------------------------------

// A project with no rollup row yet reports "not found," not a zero-valued
// row indistinguishable from a project whose rotated history was genuinely
// all zeros.
func TestGetRetentionRollupNotFoundIsDistinguishable(t *testing.T) {
	st, _ := openTestStore(t)

	rollup, found, err := st.GetRetentionRollup("never-rotated")
	if err != nil {
		t.Fatalf("GetRetentionRollup: %v", err)
	}
	if found {
		t.Errorf("found = true, want false for a project with no rollup row")
	}
	if rollup != nil {
		t.Errorf("rollup = %+v, want nil", rollup)
	}
}

// --- Task 2: RotateProject ------------------------------------------------

// The baseline positive case every other RotateProject test is contrasted
// against: a terminal run older than cutoff, with no intent, rotates —
// its rollup counts increase and its run/phase rows are gone afterward.
func TestRotateProjectRotatesOldTerminalRunWithNoIntent(t *testing.T) {
	st, _ := openTestStore(t)

	const runID = "old-passed-no-intent"
	if err := st.CreateRun(&RunRecord{ID: runID, Project: "p", TaskID: runID, Status: "passed", Type: "feat"}); err != nil {
		t.Fatal(err)
	}
	if err := st.RecordPhase(&PhaseRecord{ID: "phase-1", RunID: runID, Repo: "svc", Name: "build", Kind: "agent", Status: "passed"}); err != nil {
		t.Fatal(err)
	}
	backdateRunCreatedAt(t, st, runID, time.Now().UTC().Add(-60*24*time.Hour))

	cutoff := time.Now().UTC().Add(-30 * 24 * time.Hour)
	rotated, err := st.RotateProject("p", cutoff)
	if err != nil {
		t.Fatalf("RotateProject: %v", err)
	}
	if rotated != 1 {
		t.Fatalf("rotated = %d, want 1", rotated)
	}

	if _, err := st.GetRun(runID); err == nil {
		t.Errorf("expected run %q to be gone after rotation", runID)
	}
	phases, err := st.ListPhasesForRun(runID)
	if err != nil {
		t.Fatal(err)
	}
	if len(phases) != 0 {
		t.Errorf("phases = %+v, want none after rotation", phases)
	}

	rollup, found, err := st.GetRetentionRollup("p")
	if err != nil {
		t.Fatalf("GetRetentionRollup: %v", err)
	}
	if !found {
		t.Fatal("expected a rollup row after rotation")
	}
	if rollup.RunCount != 1 || rollup.PassedCount != 1 {
		t.Errorf("rollup = %+v, want RunCount=1 PassedCount=1", rollup)
	}
}

// spec.md: "A non-terminal run is never rotated" — even past cutoff.
func TestRotateProjectNeverRotatesANonTerminalRun(t *testing.T) {
	st, _ := openTestStore(t)

	const runID = "old-running"
	if err := st.CreateRun(&RunRecord{ID: runID, Project: "p", TaskID: runID, Status: "running"}); err != nil {
		t.Fatal(err)
	}
	backdateRunCreatedAt(t, st, runID, time.Now().UTC().Add(-60*24*time.Hour))

	cutoff := time.Now().UTC().Add(-30 * 24 * time.Hour)
	rotated, err := st.RotateProject("p", cutoff)
	if err != nil {
		t.Fatalf("RotateProject: %v", err)
	}
	if rotated != 0 {
		t.Errorf("rotated = %d, want 0 for a non-terminal run", rotated)
	}
	if _, err := st.GetRun(runID); err != nil {
		t.Errorf("expected run %q to survive rotation, GetRun error: %v", runID, err)
	}

	if _, found, err := st.GetRetentionRollup("p"); err != nil {
		t.Fatal(err)
	} else if found {
		t.Errorf("expected no rollup row when nothing rotated")
	}
}

// spec.md: "A run with an unmerged bullet is never rotated" — even past
// cutoff. Evidence for an in-flight intent is never removed.
func TestRotateProjectNeverRotatesARunWithAnUnmergedBullet(t *testing.T) {
	st, _ := openTestStore(t)

	const intentID = "intent-unmerged"
	if err := st.CreateIntent(&IntentRecord{ID: intentID, Project: "p", Statement: "s", Status: "in_progress"}); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateBullet(&BulletRecord{ID: "bullet-1", IntentID: intentID, Repo: "svc", Position: 0, Status: "sealed"}); err != nil {
		t.Fatal(err)
	}

	const runID = "old-passed-unmerged-intent"
	if err := st.CreateRun(&RunRecord{ID: runID, Project: "p", TaskID: runID, Status: "passed", IntentID: intentID}); err != nil {
		t.Fatal(err)
	}
	backdateRunCreatedAt(t, st, runID, time.Now().UTC().Add(-60*24*time.Hour))

	cutoff := time.Now().UTC().Add(-30 * 24 * time.Hour)
	rotated, err := st.RotateProject("p", cutoff)
	if err != nil {
		t.Fatalf("RotateProject: %v", err)
	}
	if rotated != 0 {
		t.Errorf("rotated = %d, want 0 while the intent has an unmerged bullet", rotated)
	}
	if _, err := st.GetRun(runID); err != nil {
		t.Errorf("expected run %q to survive rotation, GetRun error: %v", runID, err)
	}
}

// A run whose intent's only bullet has reached merged IS eligible, once past
// cutoff — the positive counterpart to the unmerged-bullet refusal above,
// proving the merged check is not simply "always refuse when there's an
// intent."
func TestRotateProjectRotatesARunWhoseIntentIsFullyMerged(t *testing.T) {
	st, _ := openTestStore(t)

	const intentID = "intent-merged"
	if err := st.CreateIntent(&IntentRecord{ID: intentID, Project: "p", Statement: "s", Status: "satisfied"}); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateBullet(&BulletRecord{ID: "bullet-1", IntentID: intentID, Repo: "svc", Position: 0, Status: "merged"}); err != nil {
		t.Fatal(err)
	}

	const runID = "old-passed-merged-intent"
	if err := st.CreateRun(&RunRecord{ID: runID, Project: "p", TaskID: runID, Status: "passed", IntentID: intentID}); err != nil {
		t.Fatal(err)
	}
	backdateRunCreatedAt(t, st, runID, time.Now().UTC().Add(-60*24*time.Hour))

	cutoff := time.Now().UTC().Add(-30 * 24 * time.Hour)
	rotated, err := st.RotateProject("p", cutoff)
	if err != nil {
		t.Fatalf("RotateProject: %v", err)
	}
	if rotated != 1 {
		t.Errorf("rotated = %d, want 1 once the intent's only bullet is merged", rotated)
	}
	if _, err := st.GetRun(runID); err == nil {
		t.Errorf("expected run %q to be gone after rotation", runID)
	}

	// The intent and its bullet are evidence shared beyond this one run and
	// must survive rotation untouched.
	if _, err := st.GetIntent(intentID); err != nil {
		t.Errorf("expected intent %q to survive rotation, GetIntent error: %v", intentID, err)
	}
	bullets, err := st.ListBulletsForIntent(intentID)
	if err != nil {
		t.Fatal(err)
	}
	if len(bullets) != 1 || bullets[0].Status != "merged" {
		t.Errorf("bullets = %+v, want one merged bullet surviving rotation", bullets)
	}
}

// A terminal run younger than cutoff is left alone regardless of status —
// RotateProject's created_at filter, not merely its status filter, must gate
// eligibility.
func TestRotateProjectNeverRotatesARunYoungerThanCutoff(t *testing.T) {
	st, _ := openTestStore(t)

	const runID = "recent-passed"
	if err := st.CreateRun(&RunRecord{ID: runID, Project: "p", TaskID: runID, Status: "passed"}); err != nil {
		t.Fatal(err)
	}
	// CreateRun already stamped created_at to now — no backdating.

	cutoff := time.Now().UTC().Add(-30 * 24 * time.Hour)
	rotated, err := st.RotateProject("p", cutoff)
	if err != nil {
		t.Fatalf("RotateProject: %v", err)
	}
	if rotated != 0 {
		t.Errorf("rotated = %d, want 0 for a run younger than cutoff", rotated)
	}
}

// spec.md: "Aggregate totals are unchanged by rotation" — the project's
// aggregate run/outcome/work-type/provenance totals after rotation equal
// what they were immediately before.
func TestComputeWorkAnalyticsTotalsUnchangedByRotation(t *testing.T) {
	st, _ := openTestStore(t)

	// One run that will rotate, one that stays — so the invariant is proven
	// against a mixed-history project, not a trivial single-run one.
	const oldRunID = "old-passed"
	if err := st.CreateRun(&RunRecord{ID: oldRunID, Project: "p", TaskID: oldRunID, Status: "passed", Type: "feat"}); err != nil {
		t.Fatal(err)
	}
	if err := st.RecordPhase(&PhaseRecord{
		ID: "phase-old", RunID: oldRunID, Repo: "svc", Name: "build", Kind: "agent", Status: "passed",
		Payload: []byte(`{"agent":"goose","model":"claude-sonnet-4-6","provider":"anthropic"}`),
	}); err != nil {
		t.Fatal(err)
	}
	backdateRunCreatedAt(t, st, oldRunID, time.Now().UTC().Add(-60*24*time.Hour))

	const recentRunID = "recent-failed"
	if err := st.CreateRun(&RunRecord{ID: recentRunID, Project: "p", TaskID: recentRunID, Status: "failed", Type: "fix"}); err != nil {
		t.Fatal(err)
	}

	before, err := st.ComputeWorkAnalytics("p")
	if err != nil {
		t.Fatalf("ComputeWorkAnalytics before rotation: %v", err)
	}

	cutoff := time.Now().UTC().Add(-30 * 24 * time.Hour)
	rotated, err := st.RotateProject("p", cutoff)
	if err != nil {
		t.Fatalf("RotateProject: %v", err)
	}
	if rotated != 1 {
		t.Fatalf("rotated = %d, want 1", rotated)
	}

	after, err := st.ComputeWorkAnalytics("p")
	if err != nil {
		t.Fatalf("ComputeWorkAnalytics after rotation: %v", err)
	}

	if after.TotalRuns != before.TotalRuns {
		t.Errorf("TotalRuns changed: before=%d after=%d", before.TotalRuns, after.TotalRuns)
	}
	for status, want := range before.ByStatus {
		if after.ByStatus[status] != want {
			t.Errorf("ByStatus[%q] changed: before=%d after=%d", status, want, after.ByStatus[status])
		}
	}
	for typ, want := range before.ByType {
		if after.ByType[typ] != want {
			t.Errorf("ByType[%q] changed: before=%d after=%d", typ, want, after.ByType[typ])
		}
	}
	for agent, want := range before.ByAgent {
		if after.ByAgent[agent] != want {
			t.Errorf("ByAgent[%q] changed: before=%d after=%d", agent, want, after.ByAgent[agent])
		}
	}
	for model, want := range before.ByModel {
		if after.ByModel[model] != want {
			t.Errorf("ByModel[%q] changed: before=%d after=%d", model, want, after.ByModel[model])
		}
	}
	for provider, want := range before.ByProvider {
		if after.ByProvider[provider] != want {
			t.Errorf("ByProvider[%q] changed: before=%d after=%d", provider, want, after.ByProvider[provider])
		}
	}
}

// A project with no rotation ever run against it (RotateProject never
// called) never loses data — the store-level half of "a project with no
// Retention configured never rotates anything." The config-level decision of
// whether to call RotateProject at all belongs to internal/ui's rotation
// loop; this proves the store performs no rotation on its own.
func TestProjectNeverRotatedKeepsAllRunsRegardlessOfAge(t *testing.T) {
	st, _ := openTestStore(t)

	const runID = "ancient-passed"
	if err := st.CreateRun(&RunRecord{ID: runID, Project: "p", TaskID: runID, Status: "passed"}); err != nil {
		t.Fatal(err)
	}
	backdateRunCreatedAt(t, st, runID, time.Now().UTC().Add(-3650*24*time.Hour))

	// RotateProject is simply never called for this project — nothing in the
	// store spontaneously rotates data on its own.
	if _, err := st.GetRun(runID); err != nil {
		t.Errorf("expected run %q to still exist, GetRun error: %v", runID, err)
	}
}

// --- Task 3: RotateArtifacts ------------------------------------------------

func recordArtifactAt(t *testing.T, st *Store, id, runID, path string, capturedAt time.Time) {
	t.Helper()
	if err := os.WriteFile(path, []byte("evidence"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := st.RecordArtifact(&ArtifactRecord{
		ID: id, RunID: runID, PhaseID: "phase-1", Repo: "svc",
		Filename: filepath.Base(path), Path: path, CapturedAt: capturedAt,
	}); err != nil {
		t.Fatalf("RecordArtifact(%s): %v", id, err)
	}
}

// spec.md: "An artifact past its own horizon is deleted before its parent
// run rotates" — the artifact and its durable file are deleted while the
// parent run's rows remain, proving the two horizons are independent.
func TestRotateArtifactsDeletesOldArtifactBeforeParentRunRotates(t *testing.T) {
	st, _ := openTestStore(t)
	dir := t.TempDir()

	const runID = "run-with-old-artifact"
	if err := st.CreateRun(&RunRecord{ID: runID, Project: "p", TaskID: runID, Status: "passed"}); err != nil {
		t.Fatal(err)
	}
	// The run itself is recent — nowhere near its own (longer) RunsAfterDays
	// cutoff — while its artifact is old enough to rotate on its own,
	// shorter, ArtifactsAfterDays horizon.

	artifactPath := filepath.Join(dir, "shot.png")
	recordArtifactAt(t, st, "artifact-old", runID, artifactPath, time.Now().UTC().Add(-30*24*time.Hour))

	cutoff := time.Now().UTC().Add(-7 * 24 * time.Hour)
	rotated, err := st.RotateArtifacts(cutoff)
	if err != nil {
		t.Fatalf("RotateArtifacts: %v", err)
	}
	if rotated != 1 {
		t.Fatalf("rotated = %d, want 1", rotated)
	}

	if _, err := os.Stat(artifactPath); !os.IsNotExist(err) {
		t.Errorf("expected artifact file to be removed, stat err = %v", err)
	}
	if _, found, err := st.GetArtifact("artifact-old"); err != nil {
		t.Fatal(err)
	} else if found {
		t.Errorf("expected artifact row to be gone")
	}

	// The parent run survives untouched — its own horizon was never reached.
	if _, err := st.GetRun(runID); err != nil {
		t.Errorf("expected parent run to survive artifact rotation, GetRun error: %v", err)
	}
}

// An artifact newer than its horizon survives a rotation pass untouched.
func TestRotateArtifactsLeavesRecentArtifactUntouched(t *testing.T) {
	st, _ := openTestStore(t)
	dir := t.TempDir()

	const runID = "run-with-recent-artifact"
	if err := st.CreateRun(&RunRecord{ID: runID, Project: "p", TaskID: runID, Status: "passed"}); err != nil {
		t.Fatal(err)
	}

	artifactPath := filepath.Join(dir, "shot.png")
	recordArtifactAt(t, st, "artifact-recent", runID, artifactPath, time.Now().UTC())

	cutoff := time.Now().UTC().Add(-7 * 24 * time.Hour)
	rotated, err := st.RotateArtifacts(cutoff)
	if err != nil {
		t.Fatalf("RotateArtifacts: %v", err)
	}
	if rotated != 0 {
		t.Errorf("rotated = %d, want 0 for a recent artifact", rotated)
	}
	if _, err := os.Stat(artifactPath); err != nil {
		t.Errorf("expected artifact file to survive, stat err = %v", err)
	}
	if _, found, err := st.GetArtifact("artifact-recent"); err != nil {
		t.Fatal(err)
	} else if !found {
		t.Errorf("expected artifact row to survive")
	}
}
