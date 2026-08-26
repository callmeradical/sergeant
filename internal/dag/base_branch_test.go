package dag

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/callmeradical/sergeant/internal/config"
)

// Scenario: "A run's first worktree creation records its real base branch"
// (specs/change-request-merge/spec.md). newGitRepo checks the source repo
// out on "main" — prepareWorktree must durably record that as the run's
// BaseBranch, not guess at it later.
func TestPrepareWorktreeRecordsTheSourceRepoRealBaseBranch(t *testing.T) {
	ctx := context.Background()
	src := filepath.Join(t.TempDir(), "svc")
	newGitRepo(t, src)
	t.Setenv("SERGEANT_FLEET_DIR", t.TempDir())

	proj := &config.Project{Name: "p", Repos: map[string]config.Repo{"svc": {Path: src}}}
	eng := newEngine(t, proj)
	createTestRun(t, eng, proj.Name, "run-basebranch-1", "running")

	if _, _, err := eng.prepareWorktree(ctx, src, "run-basebranch-1", "svc"); err != nil {
		t.Fatalf("prepareWorktree: %v", err)
	}

	run, err := eng.Store.GetRun("run-basebranch-1")
	if err != nil {
		t.Fatal(err)
	}
	if run.BaseBranch != "main" {
		t.Errorf("run.BaseBranch = %q, want %q (the source repo's actual checked-out branch)", run.BaseBranch, "main")
	}
}

// Scenario: "Resuming a run does not overwrite its recorded base branch"
// (specs/change-request-merge/spec.md). A run whose worktree was removed
// but whose branch survived is resumed after the source repo's checked-out
// branch has since changed — the recorded BaseBranch must stay what the
// first attempt captured, not silently follow the operator's checkout.
func TestResumingARunDoesNotOverwriteItsRecordedBaseBranch(t *testing.T) {
	ctx := context.Background()
	src := filepath.Join(t.TempDir(), "svc")
	newGitRepo(t, src)
	t.Setenv("SERGEANT_FLEET_DIR", t.TempDir())

	proj := &config.Project{Name: "p", Repos: map[string]config.Repo{"svc": {Path: src}}}
	eng := newEngine(t, proj)
	createTestRun(t, eng, proj.Name, "run-basebranch-resume-1", "running")

	wt, _, err := eng.prepareWorktree(ctx, src, "run-basebranch-resume-1", "svc")
	if err != nil {
		t.Fatalf("first prepareWorktree: %v", err)
	}

	run, err := eng.Store.GetRun("run-basebranch-resume-1")
	if err != nil {
		t.Fatal(err)
	}
	if run.BaseBranch != "main" {
		t.Fatalf("run.BaseBranch after first attempt = %q, want %q", run.BaseBranch, "main")
	}

	// The worktree goes away, same as TestPrepareWorktreeDoesNotDiscardCommitsOnAnExistingBranch.
	git(t, src, "worktree", "remove", "--force", wt)

	// The operator's own checkout has since moved on to a different branch.
	git(t, src, "checkout", "-q", "-b", "some-other-branch")

	if _, _, err := eng.prepareWorktree(ctx, src, "run-basebranch-resume-1", "svc"); err != nil {
		t.Fatalf("resumed prepareWorktree: %v", err)
	}

	run, err = eng.Store.GetRun("run-basebranch-resume-1")
	if err != nil {
		t.Fatal(err)
	}
	if run.BaseBranch != "main" {
		t.Errorf("run.BaseBranch after resume = %q, want unchanged %q even though the source checkout moved to %q", run.BaseBranch, "main", "some-other-branch")
	}
}
