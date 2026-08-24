package mcp

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/callmeradical/sergeant/internal/naming"
	"github.com/callmeradical/sergeant/internal/store"
)

// Scenario (specs/work-type/spec.md): pull-request creation targets the exact
// branch that was created for a run. sergeant_seal_pr used to hand-build
// fmt.Sprintf("sergeant/%s", runID) independently of the branch
// prepareWorktree actually created; this proves it now looks the run up and
// computes the same naming.BranchName(run.Type, run.ChangeID) every other
// call site uses.
func TestSealPRInvokesGHAgainstTheRunsActualBranch(t *testing.T) {
	repoPath := t.TempDir()
	runGit := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-C", repoPath}, args...)...)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
	}
	runGit("init")
	runGit("config", "user.email", "t@example.com")
	runGit("config", "user.name", "t")
	if err := os.WriteFile(filepath.Join(repoPath, "f.txt"), []byte("x"), 0644); err != nil {
		t.Fatal(err)
	}

	// A fake gh that records the exact argument list it was invoked with.
	binDir := t.TempDir()
	argsFile := filepath.Join(binDir, "gh-args.txt")
	fakeGH := filepath.Join(binDir, "gh")
	script := "#!/bin/sh\necho \"$@\" > " + argsFile + "\necho https://github.com/example/repo/pull/1\n"
	if err := os.WriteFile(fakeGH, []byte(script), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	projPath := filepath.Join(t.TempDir(), "proj.yaml")
	projYAML := "name: sealpr\nrepos:\n  - name: svc\n    path: " + repoPath + "\n"
	if err := os.WriteFile(projPath, []byte(projYAML), 0644); err != nil {
		t.Fatal(err)
	}

	s, st := mcpFixture(t)
	const runID = "run-seal-1"
	if err := st.CreateRun(&store.RunRecord{
		ID: runID, Project: "sealpr", TaskID: runID, Status: "running",
		Type: "fix", ChangeID: "add-stripe-webhooks",
	}); err != nil {
		t.Fatal(err)
	}

	if _, err := s.executeTool("sergeant_seal_pr", map[string]interface{}{
		"run_id": runID, "project": projPath, "repo": "svc", "title": "t", "body": "b",
	}); err != nil {
		t.Fatalf("sergeant_seal_pr returned an error: %v", err)
	}

	argBytes, err := os.ReadFile(argsFile)
	if err != nil {
		t.Fatalf("gh was not invoked (no recorded args file): %v", err)
	}
	want := naming.BranchName("fix", "add-stripe-webhooks")
	if !strings.Contains(string(argBytes), "--head "+want) {
		t.Errorf("gh args = %q, want it to contain --head %s", argBytes, want)
	}
}
