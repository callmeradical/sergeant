package dag

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/callmeradical/sergeant/internal/config"
	"github.com/callmeradical/sergeant/internal/handoff"
	"github.com/callmeradical/sergeant/internal/naming"
	"github.com/callmeradical/sergeant/internal/store"
)

// testWorkType is the work type engine tests dispatch as, wherever the test is
// not itself about which type was recorded. testBranch is the branch that
// naming.BranchName produces for a run created with this type and a change id
// equal to the run's own id — the same shape "sergeant/<run-id>" used to be.
const testWorkType = "feat"

func testBranch(runID string) string { return naming.BranchName(testWorkType, runID) }

// createTestRun writes a run row carrying testWorkType and a change id equal
// to its own run id, which is what prepareWorktree now requires to exist
// before it can name a branch (e.Store.GetRun(runID)). Tests that only
// exercise gate/agent-phase behaviour, not branch naming, use this so the
// resulting branch is at least deterministic and derived from the run id.
func createTestRun(t *testing.T, eng *Engine, project, runID, status string) {
	t.Helper()
	if err := eng.Store.CreateRun(&store.RunRecord{
		ID: runID, Project: project, TaskID: runID, Status: status,
		Type: testWorkType, ChangeID: runID,
	}); err != nil {
		t.Fatalf("creating run %s: %v", runID, err)
	}
}

func git(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	cmd.Env = append(os.Environ(),
		"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@example.com",
		"GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@example.com",
	)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %s: %v: %s", strings.Join(args, " "), err, out)
	}
}

func newGitRepo(t *testing.T, dir string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0755); err != nil {
		t.Fatal(err)
	}
	git(t, dir, "init", "-q", "-b", "main")
	if err := os.WriteFile(filepath.Join(dir, "README.md"), []byte("seed\n"), 0644); err != nil {
		t.Fatal(err)
	}
	git(t, dir, "add", ".")
	git(t, dir, "commit", "-q", "-m", "seed")
}

func newEngine(t *testing.T, proj *config.Project) *Engine {
	t.Helper()
	tmp := t.TempDir()
	st, err := store.Open(filepath.Join(tmp, "test.db"))
	if err != nil {
		t.Fatalf("failed to open store: %v", err)
	}
	t.Cleanup(func() { st.Close() })
	return NewEngine(proj, st, handoff.NewRouter(filepath.Join(tmp, "handoff")))
}

// A dispatched stage must run inside an isolated git worktree, never in the
// operator's configured checkout.
func TestRunStageIsolatesWorkInAWorktree(t *testing.T) {
	tempDir := t.TempDir()
	t.Setenv("SERGEANT_FLEET_DIR", filepath.Join(tempDir, "fleet"))

	backendDir := filepath.Join(tempDir, "backend")
	newGitRepo(t, backendDir)

	proj := &config.Project{
		Name: "test-proj",
		Repos: map[string]config.Repo{
			"backend": {
				Path: backendDir,
				Factory: &config.FactoryConfig{
					Pipeline: []string{"test"},
					Gates:    map[string]string{"unit-tests": "echo 'backend gates ok'"},
				},
			},
		},
	}

	engine := newEngine(t, proj)
	createTestRun(t, engine, proj.Name, "run-tdd-1", "running")
	stage := &config.DAGStage{Name: "build-and-test", Repos: []string{"backend"}}

	if err := engine.RunStage(context.Background(), "run-tdd-1", stage); err != nil {
		t.Fatalf("engine failed to run stage: %v", err)
	}

	wt := FleetDir("run-tdd-1", "backend")
	if _, err := os.Stat(wt); err != nil {
		t.Fatalf("expected isolated worktree at %s: %v", wt, err)
	}

	// The worktree must be on the run's own branch, not the repo's default branch.
	out, err := exec.Command("git", "-C", wt, "rev-parse", "--abbrev-ref", "HEAD").Output()
	if err != nil {
		t.Fatalf("reading worktree branch: %v", err)
	}
	if got, want := strings.TrimSpace(string(out)), testBranch("run-tdd-1"); got != want {
		t.Errorf("worktree branch = %q, want %q", got, want)
	}

	// The operator's checkout must be untouched and still on its own branch.
	out, err = exec.Command("git", "-C", backendDir, "rev-parse", "--abbrev-ref", "HEAD").Output()
	if err != nil {
		t.Fatalf("reading source branch: %v", err)
	}
	if got := strings.TrimSpace(string(out)); got != "main" {
		t.Errorf("source checkout switched to %q; dispatch must not touch it", got)
	}
}

// A repo that cannot be isolated must be refused, not silently mutated in place.
func TestRunStageRefusesNonGitRepo(t *testing.T) {
	tempDir := t.TempDir()
	t.Setenv("SERGEANT_FLEET_DIR", filepath.Join(tempDir, "fleet"))

	plainDir := filepath.Join(tempDir, "not-a-repo")
	if err := os.MkdirAll(plainDir, 0755); err != nil {
		t.Fatal(err)
	}

	proj := &config.Project{
		Name:  "test-proj",
		Repos: map[string]config.Repo{"backend": {Path: plainDir}},
	}

	engine := newEngine(t, proj)
	stage := &config.DAGStage{Name: "s", Repos: []string{"backend"}}

	err := engine.RunStage(context.Background(), "run-refuse-1", stage)
	if err == nil {
		t.Fatal("expected refusal for a non-git repo, got nil")
	}
	if !strings.Contains(err.Error(), "not a git repository") {
		t.Errorf("error should explain the refusal, got: %v", err)
	}
}

// R5.3/R5.4: RunStage's handoff injection from an upstream repo is wrapped in
// Store.DeliverEnvelope, not just exercised by hand-built store calls. This is
// the same class of gap found in envelope causation wiring, on the one real
// call site the delivery-durability merge (bde2b2d) shipped with zero test
// coverage (Review 007) — the runner.go call site had a regression test, this
// one did not.
func TestRunStageDeliversHandoffFromUpstreamEnvelope(t *testing.T) {
	tempDir := t.TempDir()
	t.Setenv("SERGEANT_FLEET_DIR", filepath.Join(tempDir, "fleet"))

	upstreamDir := filepath.Join(tempDir, "upstream")
	newGitRepo(t, upstreamDir)
	downstreamDir := filepath.Join(tempDir, "downstream")
	newGitRepo(t, downstreamDir)

	proj := &config.Project{
		Name: "test-proj",
		Repos: map[string]config.Repo{
			"upstream":   {Path: upstreamDir},
			"downstream": {
				Path: downstreamDir,
				Factory: &config.FactoryConfig{
					Pipeline: []string{"test"},
					Gates:    map[string]string{"unit-tests": "echo 'downstream gates ok'"},
				},
			},
		},
	}

	engine := newEngine(t, proj)
	const runID = "run-handoff-1"

	createTestRun(t, engine, "test-proj", runID, "running")
	const envID = "env-upstream-1"
	if err := engine.Store.RecordEnvelope(&store.EnvelopeRecord{
		ID: envID, RunID: runID, Repo: "upstream", Stage: "build", Summary: "upstream done",
		Type: "phase.completed", SchemaVersion: "1", Producer: "test", CorrelationID: runID,
	}); err != nil {
		t.Fatalf("recording upstream envelope: %v", err)
	}
	if err := engine.Router.SaveEnvelope(&handoff.Envelope{
		TaskID: runID, Repo: "upstream", Stage: "build", Summary: "upstream done",
	}); err != nil {
		t.Fatalf("seeding upstream handoff file: %v", err)
	}

	stage := &config.DAGStage{Name: "downstream-stage", Repos: []string{"downstream"}, After: []string{"upstream"}}
	if err := engine.RunStage(context.Background(), runID, stage); err != nil {
		t.Fatalf("engine failed to run stage: %v", err)
	}

	downstreamWorktree := FleetDir(runID, "downstream")
	injected := filepath.Join(downstreamWorktree, ".sergeant", "handoff", "upstream", "envelope_latest.json")
	if _, err := os.Stat(injected); err != nil {
		t.Fatalf("expected injected handoff file at %s: %v", injected, err)
	}

	history, err := engine.Store.ListDeliveryHistory(envID, downstreamWorktree)
	if err != nil {
		t.Fatalf("ListDeliveryHistory: %v", err)
	}
	if len(history) == 0 {
		t.Fatal("expected delivery history for the upstream handoff, got none — InjectHandoffToWorktree is not wired through DeliverEnvelope")
	}
	last := history[len(history)-1]
	if last.State != "delivered" {
		t.Errorf("expected final delivery state 'delivered', got %q", last.State)
	}
}

// Agent output must be committed so it survives worktree cleanup. Uncommitted
// work in a fleet worktree exists nowhere else and is destroyed by prune.
func TestCommitRunOutputMakesWorkRecoverable(t *testing.T) {
	tempDir := t.TempDir()
	t.Setenv("SERGEANT_FLEET_DIR", filepath.Join(tempDir, "fleet"))

	src := filepath.Join(tempDir, "svc")
	newGitRepo(t, src)

	proj := &config.Project{Name: "p", Repos: map[string]config.Repo{"svc": {Path: src}}}
	eng := newEngine(t, proj)
	createTestRun(t, eng, proj.Name, "run-commit-1", "running")

	ctx := context.Background()
	wt, isolated, err := eng.prepareWorktree(ctx, src, "run-commit-1", "svc")
	if err != nil || !isolated {
		t.Fatalf("prepareWorktree: %v", err)
	}

	// Nothing changed yet: must be a no-op, not an empty commit.
	committed, _, err := CommitRunOutput(ctx, "run-commit-1", "svc", "msg")
	if err != nil {
		t.Fatalf("no-op commit errored: %v", err)
	}
	if committed {
		t.Error("committed with no changes; expected no-op")
	}

	// Simulate agent output.
	if err := os.WriteFile(filepath.Join(wt, "feature.txt"), []byte("agent work\n"), 0644); err != nil {
		t.Fatal(err)
	}

	committed, sha, err := CommitRunOutput(ctx, "run-commit-1", "svc", "add feature")
	if err != nil {
		t.Fatalf("CommitRunOutput: %v", err)
	}
	if !committed || sha == "" {
		t.Fatalf("expected a commit, got committed=%v sha=%q", committed, sha)
	}

	if got := gitOutput(ctx, wt, "status", "--porcelain"); got != "" {
		t.Errorf("worktree still dirty after commit: %q", got)
	}

	// The decisive property: destroying the worktree must not destroy the work,
	// because the branch lives in the source repository.
	if err := os.RemoveAll(wt); err != nil {
		t.Fatal(err)
	}
	branch := testBranch("run-commit-1")
	if out := gitOutput(ctx, src, "cat-file", "-t", branch); out != "commit" {
		t.Fatalf("branch %s did not survive worktree deletion (got %q)", branch, out)
	}
	if body := gitOutput(ctx, src, "show", branch+":feature.txt"); body != "agent work" {
		t.Errorf("agent work not recoverable from branch, got %q", body)
	}
}

// Gates must run in a stable order. Ranging over the gates map directly made
// execution order random, so identical runs could report different failing gates.
func TestGatesRunInDeterministicOrder(t *testing.T) {
	order := func() []string {
		tempDir := t.TempDir()
		t.Setenv("SERGEANT_FLEET_DIR", filepath.Join(tempDir, "fleet"))
		src := filepath.Join(tempDir, "svc")
		newGitRepo(t, src)

		proj := &config.Project{
			Name: "p",
			Repos: map[string]config.Repo{"svc": {
				Path: src,
				Factory: &config.FactoryConfig{
					Pipeline: []string{"test"},
					Gates: map[string]string{
						"zeta": "true", "alpha": "true", "mike": "true", "bravo": "true",
					},
				},
			}},
		}
		eng := newEngine(t, proj)
		runID := "run-order-" + strconv.Itoa(int(time.Now().UnixNano()))
		createTestRun(t, eng, proj.Name, runID, "running")
		if err := eng.RunStage(context.Background(), runID, &config.DAGStage{Name: "s", Repos: []string{"svc"}}); err != nil {
			t.Fatalf("RunStage: %v", err)
		}
		phases, err := eng.Store.ListPhasesForRun(runID)
		if err != nil {
			t.Fatal(err)
		}
		var names []string
		for _, ph := range phases {
			if ph.Kind == "code" {
				names = append(names, ph.Name)
			}
		}
		return names
	}

	want := []string{"alpha", "bravo", "mike", "zeta"}
	for attempt := 0; attempt < 3; attempt++ {
		got := order()
		if len(got) != len(want) {
			t.Fatalf("attempt %d: got %v, want %v", attempt, got, want)
		}
		for i := range want {
			if got[i] != want[i] {
				t.Fatalf("attempt %d: gate order %v, want %v", attempt, got, want)
			}
		}
	}
}

// --- D3: red→green evidence -------------------------------------------------

// tddGateScript is a deterministic gate: it fails until an implementation file
// exists in the working tree. That makes a red state real (the behaviour is not
// implemented yet) and flips to green by writing the file, with no model
// judgment anywhere in the decision.
const tddGateScript = `#!/bin/sh
if [ -f impl.txt ]; then
  echo "implementation present"
  exit 0
fi
echo "impl.txt missing: behaviour not implemented"
exit 1
`

// newTDDRepo creates a git repo carrying the gate script. When implemented is
// true the implementation is committed up front, so the gate passes from the
// start and no red state can be observed.
func newTDDRepo(t *testing.T, dir string, implemented bool) {
	t.Helper()
	newGitRepo(t, dir)
	if err := os.WriteFile(filepath.Join(dir, "gate.sh"), []byte(tddGateScript), 0755); err != nil {
		t.Fatal(err)
	}
	if implemented {
		if err := os.WriteFile(filepath.Join(dir, "impl.txt"), []byte("done\n"), 0644); err != nil {
			t.Fatal(err)
		}
	}
	git(t, dir, "add", ".")
	git(t, dir, "commit", "-q", "-m", "gate")
}

func tddProject(repoName, repoPath string) *config.Project {
	return &config.Project{
		Name: "tdd-proj",
		Repos: map[string]config.Repo{
			repoName: {
				Path: repoPath,
				Factory: &config.FactoryConfig{
					Pipeline: []string{"test"},
					Gates:    map[string]string{"test": "sh gate.sh"},
				},
			},
		},
	}
}

// phasesByName returns every recorded phase with that name, oldest first. Each
// attempt keeps its own record, so a later attempt never erases an earlier one.
func phasesByName(t *testing.T, eng *Engine, runID, name string) []store.PhaseRecord {
	t.Helper()
	phases, err := eng.Store.ListPhasesForRun(runID)
	if err != nil {
		t.Fatalf("ListPhasesForRun: %v", err)
	}
	var out []store.PhaseRecord
	for i := range phases {
		if phases[i].Name == name {
			out = append(out, phases[i])
		}
	}
	return out
}

// latestPhaseByName returns the most recent recorded phase with that name, or nil.
func latestPhaseByName(t *testing.T, eng *Engine, runID, name string) *store.PhaseRecord {
	t.Helper()
	matches := phasesByName(t, eng, runID, name)
	if len(matches) == 0 {
		return nil
	}
	return &matches[len(matches)-1]
}

// D3: the red state is a real failing gate result, recorded on the run.
func TestRecordRedStateAcceptsAFailingGate(t *testing.T) {
	tempDir := t.TempDir()
	t.Setenv("SERGEANT_FLEET_DIR", filepath.Join(tempDir, "fleet"))

	src := filepath.Join(tempDir, "svc")
	newTDDRepo(t, src, false)

	eng := newEngine(t, tddProject("svc", src))
	runID := "run-red-1"
	createTestRun(t, eng, "tdd-proj", runID, "running")

	evidence, err := eng.RecordRedState(context.Background(), runID, "svc")
	if err != nil {
		t.Fatalf("RecordRedState on a failing gate: %v", err)
	}
	if len(evidence) != 1 {
		t.Fatalf("evidence = %+v, want 1 entry", evidence)
	}
	if got := evidence[0].Stage; got != StageRed {
		t.Errorf("Stage = %q, want %q", got, StageRed)
	}
	if got := evidence[0].Status; got != "failed" {
		t.Errorf("Status = %q, want %q", got, "failed")
	}
	if got := evidence[0].Gate; got != "test" {
		t.Errorf("Gate = %q, want %q", got, "test")
	}
	if !strings.Contains(evidence[0].Output, "impl.txt missing") {
		t.Errorf("Output = %q, want the gate's own output", evidence[0].Output)
	}
	if evidence[0].Duration <= 0 {
		t.Errorf("Duration = %v, want a positive measured duration", evidence[0].Duration)
	}

	// The evidence must be on the run, under a name that shows the stage.
	ph := latestPhaseByName(t, eng, runID, "red:test")
	if ph == nil {
		t.Fatal("no phase recorded for red:test")
	}
	if ph.Kind != "code" {
		t.Errorf("phase kind = %q, want %q", ph.Kind, "code")
	}
	if ph.Status != "failed" {
		t.Errorf("phase status = %q, want %q", ph.Status, "failed")
	}
}

// D3: if every gate already passes, the work was not test-first. That must be
// refused, not silently accepted as a red state.
func TestRecordRedStateRefusesWhenEveryGatePasses(t *testing.T) {
	tempDir := t.TempDir()
	t.Setenv("SERGEANT_FLEET_DIR", filepath.Join(tempDir, "fleet"))

	src := filepath.Join(tempDir, "svc")
	newTDDRepo(t, src, true) // implementation already committed: gate passes

	eng := newEngine(t, tddProject("svc", src))
	runID := "run-red-2"
	createTestRun(t, eng, "tdd-proj", runID, "running")

	evidence, err := eng.RecordRedState(context.Background(), runID, "svc")
	if err == nil {
		t.Fatal("expected an error when no gate fails, got nil")
	}
	if !strings.Contains(err.Error(), "no failing gate was observed") {
		t.Errorf("error should say no failing gate was observed, got: %v", err)
	}
	// What was observed is still returned and still recorded, so the refusal is
	// inspectable rather than a bare error.
	if len(evidence) != 1 || evidence[0].Status != "passed" {
		t.Errorf("evidence = %+v, want one passed gate", evidence)
	}
	if ph := latestPhaseByName(t, eng, runID, "red:test"); ph == nil || ph.Status != "passed" {
		t.Errorf("red:test phase = %+v, want a recorded passed phase", ph)
	}
}

// D3: red→green. The same gate must fail before implementation and pass after.
func TestRecordGreenStateRequiresEveryGateToPass(t *testing.T) {
	tempDir := t.TempDir()
	t.Setenv("SERGEANT_FLEET_DIR", filepath.Join(tempDir, "fleet"))

	src := filepath.Join(tempDir, "svc")
	newTDDRepo(t, src, false)

	eng := newEngine(t, tddProject("svc", src))
	runID := "run-green-1"
	createTestRun(t, eng, "tdd-proj", runID, "running")
	ctx := context.Background()

	if _, err := eng.RecordRedState(ctx, runID, "svc"); err != nil {
		t.Fatalf("RecordRedState: %v", err)
	}

	// Still red: green must be refused.
	if _, err := eng.RecordGreenState(ctx, runID, "svc"); err == nil {
		t.Fatal("expected RecordGreenState to fail while the gate still fails")
	}

	// Implement the behaviour in the run's isolated worktree.
	wt := FleetDir(runID, "svc")
	if err := os.WriteFile(filepath.Join(wt, "impl.txt"), []byte("done\n"), 0644); err != nil {
		t.Fatal(err)
	}

	evidence, err := eng.RecordGreenState(ctx, runID, "svc")
	if err != nil {
		t.Fatalf("RecordGreenState after implementation: %v", err)
	}
	if len(evidence) != 1 {
		t.Fatalf("evidence = %+v, want 1 entry", evidence)
	}
	if got := evidence[0].Stage; got != StageGreen {
		t.Errorf("Stage = %q, want %q", got, StageGreen)
	}
	if got := evidence[0].Status; got != "passed" {
		t.Errorf("Status = %q, want %q", got, "passed")
	}

	greens := phasesByName(t, eng, runID, "green:test")
	if len(greens) != 2 {
		t.Fatalf("recorded %d green:test phases, want 2 (the refused attempt and the passing one)", len(greens))
	}
	if greens[0].Status != "failed" {
		t.Errorf("first green:test attempt = %q, want it preserved as failed", greens[0].Status)
	}
	ph := greens[len(greens)-1]
	if ph.Kind != "code" || ph.Status != "passed" {
		t.Errorf("green:test phase kind/status = %q/%q, want code/passed", ph.Kind, ph.Status)
	}

	// The red evidence must still be there: green does not overwrite red.
	if red := latestPhaseByName(t, eng, runID, "red:test"); red == nil || red.Status != "failed" {
		t.Errorf("red:test phase = %+v, want the original failed record preserved", red)
	}

	// The operator's checkout must not have been touched by either stage.
	if _, err := os.Stat(filepath.Join(src, "impl.txt")); err == nil {
		t.Error("implementation appeared in the operator's checkout; gates must run in the worktree")
	}
}

// A repo with no configured gate has nothing deterministic to observe. Falling
// back to a gate that always passes would manufacture evidence.
func TestRedStateRequiresConfiguredGates(t *testing.T) {
	tempDir := t.TempDir()
	t.Setenv("SERGEANT_FLEET_DIR", filepath.Join(tempDir, "fleet"))

	src := filepath.Join(tempDir, "svc")
	newGitRepo(t, src)

	proj := &config.Project{
		Name:  "tdd-proj",
		Repos: map[string]config.Repo{"svc": {Path: src}},
	}
	eng := newEngine(t, proj)

	_, err := eng.RecordRedState(context.Background(), "run-nogates-1", "svc")
	if err == nil {
		t.Fatal("expected an error for a repo with no gates, got nil")
	}
	if !strings.Contains(err.Error(), "configures no gates") {
		t.Errorf("error should name the missing gate configuration, got: %v", err)
	}
}

// D3: an exemption must be explicit. An unexplained exemption is
// indistinguishable from skipping the rule.
func TestRedExemptionRequiresAReason(t *testing.T) {
	tempDir := t.TempDir()
	t.Setenv("SERGEANT_FLEET_DIR", filepath.Join(tempDir, "fleet"))

	src := filepath.Join(tempDir, "svc")
	newTDDRepo(t, src, false)

	eng := newEngine(t, tddProject("svc", src))
	runID := "run-exempt-1"

	for _, reason := range []string{"", "   \n\t"} {
		err := eng.RecordRedExemption(context.Background(), runID, "svc", reason)
		if err == nil {
			t.Fatalf("expected an error for reason %q, got nil", reason)
		}
		if !strings.Contains(err.Error(), "requires a reason") {
			t.Errorf("error should demand a reason, got: %v", err)
		}
	}

	phases, err := eng.Store.ListPhasesForRun(runID)
	if err != nil {
		t.Fatal(err)
	}
	if len(phases) != 0 {
		t.Errorf("a refused exemption recorded %d phase(s); it must record none", len(phases))
	}
}

// D3: a granted exemption is durable and visible on the run.
func TestRedExemptionIsRecordedAsAPhase(t *testing.T) {
	tempDir := t.TempDir()
	t.Setenv("SERGEANT_FLEET_DIR", filepath.Join(tempDir, "fleet"))

	src := filepath.Join(tempDir, "svc")
	newTDDRepo(t, src, false)

	eng := newEngine(t, tddProject("svc", src))
	runID := "run-exempt-2"
	reason := "pure refactor: extracts sortedGateNames, behaviour unchanged"

	if err := eng.RecordRedExemption(context.Background(), runID, "svc", reason); err != nil {
		t.Fatalf("RecordRedExemption: %v", err)
	}

	ph := latestPhaseByName(t, eng, runID, RedExemptionPhaseName)
	if ph == nil {
		t.Fatalf("no phase recorded for %s", RedExemptionPhaseName)
	}
	if ph.Repo != "svc" {
		t.Errorf("phase repo = %q, want %q", ph.Repo, "svc")
	}
	// An exemption is not a gate result and must not read as one.
	if ph.Kind == "code" {
		t.Error("exemption recorded with kind \"code\"; it would be mistaken for a gate result")
	}
	if ph.Status == "passed" {
		t.Error("exemption recorded with status \"passed\"; it would claim a gate that never ran")
	}
	if !strings.Contains(string(ph.Payload), reason) {
		t.Errorf("payload = %s, want it to carry the reason", ph.Payload)
	}

	// An exemption for a repo the project does not own is meaningless.
	if err := eng.RecordRedExemption(context.Background(), runID, "unknown", reason); err == nil {
		t.Error("expected an error for a repo that is not in the project")
	}
}

// With no override, v2 must place worktrees under its own state root. v1 uses
// ~/.local/share/sergeant/fleet/<task>/<repo>/ as a metadata directory, so
// writing worktrees there would corrupt v1's layout.
func TestFleetDirDefaultsToV2Root(t *testing.T) {
	t.Setenv("SERGEANT_FLEET_DIR", "")

	got := filepath.ToSlash(FleetDir("run-default-root", "backend"))

	if !strings.Contains(got, "sergeant-v2") {
		t.Errorf("FleetDir default = %q, want a path containing %q", got, "sergeant-v2")
	}
	if strings.Contains(got, "share/sergeant/fleet") {
		t.Errorf("FleetDir default = %q, must not use v1 root %q", got, "share/sergeant/fleet")
	}
}

// Resuming a run must never destroy the work it is resuming.
//
// prepareWorktree used `git worktree add -B <branch>`, and -B *resets* the branch
// to HEAD. That is correct when starting fresh and catastrophic when resuming: if
// the worktree directory is gone but the branch survives — a pruned worktree, a
// cleaned fleet dir, a machine restart — re-preparing the same run id silently
// discards every commit the previous attempt made.
//
// Run sgt-1787427981 is exactly this shape: killed at its timeout with a good
// commit on sergeant/sgt-1787427981 and nothing to pick it back up with.
func TestPrepareWorktreeDoesNotDiscardCommitsOnAnExistingBranch(t *testing.T) {
	ctx := context.Background()
	src := filepath.Join(t.TempDir(), "svc")
	newGitRepo(t, src)
	t.Setenv("SERGEANT_FLEET_DIR", t.TempDir())

	proj := &config.Project{Name: "p", Repos: map[string]config.Repo{"svc": {Path: src}}}
	eng := newEngine(t, proj)
	createTestRun(t, eng, proj.Name, "run-resume-1", "running")

	wt, _, err := eng.prepareWorktree(ctx, src, "run-resume-1", "svc")
	if err != nil {
		t.Fatalf("first prepareWorktree: %v", err)
	}

	// The previous attempt committed real work before it died.
	if err := os.WriteFile(filepath.Join(wt, "work.txt"), []byte("agent output\n"), 0644); err != nil {
		t.Fatal(err)
	}
	git(t, wt, "add", ".")
	git(t, wt, "commit", "-q", "-m", "work the previous attempt finished")
	want := gitOutput(ctx, wt, "rev-parse", "HEAD")
	if want == "" {
		t.Fatal("could not read the commit under test")
	}

	// The worktree goes away; the branch does not. `git worktree remove` is the
	// polite path, and a pruned fleet dir is the impolite one. Both must be safe.
	git(t, src, "worktree", "remove", "--force", wt)

	wt2, _, err := eng.prepareWorktree(ctx, src, "run-resume-1", "svc")
	if err != nil {
		t.Fatalf("second prepareWorktree: %v", err)
	}

	got := gitOutput(ctx, wt2, "rev-parse", "HEAD")
	if got != want {
		t.Errorf("resumed worktree HEAD = %q, want %q; the previous attempt's commit was discarded", got, want)
	}
	if _, err := os.Stat(filepath.Join(wt2, "work.txt")); err != nil {
		t.Errorf("work.txt missing after resume: %v; committed agent output was lost", err)
	}
}

// Resuming a run skips the phases that already passed and re-runs the rest.
//
// Without this, resuming means re-running everything, which throws away gate
// results that were already earned and re-invokes agents whose work is already
// committed. A phase that passed is a fact; a resume must not spend an agent
// invocation to re-derive it.
func TestResumeSkipsPhasesThatAlreadyPassed(t *testing.T) {
	tempDir := t.TempDir()
	t.Setenv("SERGEANT_FLEET_DIR", filepath.Join(tempDir, "fleet"))

	repoDir := filepath.Join(tempDir, "svc")
	newGitRepo(t, repoDir)

	// Two gates. The first already passed on the previous attempt; the second
	// never ran. Only the second may execute on resume.
	proj := &config.Project{
		Name: "p",
		Repos: map[string]config.Repo{
			"svc": {
				Path: repoDir,
				Factory: &config.FactoryConfig{
					Pipeline: []string{"test"},
					Gates: map[string]string{
						"already-passed": "exit 1", // would FAIL if wrongly re-run
						"never-ran":      "true",
					},
				},
			},
		},
	}

	e := newEngine(t, proj)
	e.Resume = true

	if err := e.Store.CreateRun(&store.RunRecord{
		ID: "run-r1", Project: "p", TaskID: "run-r1", Status: "failed",
		Type: testWorkType, ChangeID: "run-r1",
	}); err != nil {
		t.Fatal(err)
	}
	// The record the previous attempt left behind.
	if err := e.Store.RecordPhase(&store.PhaseRecord{
		ID: "ph-1", RunID: "run-r1", Repo: "svc",
		Name: "already-passed", Kind: "code", Status: "passed",
	}); err != nil {
		t.Fatal(err)
	}

	stage := &config.DAGStage{Name: "s", Repos: []string{"svc"}, Brief: "resume me"}
	if err := e.RunStage(context.Background(), "run-r1", stage); err != nil {
		t.Fatalf("RunStage on resume: %v; the already-passed gate was re-run and its `exit 1` failed the stage", err)
	}

	phases, err := e.Store.ListPhasesForRun("run-r1")
	if err != nil {
		t.Fatal(err)
	}
	var passedCount, ranAgain int
	for _, p := range phases {
		if p.Name == "already-passed" {
			passedCount++
			if p.ID != "ph-1" {
				ranAgain++
			}
		}
	}
	if ranAgain > 0 {
		t.Errorf("the already-passed gate produced %d new phase record(s); a passed phase must not re-run on resume", ranAgain)
	}

	var sawNeverRan bool
	for _, p := range phases {
		if p.Name == "never-ran" && p.Status == "passed" {
			sawNeverRan = true
		}
	}
	if !sawNeverRan {
		t.Error("the gate that never ran did not execute on resume; resume must continue the run, not merely skip it")
	}
}

// A fresh run must not skip anything, or a re-dispatch would silently inherit
// another run's results.
func TestFreshRunDoesNotSkipPhases(t *testing.T) {
	tempDir := t.TempDir()
	t.Setenv("SERGEANT_FLEET_DIR", filepath.Join(tempDir, "fleet"))
	repoDir := filepath.Join(tempDir, "svc")
	newGitRepo(t, repoDir)

	proj := &config.Project{
		Name: "p",
		Repos: map[string]config.Repo{
			"svc": {Path: repoDir, Factory: &config.FactoryConfig{
				Pipeline: []string{"test"},
				Gates:    map[string]string{"g": "true"},
			}},
		},
	}
	e := newEngine(t, proj) // Resume defaults to false
	createTestRun(t, e, "p", "run-f1", "running")
	if err := e.Store.RecordPhase(&store.PhaseRecord{
		ID: "old", RunID: "run-f1", Repo: "svc", Name: "g", Kind: "code", Status: "passed",
	}); err != nil {
		t.Fatal(err)
	}

	if err := e.RunStage(context.Background(), "run-f1", &config.DAGStage{Name: "s", Repos: []string{"svc"}}); err != nil {
		t.Fatalf("RunStage: %v", err)
	}

	phases, _ := e.Store.ListPhasesForRun("run-f1")
	var n int
	for _, p := range phases {
		if p.Name == "g" {
			n++
		}
	}
	if n < 2 {
		t.Errorf("gate ran %d time(s); a fresh run must execute every phase regardless of prior records", n-1)
	}
}

// --- R2.4: retry policy is explicit and observable ---------------------------

// The engine must pass the resolved retry count (not a hard-coded 0) to
// RunAgentPhase. We observe this indirectly: with a project that configures
// retries=1, a phase backed by a fake agent that always fails must produce
// exactly 2 phase records (1 original + 1 retry).
func TestEnginePassesResolvedRetriesToAgentPhase(t *testing.T) {
	tempDir := t.TempDir()
	t.Setenv("SERGEANT_FLEET_DIR", filepath.Join(tempDir, "fleet"))

	repoDir := filepath.Join(tempDir, "svc")
	newGitRepo(t, repoDir)

	// Write a fake agent that always exits non-zero.
	binDir := filepath.Join(tempDir, "bin")
	if err := os.MkdirAll(binDir, 0755); err != nil {
		t.Fatal(err)
	}
	fakeAgentPath := filepath.Join(binDir, "goose")
	if err := os.WriteFile(fakeAgentPath, []byte("#!/bin/sh\nexit 1\n"), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", binDir+":"+os.Getenv("PATH"))

	proj := &config.Project{
		Name:     "retry-proj",
		Defaults: config.ProjectDefaults{Agent: fakeAgentPath, Retries: 1},
		Repos: map[string]config.Repo{
			"svc": {Path: repoDir, Factory: &config.FactoryConfig{
				Pipeline: []string{"plan"},
			}},
		},
	}

	eng := newEngine(t, proj)
	runID := "run-retry-engine-1"
	createTestRun(t, eng, proj.Name, runID, "running")

	// The run must fail (agent always fails) — that's fine, we only care about the
	// phase count.
	_ = eng.RunStage(context.Background(), runID, &config.DAGStage{
		Name: "s", Repos: []string{"svc"}, Brief: "do work",
	})

	phases, err := eng.Store.ListPhasesForRun(runID)
	if err != nil {
		t.Fatal(err)
	}
	var planPhases []store.PhaseRecord
	for _, p := range phases {
		if p.Name == "plan" {
			planPhases = append(planPhases, p)
		}
	}
	// retries=1 means 2 total attempts; hard-coded 0 would give only 1.
	if got := len(planPhases); got != 2 {
		t.Errorf("plan phases = %d, want 2 (1 attempt + 1 retry); engine may be ignoring the configured retry count", got)
	}
}

// A failing deterministic gate must run exactly once even when a non-zero retry
// count is configured. A gate's exit status is the evidence; re-running it to
// get a different answer contradicts R2.5 and R2.6.
func TestGateIsNeverRetriedEvenWithRetryCount(t *testing.T) {
	tempDir := t.TempDir()
	t.Setenv("SERGEANT_FLEET_DIR", filepath.Join(tempDir, "fleet"))

	repoDir := filepath.Join(tempDir, "svc")
	newGitRepo(t, repoDir)

	proj := &config.Project{
		Name:     "retry-proj",
		Defaults: config.ProjectDefaults{Retries: 3},
		Repos: map[string]config.Repo{
			"svc": {Path: repoDir, Factory: &config.FactoryConfig{
				Pipeline: []string{"test"},
				Gates:    map[string]string{"unit": "exit 1"},
			}},
		},
	}

	eng := newEngine(t, proj)
	runID := "run-gate-no-retry-1"
	createTestRun(t, eng, proj.Name, runID, "running")

	_ = eng.RunStage(context.Background(), runID, &config.DAGStage{
		Name: "s", Repos: []string{"svc"},
	})

	phases, err := eng.Store.ListPhasesForRun(runID)
	if err != nil {
		t.Fatal(err)
	}
	var gatePhases []store.PhaseRecord
	for _, p := range phases {
		if p.Kind == "code" && p.Name == "unit" {
			gatePhases = append(gatePhases, p)
		}
	}
	if got := len(gatePhases); got != 1 {
		t.Errorf("gate ran %d time(s), want exactly 1; gates must never be retried", got)
	}
}

// A repo-level retry count overrides the project default in the engine.
func TestEngineUsesRepoRetryOverride(t *testing.T) {
	tempDir := t.TempDir()
	t.Setenv("SERGEANT_FLEET_DIR", filepath.Join(tempDir, "fleet"))

	repoDir := filepath.Join(tempDir, "svc")
	newGitRepo(t, repoDir)

	binDir := filepath.Join(tempDir, "bin")
	if err := os.MkdirAll(binDir, 0755); err != nil {
		t.Fatal(err)
	}
	fakeAgentPath := filepath.Join(binDir, "goose")
	if err := os.WriteFile(fakeAgentPath, []byte("#!/bin/sh\nexit 1\n"), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", binDir+":"+os.Getenv("PATH"))

	proj := &config.Project{
		Name:     "retry-proj",
		Defaults: config.ProjectDefaults{Agent: fakeAgentPath, Retries: 1},
		Repos: map[string]config.Repo{
			// repo override = 2 retries → 3 total attempts
			"svc": {Path: repoDir, Retries: 2, Factory: &config.FactoryConfig{
				Pipeline: []string{"plan"},
			}},
		},
	}

	eng := newEngine(t, proj)
	runID := "run-retry-repo-override-1"
	createTestRun(t, eng, proj.Name, runID, "running")

	_ = eng.RunStage(context.Background(), runID, &config.DAGStage{
		Name: "s", Repos: []string{"svc"}, Brief: "do work",
	})

	phases, err := eng.Store.ListPhasesForRun(runID)
	if err != nil {
		t.Fatal(err)
	}
	var planPhases []store.PhaseRecord
	for _, p := range phases {
		if p.Name == "plan" {
			planPhases = append(planPhases, p)
		}
	}
	if got := len(planPhases); got != 3 {
		t.Errorf("plan phases = %d, want 3 (repo retries=2 overrides project default retries=1)", got)
	}
}
