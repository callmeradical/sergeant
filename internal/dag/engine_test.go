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
	"github.com/callmeradical/sergeant/internal/store"
)

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
	if got, want := strings.TrimSpace(string(out)), BranchName("run-tdd-1"); got != want {
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

// Agent output must be committed so it survives worktree cleanup. Uncommitted
// work in a fleet worktree exists nowhere else and is destroyed by prune.
func TestCommitRunOutputMakesWorkRecoverable(t *testing.T) {
	tempDir := t.TempDir()
	t.Setenv("SERGEANT_FLEET_DIR", filepath.Join(tempDir, "fleet"))

	src := filepath.Join(tempDir, "svc")
	newGitRepo(t, src)

	ctx := context.Background()
	wt, isolated, err := prepareWorktree(ctx, src, "run-commit-1", "svc")
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
	branch := BranchName("run-commit-1")
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
