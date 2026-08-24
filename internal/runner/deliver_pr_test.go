package runner

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
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
