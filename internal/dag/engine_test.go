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
