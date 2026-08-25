package runner

import (
	"context"
	"strings"
	"testing"
)

// RunShippingGate is not a *PhaseRunner method: a shipping gate evaluates an
// intent as a whole, which may span several worktrees, so there is no single
// pr.Worktree to run it in. Instead it publishes the bullets' worktree paths,
// comma-joined in merge order, as SERGEANT_BULLET_WORKTREES — the substrate a
// project's shipping-gate command needs to actually inspect more than one
// repo.
func TestRunShippingGateSetsBulletWorktreesEnvVar(t *testing.T) {
	res, err := RunShippingGate(context.Background(), "cross-repo", `echo "$SERGEANT_BULLET_WORKTREES"`, []string{"/tmp/a", "/tmp/b"})
	if err != nil {
		t.Fatalf("RunShippingGate error: %v", err)
	}
	if !res.Passed {
		t.Fatalf("expected the gate to pass, output=%q", res.Output)
	}
	if !strings.Contains(res.Output, "/tmp/a,/tmp/b") {
		t.Errorf("output = %q, want it to contain the comma-joined worktrees from SERGEANT_BULLET_WORKTREES", res.Output)
	}
}

// GateResult.Worktree makes a shipping-gate result auditable the same way
// RunCodeGate's already is: a comma-joined list of every worktree it ran
// against, in the same merge order the caller passed in.
func TestRunShippingGateResultRecordsTheWorktreeList(t *testing.T) {
	res, err := RunShippingGate(context.Background(), "cross-repo", "true", []string{"/tmp/a", "/tmp/b"})
	if err != nil {
		t.Fatalf("RunShippingGate error: %v", err)
	}
	if res.Worktree != "/tmp/a,/tmp/b" {
		t.Errorf("GateResult.Worktree = %q, want %q", res.Worktree, "/tmp/a,/tmp/b")
	}
	if res.Branch != "" {
		t.Errorf("GateResult.Branch = %q, want empty — a shipping gate spans potentially several branches", res.Branch)
	}
}

// A failing shipping-gate command must be observable the same way a failing
// code gate is: Passed is false, with no error returned for the caller to
// mishandle as "the gate could not be evaluated at all".
func TestRunShippingGateReportsFailureWithoutReturningAnError(t *testing.T) {
	res, err := RunShippingGate(context.Background(), "cross-repo", "exit 1", nil)
	if err != nil {
		t.Fatalf("RunShippingGate error: %v", err)
	}
	if res.Passed {
		t.Fatal("expected the gate to fail")
	}
}

// Output redaction/truncation must match RunCodeGate exactly (design.md):
// the pass/fail/output/redaction/timeout shape is identical between the two,
// only where the command runs and what tells it where to look differ.
func TestRunShippingGateRedactsSecretsFromOutput(t *testing.T) {
	secret := "AKIAIOSFODNN7EXAMPLE"
	res, err := RunShippingGate(context.Background(), "secret-gate", "echo 'AWS_CREDENTIAL="+secret+"'", nil)
	if err != nil {
		t.Fatalf("RunShippingGate error: %v", err)
	}
	if strings.Contains(res.Output, secret) {
		t.Errorf("GateResult.Output leaked the secret: %q", res.Output)
	}
	if !strings.Contains(res.Output, "[REDACTED]") {
		t.Errorf("GateResult.Output was not redacted: %q", res.Output)
	}
}
