package runner

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/callmeradical/sergeant/internal/naming"
	"github.com/callmeradical/sergeant/internal/store"
)

// DeliverPullRequest returns gh pr create's raw stdout/stderr verbatim on
// success — a third, independent write path for gh output (alongside
// handleCreatePR, fixed separately) that must not bypass redaction just
// because this path returns rather than persists (Review 016).
func TestDeliverPullRequestRedactsGHOutput(t *testing.T) {
	worktree := t.TempDir()
	runGit := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-C", worktree}, args...)...)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
	}
	runGit("init")
	runGit("config", "user.email", "test@example.com")
	runGit("config", "user.name", "test")
	if err := os.WriteFile(filepath.Join(worktree, "f.txt"), []byte("x"), 0644); err != nil {
		t.Fatal(err)
	}

	secret := "sk-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOP"
	binDir := t.TempDir()
	fakeGH := filepath.Join(binDir, "gh")
	if err := os.WriteFile(fakeGH, []byte("#!/bin/sh\necho 'warning: using token "+secret+"'\necho 'https://github.com/example/repo/pull/1'\n"), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	pr := &PhaseRunner{Worktree: worktree, RepoName: "svc", RunID: "run-1"}
	out, err := pr.DeliverPullRequest(context.Background(), "sergeant/run-1", "title", "body")
	if err != nil {
		t.Fatalf("DeliverPullRequest returned an error: %v", err)
	}
	if strings.Contains(out, secret) {
		t.Errorf("DeliverPullRequest leaked the secret: %q", out)
	}
	if !strings.Contains(out, "[REDACTED]") {
		t.Errorf("DeliverPullRequest output was not redacted: %q", out)
	}
}

// Scenario (specs/work-type/spec.md): DeliverPullRequest's fallback for an
// empty branch (its caller passing "") must compute the same
// naming.BranchName(run.Type, run.ChangeID) every other call site uses,
// looked up via pr.Store.GetRun(pr.RunID) — not a hand-built
// "sergeant/<run>-<repo>" string independent of the branch actually created.
func TestDeliverPullRequestFallsBackToNamingBranchNameWhenBranchIsEmpty(t *testing.T) {
	worktree := t.TempDir()
	runGit := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-C", worktree}, args...)...)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
	}
	runGit("init")
	runGit("config", "user.email", "test@example.com")
	runGit("config", "user.name", "test")
	if err := os.WriteFile(filepath.Join(worktree, "f.txt"), []byte("x"), 0644); err != nil {
		t.Fatal(err)
	}

	// A fake gh that always fails, forcing DeliverPullRequest's local-review
	// fallback path, which records the branch it actually used.
	binDir := t.TempDir()
	fakeGH := filepath.Join(binDir, "gh")
	if err := os.WriteFile(fakeGH, []byte("#!/bin/sh\nexit 1\n"), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	st, err := store.Open(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	const runID = "run-fallback-1"
	if err := st.CreateRun(&store.RunRecord{
		ID: runID, Project: "p", TaskID: runID, Status: "running",
		Type: "refactor", ChangeID: "consolidate-store",
	}); err != nil {
		t.Fatal(err)
	}

	pr := &PhaseRunner{Store: st, Worktree: worktree, RepoName: "svc", RunID: runID}
	msg, err := pr.DeliverPullRequest(context.Background(), "", "title", "body")
	if err != nil {
		t.Fatalf("DeliverPullRequest returned an error: %v", err)
	}

	want := naming.BranchName("refactor", "consolidate-store")
	if !strings.Contains(msg, want) {
		t.Errorf("DeliverPullRequest message = %q, want it to name the fallback branch %q", msg, want)
	}
}
