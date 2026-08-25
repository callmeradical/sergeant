package ui

// Characterization tests for specs/dispatch-execution-decomposition/spec.md.
//
// Written against the CURRENT (pre-extraction) server.go and confirmed passing
// before handleDispatch/createRunAndDispatch/executeRun and their support
// functions move to dispatch.go. Re-run unmodified after the move; the seam
// this change introduces (stageRunner) only narrows executeRun's engine
// parameter type, so a real *dag.Engine argument still satisfies it and every
// test below needs no edit for the move itself.
//
// Scenarios s-1, s-2 and s-5 already have direct, extensive coverage
// elsewhere in this package (server_test.go's TestDispatchWithUnknownChangeIDIsRejectedAndCreatesNoRun,
// TestDispatchRecordsAnExistingChangeIDOnTheRun, TestDispatchPersistsItsIntentAndOneBulletPerTargetRepo,
// dispatch_idempotency_test.go, and run_lifecycle_test.go's recordTerminalRun/
// blockedReasonForRun tests including a real failing dispatch in
// TestADispatchedRunAdvancesItsBulletsThroughTheTerminalPath) — that suite
// already pins handleDispatch's validation/response behavior and
// recordTerminalRun/blockedReasonForRun's failure-mapping behavior, and
// continues to run, unmodified, before and after this move. This file adds
// the two scenarios that had no prior coverage: s-3 (executeRun runs
// configured stages in order) and s-4 (executeRun is testable with a fake
// stage runner, added once the stageRunner seam exists).

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/callmeradical/sergeant/internal/config"
	"github.com/callmeradical/sergeant/internal/dag"
	"github.com/callmeradical/sergeant/internal/handoff"
	"github.com/callmeradical/sergeant/internal/store"
)

// Scenario: executeRun runs configured stages in order.
//
// Two repos, each its own DAG stage, each stage's one gate appends its own
// repo name to a shared log file. If executeRun ran RunStage out of the
// project's configured order, or ran both concurrently, the log would show it.
func TestExecuteRunRunsConfiguredStagesInOrder(t *testing.T) {
	base := t.TempDir()
	cfgDir := filepath.Join(base, "config")
	if err := os.MkdirAll(cfgDir, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SERGEANT_CONFIG", cfgDir)
	t.Setenv("SERGEANT_FLEET_DIR", filepath.Join(base, "fleet"))

	repoA := filepath.Join(base, "repoA")
	repoB := filepath.Join(base, "repoB")
	initGitRepo(t, repoA)
	initGitRepo(t, repoB)

	orderLog := filepath.Join(base, "order.log")
	t.Setenv("ORDER_LOG", orderLog)

	projYAML := fmt.Sprintf(`name: ordered-proj
repos:
  - name: repoA
    path: %s
    factory:
      pipeline: [test]
      gates:
        mark: "echo repoA >> $ORDER_LOG"
  - name: repoB
    path: %s
    factory:
      pipeline: [test]
      gates:
        mark: "echo repoB >> $ORDER_LOG"
dag:
  name: ordered-pipeline
  stages:
    - name: stage-a
      repos: [repoA]
    - name: stage-b
      repos: [repoB]
`, repoA, repoB)
	if err := os.WriteFile(filepath.Join(cfgDir, "ordered-proj.yaml"), []byte(projYAML), 0o644); err != nil {
		t.Fatal(err)
	}

	st, err := store.Open(filepath.Join(base, "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	srv := NewServer(st, 0)

	proj, err := config.LoadProject("ordered-proj")
	if err != nil {
		t.Fatal(err)
	}

	const runID = "sgt-order-test"
	if err := st.CreateRun(&store.RunRecord{
		ID: runID, Project: proj.Name, TaskID: runID, Type: "feat", ChangeID: "order-change", Status: "running",
	}); err != nil {
		t.Fatal(err)
	}

	router := handoff.NewRouter(filepath.Join(dag.FleetRoot(), runID, "handoff"))
	engine := dag.NewEngine(proj, st, router)

	ctx, cancel := context.WithCancel(context.Background())
	srv.executeRun(ctx, cancel, engine, proj, runID, "order test", nil, "")

	run, err := st.GetRun(runID)
	if err != nil {
		t.Fatal(err)
	}
	if run.Status != "passed" {
		t.Fatalf("run status = %q, want passed; body of order log so far: %s", run.Status, readFileOrEmpty(t, orderLog))
	}

	got := readFileOrEmpty(t, orderLog)
	lines := strings.Fields(got)
	if len(lines) != 2 {
		t.Fatalf("order log has %d line(s), want 2: %q", len(lines), got)
	}
	if lines[0] != "repoA" || lines[1] != "repoB" {
		t.Errorf("stage order = %v, want [repoA repoB] (the project's configured stage order)", lines)
	}
}

// fakeStageRunner implements stageRunner without touching git or spawning an
// agent process. It records which stages it was asked to run, in order, so a
// test can assert on executeRun's behavior without a real *dag.Engine.
type fakeStageRunner struct {
	mu  sync.Mutex
	ran []string
}

func (f *fakeStageRunner) RunStage(ctx context.Context, runID string, stage *config.DAGStage) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.ran = append(f.ran, stage.Name)
	return nil
}

func (f *fakeStageRunner) stagesRun() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.ran...)
}

// Scenario: executeRun is testable with a fake stage runner.
//
// This is the point of the stageRunner seam: executeRun is driven end to end
// with no real *dag.Engine, so no git worktree and no agent CLI is ever
// touched — proven here by asserting the fleet directory gains no entries.
func TestExecuteRunIsTestableWithAFakeStageRunner(t *testing.T) {
	base := t.TempDir()
	fleetRoot := filepath.Join(base, "fleet")
	t.Setenv("SERGEANT_FLEET_DIR", fleetRoot)

	proj := &config.Project{
		Name: "fake-proj",
		DAG: &config.DAGConfig{
			Name: "fake-pipeline",
			Stages: []config.DAGStage{
				{Name: "stage-1", Repos: []string{"repoA"}},
				{Name: "stage-2", Repos: []string{"repoB"}},
			},
		},
	}

	st, err := store.Open(filepath.Join(base, "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	srv := NewServer(st, 0)

	const runID = "sgt-fake-stage-test"
	if err := st.CreateRun(&store.RunRecord{
		ID: runID, Project: proj.Name, TaskID: runID, Type: "feat", ChangeID: "fake-change", Status: "running",
	}); err != nil {
		t.Fatal(err)
	}

	fake := &fakeStageRunner{}
	ctx, cancel := context.WithCancel(context.Background())
	srv.executeRun(ctx, cancel, fake, proj, runID, "fake stage runner test", nil, "")

	if got, want := fake.stagesRun(), []string{"stage-1", "stage-2"}; !equalStrings(got, want) {
		t.Errorf("stages run = %v, want %v", got, want)
	}

	run, err := st.GetRun(runID)
	if err != nil {
		t.Fatal(err)
	}
	if run.Status != "passed" {
		t.Errorf("run status = %q, want passed", run.Status)
	}

	// No real worktree or agent process exists to have created anything under
	// the fleet root — the fake never shells out or writes to disk.
	if entries, err := os.ReadDir(fleetRoot); err == nil && len(entries) != 0 {
		t.Errorf("fleet root gained %d entr(y/ies) with a fake stage runner, want 0: %v", len(entries), entries)
	} else if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
}

func readFileOrEmpty(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return ""
		}
		t.Fatal(err)
	}
	return string(b)
}
