package runner

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/callmeradical/sergeant/internal/handoff"
	"github.com/callmeradical/sergeant/internal/store"
)

func TestCodeGateExecution(t *testing.T) {
	tempDir := t.TempDir()
	dbPath := filepath.Join(tempDir, "test.db")
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("failed to open store: %v", err)
	}
	defer st.Close()

	router := handoff.NewRouter(filepath.Join(tempDir, "handoff"))

	pr := &PhaseRunner{
		Store:    st,
		Router:   router,
		Worktree: tempDir,
		RepoName: "backend",
		RunID:    "run-test",
	}

	ctx := context.Background()

	// 1. Test passing code gate
	res, err := pr.RunCodeGate(ctx, "pass-gate", "echo 'all tests passed'")
	if err != nil {
		t.Fatalf("RunCodeGate error: %v", err)
	}
	if !res.Passed {
		t.Errorf("expected gate to pass")
	}

	// 2. Test failing code gate
	resFail, err := pr.RunCodeGate(ctx, "fail-gate", "exit 1")
	if err != nil {
		t.Fatalf("RunCodeGate unexpected error: %v", err)
	}
	if resFail.Passed {
		t.Errorf("expected gate to fail")
	}
}

// fakeAgent writes an executable script that stands in for an agent CLI.
func fakeAgent(t *testing.T, dir, name, body string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte("#!/bin/sh\n"+body+"\n"), 0755); err != nil {
		t.Fatal(err)
	}
	return p
}

func newRunner(t *testing.T, agent string, timeout time.Duration) (*PhaseRunner, *store.Store) {
	t.Helper()
	tempDir := t.TempDir()
	st, err := store.Open(filepath.Join(tempDir, "test.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { st.Close() })
	if err := st.CreateRun(&store.RunRecord{ID: "run-1", Project: "p", TaskID: "run-1", Status: "running"}); err != nil {
		t.Fatal(err)
	}
	return &PhaseRunner{
		Store:        st,
		Router:       handoff.NewRouter(filepath.Join(tempDir, "handoff")),
		Worktree:     tempDir,
		RepoName:     "svc",
		RunID:        "run-1",
		AgentCLI:     agent,
		AgentTimeout: timeout,
	}, st
}

// PRD R2.6: a worker/phase process exit cannot falsely mark a phase as passed.
// Regression: RunAgentPhase used to hardcode phaseStatus="passed", ignore the exec
// error, and return nil — so an agent killed at its timeout produced a passed run.
func TestAgentPhaseFailureIsNotRecordedAsPassed(t *testing.T) {
	cases := []struct {
		name    string
		body    string
		timeout time.Duration
		wantErr string
	}{
		{"non-zero exit", "exit 3", 10 * time.Second, "exited with error"},
		{"killed at timeout", "sleep 30", 150 * time.Millisecond, "exceeded its"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			agent := fakeAgent(t, dir, "agent.sh", tc.body)
			pr, st := newRunner(t, agent, tc.timeout)

			env, err := pr.RunAgentPhase(context.Background(), "build", "do the thing", 0)
			if err == nil {
				t.Fatal("expected an error from a failed agent, got nil")
			}
			if env != nil {
				t.Errorf("expected no envelope on failure, got %+v", env)
			}
			if !strings.Contains(err.Error(), tc.wantErr) {
				t.Errorf("error should explain the failure; got %v", err)
			}

			phases, perr := st.ListPhasesForRun("run-1")
			if perr != nil {
				t.Fatal(perr)
			}
			if len(phases) != 1 {
				t.Fatalf("expected 1 phase record, got %d", len(phases))
			}
			if phases[0].Status != "failed" {
				t.Errorf("phase status = %q, want failed", phases[0].Status)
			}
			if phases[0].Error == "" {
				t.Error("phase should record why it failed")
			}

			// The envelope must not claim the phase completed.
			envs, eerr := st.ListEnvelopesForRun("run-1")
			if eerr != nil {
				t.Fatal(eerr)
			}
			if len(envs) != 1 {
				t.Fatalf("expected 1 envelope, got %d", len(envs))
			}
			if strings.Contains(envs[0].Summary, "completed") {
				t.Errorf("envelope claims completion for a failed phase: %q", envs[0].Summary)
			}
		})
	}
}

// PRD R2.4: retry policy must be explicit and observable. Each attempt gets its own
// phase record; a single reused id made retries invisible via INSERT OR REPLACE.
func TestAgentPhaseRetriesAreObservable(t *testing.T) {
	dir := t.TempDir()
	agent := fakeAgent(t, dir, "agent.sh", "exit 1")
	pr, st := newRunner(t, agent, 10*time.Second)

	if _, err := pr.RunAgentPhase(context.Background(), "build", "brief", 2); err == nil {
		t.Fatal("expected failure after retries")
	}

	phases, err := st.ListPhasesForRun("run-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(phases) != 3 {
		t.Fatalf("expected 3 attempt records (1 + 2 retries), got %d", len(phases))
	}
	for _, p := range phases {
		if p.Status != "failed" {
			t.Errorf("attempt %s status = %q, want failed", p.ID, p.Status)
		}
	}
}

// A successful agent still records passed and returns its envelope.
func TestAgentPhaseSuccessStillPasses(t *testing.T) {
	dir := t.TempDir()
	agent := fakeAgent(t, dir, "agent.sh", "echo done")
	pr, st := newRunner(t, agent, 10*time.Second)

	env, err := pr.RunAgentPhase(context.Background(), "build", "brief", 0)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if env == nil {
		t.Fatal("expected an envelope")
	}
	phases, _ := st.ListPhasesForRun("run-1")
	if len(phases) != 1 || phases[0].Status != "passed" {
		t.Fatalf("expected 1 passed phase, got %+v", phases)
	}
}

// An agent phase has no default deadline. Agent work has no predictable upper
// bound, and a default budget silently kills productive work: run
// sgt-1787427981 was killed at exactly the former 10m default having already
// committed work whose build and tests passed, and the bullet was discarded.
//
// A gate keeps its default. A gate is a deterministic command, so a gate that
// stops making progress is genuinely hung and killing it is correct.
func TestAgentPhaseHasNoDefaultTimeout(t *testing.T) {
	t.Setenv("SERGEANT_AGENT_TIMEOUT", "")
	pr, _ := newRunner(t, "opencode", 0)

	if got := pr.agentTimeout(); got != 0 {
		t.Errorf("agentTimeout() with nothing configured = %v, want 0 (unbounded); a default budget kills real agent work", got)
	}
	if DefaultAgentTimeout != 0 {
		t.Errorf("DefaultAgentTimeout = %v, want 0", DefaultAgentTimeout)
	}
	if got := pr.gateTimeout(); got != DefaultGateTimeout || got == 0 {
		t.Errorf("gateTimeout() = %v, want the %v default; gates stay bounded", got, DefaultGateTimeout)
	}
}

// The budget remains available, opt-in, for an operator who wants one.
func TestAgentTimeoutIsOptIn(t *testing.T) {
	t.Setenv("SERGEANT_AGENT_TIMEOUT", "45s")
	pr, _ := newRunner(t, "opencode", 0)
	if got := pr.agentTimeout(); got != 45*time.Second {
		t.Errorf("agentTimeout() with env set = %v, want 45s", got)
	}

	explicit, _ := newRunner(t, "opencode", 2*time.Minute)
	if got := explicit.agentTimeout(); got != 2*time.Minute {
		t.Errorf("explicit AgentTimeout = %v, want 2m", got)
	}
}

// An unbounded agent phase must still stop when the operator cancels the run.
// Removing the deadline must not remove cancellation: without the parent context
// wired through, a cancelled run would leave the agent running forever.
func TestUnboundedAgentPhaseStillHonoursCancellation(t *testing.T) {
	dir := t.TempDir()
	pr, st := newRunner(t, fakeAgent(t, dir, "slow-agent", "sleep 30"), 0)

	ctx, cancel := context.WithCancel(context.Background())
	go func() { time.Sleep(200 * time.Millisecond); cancel() }()

	start := time.Now()
	_, err := pr.RunAgentPhase(ctx, "build", "do the thing", 0)
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("RunAgentPhase returned nil error after cancellation, want a cancellation error")
	}
	if elapsed > 10*time.Second {
		t.Errorf("cancellation took %v; an unbounded phase ignored the parent context", elapsed)
	}
	_ = st
}
