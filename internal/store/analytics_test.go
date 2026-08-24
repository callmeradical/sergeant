package store

import (
	"fmt"
	"testing"
)

// createRunWithStatus is a small helper so each analytics test can seed a run
// without repeating CreateRun's full argument list.
func createRunWithStatus(t *testing.T, st *Store, id, project, status, workType string) {
	t.Helper()
	if err := st.CreateRun(&RunRecord{
		ID: id, Project: project, TaskID: id, Status: status, Type: workType, ChangeID: "c",
	}); err != nil {
		t.Fatalf("CreateRun(%s): %v", id, err)
	}
}

// recordPhaseWithPayload attaches a phase carrying an arbitrary payload to an
// existing run, the same shape annotatePayloadWithProvenance writes.
func recordPhaseWithPayload(t *testing.T, st *Store, runID, phaseID, payload string) {
	t.Helper()
	if err := st.RecordPhase(&PhaseRecord{
		ID: phaseID, RunID: runID, Repo: "svc", Name: "build", Kind: "agent", Status: "passed",
		Payload: []byte(payload),
	}); err != nil {
		t.Fatalf("RecordPhase(%s): %v", phaseID, err)
	}
}

// createBulletForNewIntent creates a fresh intent in project and one bullet
// under it at the given status, returning the bullet id.
func createBulletForNewIntent(t *testing.T, st *Store, id, project, status string) string {
	t.Helper()
	intentID := "intent-" + id
	if err := st.CreateIntent(&IntentRecord{ID: intentID, Project: project, Statement: "s", Status: "proposed"}); err != nil {
		t.Fatalf("CreateIntent(%s): %v", intentID, err)
	}
	if err := st.CreateBullet(&BulletRecord{ID: id, IntentID: intentID, Repo: "svc", Position: 0, Status: "pending"}); err != nil {
		t.Fatalf("CreateBullet(%s): %v", id, err)
	}
	if status != "pending" {
		if err := st.UpdateBulletStatus(id, status); err != nil {
			t.Fatalf("UpdateBulletStatus(%s): %v", id, err)
		}
	}
	return id
}

// AllRunsForAnalytics must return every run for a project, not the 50-row
// window ListRunsForProject/ListRecentRuns cap at — the same distinction
// RunsEligibleForCleanup already draws between "recent" and "everything".
func TestAllRunsForAnalyticsReturnsMoreThanFifty(t *testing.T) {
	st, _ := openTestStore(t)

	const total = 55
	for i := 0; i < total; i++ {
		createRunWithStatus(t, st, fmt.Sprintf("run-%03d", i), "p", "passed", "feat")
	}

	runs, err := st.AllRunsForAnalytics("p")
	if err != nil {
		t.Fatal(err)
	}
	if len(runs) != total {
		t.Fatalf("AllRunsForAnalytics returned %d runs, want %d (proves no silent 50-row cap)", len(runs), total)
	}
}

// AllRunsForAnalytics with an empty or "all" project must combine every
// project, matching handleRuns's existing project/all scoping convention.
func TestAllRunsForAnalyticsAllProjectsCombinesEveryProject(t *testing.T) {
	st, _ := openTestStore(t)

	createRunWithStatus(t, st, "run-a", "proj-a", "passed", "feat")
	createRunWithStatus(t, st, "run-b", "proj-b", "failed", "fix")

	forAll, err := st.AllRunsForAnalytics("all")
	if err != nil {
		t.Fatal(err)
	}
	if len(forAll) != 2 {
		t.Fatalf("AllRunsForAnalytics(\"all\") = %d runs, want 2", len(forAll))
	}

	forEmpty, err := st.AllRunsForAnalytics("")
	if err != nil {
		t.Fatal(err)
	}
	if len(forEmpty) != 2 {
		t.Fatalf("AllRunsForAnalytics(\"\") = %d runs, want 2", len(forEmpty))
	}
}

// AllBulletsForAnalytics must scope through the intent's project, since a
// bullet carries no project column of its own.
func TestAllBulletsForAnalyticsScopesThroughIntentProject(t *testing.T) {
	st, _ := openTestStore(t)

	createBulletForNewIntent(t, st, "bullet-a", "proj-a", "merged")
	createBulletForNewIntent(t, st, "bullet-b", "proj-b", "pending")

	scoped, err := st.AllBulletsForAnalytics("proj-a")
	if err != nil {
		t.Fatal(err)
	}
	if len(scoped) != 1 || scoped[0].ID != "bullet-a" {
		t.Fatalf("AllBulletsForAnalytics(proj-a) = %+v, want only bullet-a", scoped)
	}

	all, err := st.AllBulletsForAnalytics("all")
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 2 {
		t.Fatalf("AllBulletsForAnalytics(all) = %d bullets, want 2", len(all))
	}
}

// Scenario: Total run count and outcome breakdown reflect complete history.
func TestComputeWorkAnalyticsTotalsReflectMoreThanFifty(t *testing.T) {
	st, _ := openTestStore(t)

	const total = 60
	for i := 0; i < total; i++ {
		status := "passed"
		if i%5 == 0 {
			status = "failed"
		}
		createRunWithStatus(t, st, fmt.Sprintf("run-%03d", i), "p", status, "feat")
	}

	got, err := st.ComputeWorkAnalytics("p")
	if err != nil {
		t.Fatal(err)
	}
	if got.TotalRuns != total {
		t.Fatalf("TotalRuns = %d, want %d (must not be capped at 50)", got.TotalRuns, total)
	}
	sum := 0
	for _, c := range got.ByStatus {
		sum += c
	}
	if sum != total {
		t.Errorf("sum(ByStatus) = %d, want %d", sum, total)
	}
	if got.ByStatus["failed"] != 12 || got.ByStatus["passed"] != 48 {
		t.Errorf("ByStatus = %+v, want failed=12 passed=48", got.ByStatus)
	}
}

// Scenario: Work type breakdown covers pre-migration runs.
func TestComputeWorkAnalyticsBucketsEmptyTypeExplicitly(t *testing.T) {
	st, _ := openTestStore(t)

	createRunWithStatus(t, st, "run-typed", "p", "passed", "feat")
	createRunWithStatus(t, st, "run-pre-o2", "p", "passed", "")

	got, err := st.ComputeWorkAnalytics("p")
	if err != nil {
		t.Fatal(err)
	}
	if got.ByType["feat"] != 1 {
		t.Errorf("ByType[feat] = %d, want 1", got.ByType["feat"])
	}
	if got.ByType[""] != 1 {
		t.Errorf("ByType[\"\"] = %d, want 1 (pre-O2 run must be counted, not dropped)", got.ByType[""])
	}
	total := 0
	for _, c := range got.ByType {
		total += c
	}
	if total != got.TotalRuns {
		t.Errorf("sum(ByType) = %d, want %d (TotalRuns)", total, got.TotalRuns)
	}
}

// Scenario: A run with known provenance is counted under its agent/model/provider.
func TestComputeWorkAnalyticsKnownProvenance(t *testing.T) {
	st, _ := openTestStore(t)

	createRunWithStatus(t, st, "run-known", "p", "passed", "feat")
	recordPhaseWithPayload(t, st, "run-known", "phase-1",
		`{"agent":"goose","model":"claude-sonnet-4-6","provider":"anthropic"}`)

	got, err := st.ComputeWorkAnalytics("p")
	if err != nil {
		t.Fatal(err)
	}
	if got.ByAgent["goose"] != 1 {
		t.Errorf("ByAgent = %+v, want goose=1", got.ByAgent)
	}
	if got.ByModel["claude-sonnet-4-6"] != 1 {
		t.Errorf("ByModel = %+v, want claude-sonnet-4-6=1", got.ByModel)
	}
	if got.ByProvider["anthropic"] != 1 {
		t.Errorf("ByProvider = %+v, want anthropic=1", got.ByProvider)
	}
}

// Scenario: A run with no captured provenance is counted as unknown, not
// omitted — and every breakdown's sum must equal the total run count.
func TestComputeWorkAnalyticsUnknownProvenanceSumsToTotal(t *testing.T) {
	st, _ := openTestStore(t)

	createRunWithStatus(t, st, "run-known", "p", "passed", "feat")
	recordPhaseWithPayload(t, st, "run-known", "phase-1",
		`{"agent":"goose","model":"claude-sonnet-4-6","provider":"anthropic"}`)

	createRunWithStatus(t, st, "run-unknown-no-phase", "p", "passed", "feat")

	createRunWithStatus(t, st, "run-unknown-empty-agent", "p", "passed", "feat")
	recordPhaseWithPayload(t, st, "run-unknown-empty-agent", "phase-2", `{"command":"go test"}`)

	got, err := st.ComputeWorkAnalytics("p")
	if err != nil {
		t.Fatal(err)
	}
	if got.TotalRuns != 3 {
		t.Fatalf("TotalRuns = %d, want 3", got.TotalRuns)
	}
	if got.ByAgent[""] != 2 {
		t.Errorf("ByAgent[\"\"] = %d, want 2 unknown runs", got.ByAgent[""])
	}
	if got.ByModel[""] != 2 {
		t.Errorf("ByModel[\"\"] = %d, want 2 unknown runs", got.ByModel[""])
	}
	if got.ByProvider[""] != 2 {
		t.Errorf("ByProvider[\"\"] = %d, want 2 unknown runs", got.ByProvider[""])
	}

	for name, m := range map[string]map[string]int{"ByAgent": got.ByAgent, "ByModel": got.ByModel, "ByProvider": got.ByProvider} {
		sum := 0
		for _, c := range m {
			sum += c
		}
		if sum != got.TotalRuns {
			t.Errorf("sum(%s) = %d, want %d (every run must land in exactly one bucket)", name, sum, got.TotalRuns)
		}
	}
}

// Scenario: Merged and total bullet counts are both shown.
func TestComputeWorkAnalyticsBulletCounts(t *testing.T) {
	st, _ := openTestStore(t)

	createBulletForNewIntent(t, st, "bullet-merged-1", "p", "merged")
	createBulletForNewIntent(t, st, "bullet-merged-2", "p", "merged")
	createBulletForNewIntent(t, st, "bullet-open", "p", "green")

	got, err := st.ComputeWorkAnalytics("p")
	if err != nil {
		t.Fatal(err)
	}
	if got.BulletsTotal != 3 {
		t.Errorf("BulletsTotal = %d, want 3", got.BulletsTotal)
	}
	if got.BulletsMerged != 2 {
		t.Errorf("BulletsMerged = %d, want 2", got.BulletsMerged)
	}
}

// Scenario: Zero bullets renders without error — the store side of that
// scenario is simply that both counts are zero and no error occurs.
func TestComputeWorkAnalyticsZeroBullets(t *testing.T) {
	st, _ := openTestStore(t)
	createRunWithStatus(t, st, "run-only", "p", "passed", "feat")

	got, err := st.ComputeWorkAnalytics("p")
	if err != nil {
		t.Fatal(err)
	}
	if got.BulletsTotal != 0 || got.BulletsMerged != 0 {
		t.Errorf("BulletsTotal/BulletsMerged = %d/%d, want 0/0", got.BulletsTotal, got.BulletsMerged)
	}
}

// Scenario: A specific project shows only that project's data.
func TestComputeWorkAnalyticsScopesToOneProjectWithoutCommingling(t *testing.T) {
	st, _ := openTestStore(t)

	createRunWithStatus(t, st, "run-a1", "proj-a", "passed", "feat")
	createRunWithStatus(t, st, "run-a2", "proj-a", "failed", "fix")
	createRunWithStatus(t, st, "run-b1", "proj-b", "passed", "feat")
	createBulletForNewIntent(t, st, "bullet-a", "proj-a", "merged")
	createBulletForNewIntent(t, st, "bullet-b", "proj-b", "merged")

	got, err := st.ComputeWorkAnalytics("proj-a")
	if err != nil {
		t.Fatal(err)
	}
	if got.TotalRuns != 2 {
		t.Errorf("TotalRuns = %d, want 2 (proj-a only)", got.TotalRuns)
	}
	if got.BulletsTotal != 1 {
		t.Errorf("BulletsTotal = %d, want 1 (proj-a only)", got.BulletsTotal)
	}
}

// Scenario: "All projects" combines every project's data.
func TestComputeWorkAnalyticsAllProjectsCombinesEveryProject(t *testing.T) {
	st, _ := openTestStore(t)

	createRunWithStatus(t, st, "run-a1", "proj-a", "passed", "feat")
	createRunWithStatus(t, st, "run-b1", "proj-b", "passed", "feat")
	createBulletForNewIntent(t, st, "bullet-a", "proj-a", "merged")
	createBulletForNewIntent(t, st, "bullet-b", "proj-b", "pending")

	got, err := st.ComputeWorkAnalytics("all")
	if err != nil {
		t.Fatal(err)
	}
	if got.TotalRuns != 2 {
		t.Errorf("TotalRuns = %d, want 2", got.TotalRuns)
	}
	if got.BulletsTotal != 2 {
		t.Errorf("BulletsTotal = %d, want 2", got.BulletsTotal)
	}
	if got.BulletsMerged != 1 {
		t.Errorf("BulletsMerged = %d, want 1", got.BulletsMerged)
	}
}
