package runner

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/callmeradical/sergeant/internal/handoff"
	"github.com/callmeradical/sergeant/internal/store"
)

// runGit runs a git command in dir, failing the test on error. It exists
// here (rather than reusing internal/dag's test helper) because runner_test
// is a different package and has had no need for a git fixture until now.
func runGit(t *testing.T, dir string, args ...string) {
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

			env, _, err := pr.RunAgentPhase(context.Background(), "build", "do the thing", 0)
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

// On exhausted retries, RunAgentPhase returns an error built from a second,
// independent read of the raw output buffer (to embed it for a human
// debugging the failure) — that read must not bypass redaction, or a failing
// agent that printed a secret leaks it into the returned error and, via
// cmd/sergeant, straight to stderr (Review 016).
func TestAgentPhaseFailureErrorIsRedacted(t *testing.T) {
	dir := t.TempDir()
	secret := "sk-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOP"
	agent := fakeAgent(t, dir, "agent.sh", "echo 'API_KEY="+secret+"'; exit 1")
	pr, _ := newRunner(t, agent, 10*time.Second)

	_, _, err := pr.RunAgentPhase(context.Background(), "build", "do the thing", 0)
	if err == nil {
		t.Fatal("expected an error from a failed agent, got nil")
	}
	if strings.Contains(err.Error(), secret) {
		t.Errorf("returned error leaked the secret: %v", err)
	}
	if !strings.Contains(err.Error(), "[REDACTED]") {
		t.Errorf("returned error was not redacted: %v", err)
	}
}

// PRD R2.4: retry policy must be explicit and observable. Each attempt gets its own
// phase record; a single reused id made retries invisible via INSERT OR REPLACE.
func TestAgentPhaseRetriesAreObservable(t *testing.T) {
	dir := t.TempDir()
	agent := fakeAgent(t, dir, "agent.sh", "exit 1")
	pr, st := newRunner(t, agent, 10*time.Second)

	if _, _, err := pr.RunAgentPhase(context.Background(), "build", "brief", 2); err == nil {
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

	env, _, err := pr.RunAgentPhase(context.Background(), "build", "brief", 0)
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

// R5.3/R5.4: RunAgentPhase's SaveEnvelope write is wrapped in DeliverEnvelope,
// not just exercised by hand-built store calls. This is the same class of gap
// found in envelope causation wiring: the store-level plumbing can be correct
// while the real call site still discards its error with "_ = ...".
func TestAgentPhaseRecordsDurableDelivery(t *testing.T) {
	dir := t.TempDir()
	agent := fakeAgent(t, dir, "agent.sh", "echo done")
	pr, st := newRunner(t, agent, 10*time.Second)

	if _, _, err := pr.RunAgentPhase(context.Background(), "build", "brief", 0); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	envs, err := st.ListEnvelopesForRun("run-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(envs) != 1 {
		t.Fatalf("expected 1 envelope, got %d", len(envs))
	}

	history, err := st.ListDeliveryHistory(envs[0].ID, pr.RepoName)
	if err != nil {
		t.Fatal(err)
	}
	if len(history) == 0 {
		t.Fatal("expected delivery history for the phase's envelope, got none — SaveEnvelope is not wired through DeliverEnvelope")
	}
	last := history[len(history)-1]
	if last.State != "delivered" {
		t.Errorf("expected final delivery state 'delivered', got %q", last.State)
	}
}

// R5.2: envelopes published within one run form a causation chain. The first
// envelope of a run has no cause; a later one names the previous envelope as
// its cause. This exercises RunAgentPhase itself, not just the store, because
// the store-level plumbing can be correct while every real call site still
// leaves CausationID nil.
func TestAgentPhaseEnvelopesChainCausation(t *testing.T) {
	dir := t.TempDir()
	agent := fakeAgent(t, dir, "agent.sh", "echo done")
	pr, st := newRunner(t, agent, 10*time.Second)

	first, _, err := pr.RunAgentPhase(context.Background(), "build", "brief", 0)
	if err != nil {
		t.Fatalf("unexpected error on first phase: %v", err)
	}
	second, _, err := pr.RunAgentPhase(context.Background(), "test", "brief", 0)
	if err != nil {
		t.Fatalf("unexpected error on second phase: %v", err)
	}
	_ = first
	_ = second

	envs, err := st.ListEnvelopesForRun("run-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(envs) != 2 {
		t.Fatalf("expected 2 envelopes, got %d", len(envs))
	}
	if envs[0].CausationID != nil {
		t.Errorf("first envelope CausationID = %v, want nil (absent)", envs[0].CausationID)
	}
	if envs[1].CausationID == nil || *envs[1].CausationID != envs[0].ID {
		t.Errorf("second envelope CausationID = %v, want pointer to %q", envs[1].CausationID, envs[0].ID)
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
	_, _, err := pr.RunAgentPhase(ctx, "build", "do the thing", 0)
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("RunAgentPhase returned nil error after cancellation, want a cancellation error")
	}
	if elapsed > 10*time.Second {
		t.Errorf("cancellation took %v; an unbounded phase ignored the parent context", elapsed)
	}
	_ = st
}

// --- R2.4: attempt number on phase records -----------------------------------

// Each attempt must produce a phase record with an attempt number starting at 1
// and increasing by 1 with no gaps.
func TestAttemptNumberStartsAtOneAndIncrements(t *testing.T) {
	dir := t.TempDir()
	agent := fakeAgent(t, dir, "agent.sh", "exit 1") // always fails
	pr, st := newRunner(t, agent, 10*time.Second)

	// 2 retries = 3 attempts total
	_, _, _ = pr.RunAgentPhase(context.Background(), "build", "brief", 2)

	phases, err := st.ListPhasesForRun("run-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(phases) != 3 {
		t.Fatalf("expected 3 phase records, got %d", len(phases))
	}
	for i, p := range phases {
		want := i + 1
		if p.Attempt != want {
			t.Errorf("phases[%d].Attempt = %d, want %d", i, p.Attempt, want)
		}
	}
}

// A phase that fails then succeeds must leave BOTH a failed and a passed record
// with different attempt numbers. Collapsing them hides that a retry happened.
func TestRetryKeepsBothFailedAndPassedRecord(t *testing.T) {
	dir := t.TempDir()

	// Script fails on attempt 1, passes on attempt 2 by counting invocations via a file.
	countFile := filepath.Join(dir, "count")
	script := `#!/bin/sh
COUNT=0
if [ -f "` + countFile + `" ]; then COUNT=$(cat "` + countFile + `"); fi
COUNT=$((COUNT+1))
echo $COUNT > "` + countFile + `"
if [ "$COUNT" -lt 2 ]; then exit 1; fi
exit 0`
	agent := fakeAgent(t, dir, "agent.sh", script[len("#!/bin/sh\n"):])
	// Rewrite fully (fakeAgent prepends #!/bin/sh):
	if err := os.WriteFile(agent, []byte(script), 0755); err != nil {
		t.Fatal(err)
	}

	pr, st := newRunner(t, agent, 10*time.Second)

	env, _, err := pr.RunAgentPhase(context.Background(), "build", "brief", 1)
	if err != nil {
		t.Fatalf("expected success on retry, got: %v", err)
	}
	if env == nil {
		t.Fatal("expected an envelope on success")
	}

	phases, err := st.ListPhasesForRun("run-1")
	if err != nil {
		t.Fatal(err)
	}
	// Filter to "build" agent phases only (skip initial "running" record)
	var buildPhases []store.PhaseRecord
	for _, p := range phases {
		if p.Name == "build" && p.Kind == "agent" && p.Status != "running" {
			buildPhases = append(buildPhases, p)
		}
	}
	if len(buildPhases) != 2 {
		t.Fatalf("expected 2 build phase records (failed + passed), got %d: %+v", len(buildPhases), buildPhases)
	}
	if buildPhases[0].Status != "failed" {
		t.Errorf("first record status = %q, want failed", buildPhases[0].Status)
	}
	if buildPhases[1].Status != "passed" {
		t.Errorf("second record status = %q, want passed", buildPhases[1].Status)
	}
	if buildPhases[0].Attempt == buildPhases[1].Attempt {
		t.Errorf("both records have the same attempt number %d; they must differ", buildPhases[0].Attempt)
	}
	if buildPhases[0].Attempt != 1 {
		t.Errorf("first record Attempt = %d, want 1", buildPhases[0].Attempt)
	}
	if buildPhases[1].Attempt != 2 {
		t.Errorf("second record Attempt = %d, want 2", buildPhases[1].Attempt)
	}
}

// A successful first-attempt phase must record Attempt=1.
func TestSuccessfulFirstAttemptIsAttemptOne(t *testing.T) {
	dir := t.TempDir()
	agent := fakeAgent(t, dir, "agent.sh", "echo done")
	pr, st := newRunner(t, agent, 10*time.Second)

	_, _, err := pr.RunAgentPhase(context.Background(), "build", "brief", 0)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	phases, err := st.ListPhasesForRun("run-1")
	if err != nil {
		t.Fatal(err)
	}
	var final []store.PhaseRecord
	for _, p := range phases {
		if p.Name == "build" && p.Kind == "agent" && p.Status != "running" {
			final = append(final, p)
		}
	}
	if len(final) != 1 {
		t.Fatalf("expected 1 phase record, got %d", len(final))
	}
	if final[0].Attempt != 1 {
		t.Errorf("Attempt = %d, want 1", final[0].Attempt)
	}
}

// --- R4.6: phases record their model and provider ---------------------------

func payloadProvenance(t *testing.T, payload json.RawMessage) (model, provider string) {
	t.Helper()
	var m map[string]interface{}
	if err := json.Unmarshal(payload, &m); err != nil {
		t.Fatalf("payload is not valid JSON: %v (payload: %s)", err, payload)
	}
	modelVal, _ := m["model"].(string)
	providerVal, _ := m["provider"].(string)
	return modelVal, providerVal
}

// A goose phase whose raw output contains the startup banner records the
// provider and model it names, even though sergeant synthesized the envelope
// (the fake agent here writes no envelope.json of its own).
func TestGooseAgentPhaseRecordsModelAndProvider(t *testing.T) {
	dir := t.TempDir()
	agent := fakeAgent(t, dir, "goose", "echo '● new session · anthropic claude-sonnet-4-6'")
	pr, st := newRunner(t, agent, 10*time.Second)

	env, _, err := pr.RunAgentPhase(context.Background(), "build", "brief", 0)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if env == nil {
		t.Fatal("expected an envelope")
	}

	model, provider := payloadProvenance(t, env.Payload)
	if model != "claude-sonnet-4-6" || provider != "anthropic" {
		t.Errorf("envelope payload model/provider = %q/%q, want claude-sonnet-4-6/anthropic", model, provider)
	}

	phases, err := st.ListPhasesForRun("run-1")
	if err != nil {
		t.Fatal(err)
	}
	var final []store.PhaseRecord
	for _, p := range phases {
		if p.Name == "build" && p.Kind == "agent" && p.Status != "running" {
			final = append(final, p)
		}
	}
	if len(final) != 1 {
		t.Fatalf("expected 1 phase record, got %d", len(final))
	}
	model, provider = payloadProvenance(t, final[0].Payload)
	if model != "claude-sonnet-4-6" || provider != "anthropic" {
		t.Errorf("phase record model/provider = %q/%q, want claude-sonnet-4-6/anthropic", model, provider)
	}
}

// claude never prints a parseable provenance banner the way goose does, but
// its provider is still a real, derivable fact (not a guess): which backend
// it talks to is an environment fact (CLAUDE_CODE_USE_BEDROCK/_VERTEX), and
// which model it used is exactly whatever was requested via --model, known
// to the caller already. Default environment (neither flag set) is
// Anthropic directly.
func TestClaudeAgentPhaseRecordsAnthropicProviderAndRequestedModel(t *testing.T) {
	dir := t.TempDir()
	agent := fakeAgent(t, dir, "claude", "exit 0")
	pr, st := newRunner(t, agent, 10*time.Second)
	pr.Model = "claude-sonnet-4-6"

	env, _, err := pr.RunAgentPhase(context.Background(), "build", "brief", 0)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	model, provider := payloadProvenance(t, env.Payload)
	if model != "claude-sonnet-4-6" || provider != "anthropic" {
		t.Errorf("envelope payload model/provider = %q/%q, want claude-sonnet-4-6/anthropic", model, provider)
	}

	phases, err := st.ListPhasesForRun("run-1")
	if err != nil {
		t.Fatal(err)
	}
	var final []store.PhaseRecord
	for _, p := range phases {
		if p.Name == "build" && p.Kind == "agent" && p.Status != "running" {
			final = append(final, p)
		}
	}
	if len(final) != 1 {
		t.Fatalf("expected 1 phase record, got %d", len(final))
	}
	model, provider = payloadProvenance(t, final[0].Payload)
	if model != "claude-sonnet-4-6" || provider != "anthropic" {
		t.Errorf("phase record model/provider = %q/%q, want claude-sonnet-4-6/anthropic", model, provider)
	}
}

// A claude dispatch with no explicit --model still has a known provider
// (an environment fact), but the specific model claude chose on its own is
// genuinely unknown to sergeant — recording one would be exactly the guess
// TestUnparsedAgentProvenanceIsEmptyNotGuessed already forbids for other
// agents.
func TestClaudeAgentWithNoRequestedModelLeavesModelEmpty(t *testing.T) {
	dir := t.TempDir()
	agent := fakeAgent(t, dir, "claude", "exit 0")
	pr, _ := newRunner(t, agent, 10*time.Second)
	// pr.Model left at its zero value: no --model was requested.

	env, _, err := pr.RunAgentPhase(context.Background(), "build", "brief", 0)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	model, provider := payloadProvenance(t, env.Payload)
	if model != "" {
		t.Errorf("model = %q, want empty — no --model was requested, so the actual model claude chose is unknown", model)
	}
	if provider != "anthropic" {
		t.Errorf("provider = %q, want anthropic — the backend is a known environment fact regardless of which model was requested", provider)
	}
}

// CLAUDE_CODE_USE_BEDROCK/CLAUDE_CODE_USE_VERTEX route claude through AWS/GCP
// instead of Anthropic directly. claude subprocesses inherit this process's
// environment (BuildAgentCommand sets no override for claude), so these are
// exactly the variables the real CLI itself reads to decide.
func TestClaudeAgentPhaseRecordsBedrockOrVertexProviderWhenConfigured(t *testing.T) {
	cases := []struct {
		envVar       string
		wantProvider string
	}{
		{"CLAUDE_CODE_USE_BEDROCK", "bedrock"},
		{"CLAUDE_CODE_USE_VERTEX", "vertex"},
	}
	for _, tc := range cases {
		t.Run(tc.wantProvider, func(t *testing.T) {
			t.Setenv(tc.envVar, "1")
			dir := t.TempDir()
			agent := fakeAgent(t, dir, "claude", "exit 0")
			pr, _ := newRunner(t, agent, 10*time.Second)

			env, _, err := pr.RunAgentPhase(context.Background(), "build", "brief", 0)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			_, provider := payloadProvenance(t, env.Payload)
			if provider != tc.wantProvider {
				t.Errorf("provider = %q, want %q with %s=1", provider, tc.wantProvider, tc.envVar)
			}
		})
	}
}

// An agent this project has no output parser for must never guess: its
// phase's model/provider are empty, even when the raw output happens to
// contain text that looks like goose's banner.
func TestUnparsedAgentProvenanceIsEmptyNotGuessed(t *testing.T) {
	dir := t.TempDir()
	agent := fakeAgent(t, dir, "opencode", "echo '● new session · anthropic claude-sonnet-4-6'")
	pr, st := newRunner(t, agent, 10*time.Second)

	env, _, err := pr.RunAgentPhase(context.Background(), "build", "brief", 0)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	model, provider := payloadProvenance(t, env.Payload)
	if model != "" || provider != "" {
		t.Errorf("envelope payload model/provider = %q/%q, want empty/empty for an unparsed agent", model, provider)
	}

	phases, err := st.ListPhasesForRun("run-1")
	if err != nil {
		t.Fatal(err)
	}
	var final []store.PhaseRecord
	for _, p := range phases {
		if p.Name == "build" && p.Kind == "agent" && p.Status != "running" {
			final = append(final, p)
		}
	}
	if len(final) != 1 {
		t.Fatalf("expected 1 phase record, got %d", len(final))
	}
	model, provider = payloadProvenance(t, final[0].Payload)
	if model != "" || provider != "" {
		t.Errorf("phase record model/provider = %q/%q, want empty/empty for an unparsed agent", model, provider)
	}
}

// A successful phase whose envelope was written by the agent itself (not
// synthesized by sergeant) must still carry model/provider — provenance is
// attached after both env-building branches converge, not only inside the
// synthesized one.
func TestAgentAuthoredEnvelopeStillGetsProvenance(t *testing.T) {
	dir := t.TempDir()
	script := `#!/bin/sh
echo '` + "●" + ` new session ` + "·" + ` anthropic claude-sonnet-4-6'
mkdir -p .sergeant
cat > .sergeant/envelope.json <<'EOF'
{"task_id":"run-1","repo":"svc","stage":"build","summary":"agent authored this envelope","payload":{"custom":"value"}}
EOF
exit 0
`
	agent := filepath.Join(dir, "goose")
	if err := os.WriteFile(agent, []byte(script), 0755); err != nil {
		t.Fatal(err)
	}
	pr, st := newRunner(t, agent, 10*time.Second)

	env, _, err := pr.RunAgentPhase(context.Background(), "build", "brief", 0)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if env == nil {
		t.Fatal("expected an envelope")
	}
	if env.Summary != "agent authored this envelope" {
		t.Fatalf("envelope was not read from the agent-authored envelope.json: %+v", env)
	}

	var payloadMap map[string]interface{}
	if err := json.Unmarshal(env.Payload, &payloadMap); err != nil {
		t.Fatalf("payload is not valid JSON: %v", err)
	}
	if payloadMap["custom"] != "value" {
		t.Errorf("agent-authored payload fields were lost; got %+v", payloadMap)
	}
	model, provider := payloadProvenance(t, env.Payload)
	if model != "claude-sonnet-4-6" || provider != "anthropic" {
		t.Errorf("agent-authored envelope model/provider = %q/%q, want claude-sonnet-4-6/anthropic", model, provider)
	}

	phases, err := st.ListPhasesForRun("run-1")
	if err != nil {
		t.Fatal(err)
	}
	var final []store.PhaseRecord
	for _, p := range phases {
		if p.Name == "build" && p.Kind == "agent" && p.Status != "running" {
			final = append(final, p)
		}
	}
	if len(final) != 1 {
		t.Fatalf("expected 1 phase record, got %d", len(final))
	}
	model, provider = payloadProvenance(t, final[0].Payload)
	if model != "claude-sonnet-4-6" || provider != "anthropic" {
		t.Errorf("phase record model/provider = %q/%q, want claude-sonnet-4-6/anthropic", model, provider)
	}
}

// An agent-authored envelope.json is not built by sergeant field-by-field,
// so it is never redacted at the point of construction the way a synthesized
// envelope's raw_output is. A secret the agent writes into its own summary
// or payload must still be redacted before it reaches the returned envelope
// or any persisted record — closing that gap is not optional just because
// sergeant did not write the content itself.
func TestAgentAuthoredEnvelopeIsRedacted(t *testing.T) {
	dir := t.TempDir()
	secret := "sk-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOP"
	script := `#!/bin/sh
mkdir -p .sergeant
cat > .sergeant/envelope.json <<EOF
{"task_id":"run-1","repo":"svc","stage":"build","summary":"leaked ` + secret + `","payload":{"nested":{"note":"` + secret + `"}}}
EOF
exit 0
`
	agent := filepath.Join(dir, "goose")
	if err := os.WriteFile(agent, []byte(script), 0755); err != nil {
		t.Fatal(err)
	}
	pr, st := newRunner(t, agent, 10*time.Second)

	env, _, err := pr.RunAgentPhase(context.Background(), "build", "brief", 0)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if strings.Contains(env.Summary, secret) {
		t.Errorf("returned envelope Summary leaked the secret: %q", env.Summary)
	}
	if !strings.Contains(env.Summary, "[REDACTED]") {
		t.Errorf("returned envelope Summary was not redacted: %q", env.Summary)
	}
	if strings.Contains(string(env.Payload), secret) {
		t.Errorf("returned envelope Payload leaked the secret: %s", env.Payload)
	}
	if !strings.Contains(string(env.Payload), "[REDACTED]") {
		t.Errorf("returned envelope Payload was not redacted: %s", env.Payload)
	}

	phases, err := st.ListPhasesForRun("run-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(phases) != 1 {
		t.Fatalf("expected 1 phase record, got %d", len(phases))
	}
	if strings.Contains(string(phases[0].Payload), secret) {
		t.Errorf("persisted PhaseRecord.Payload leaked the secret: %s", phases[0].Payload)
	}

	envelopes, err := st.ListEnvelopesForRun("run-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(envelopes) != 1 {
		t.Fatalf("expected 1 envelope record, got %d", len(envelopes))
	}
	if strings.Contains(string(envelopes[0].Data), secret) {
		t.Errorf("persisted EnvelopeRecord.Data leaked the secret: %s", envelopes[0].Data)
	}
}

// D5(b): an agent can explain why it could not proceed via a blocked_reason
// key nested in its envelope's own payload — not a new top-level Envelope
// field, so it inherits payload redaction rather than needing its own
// call site (design.md, "Where the reason comes from"). RunAgentPhase makes
// that reason available to its caller alongside the envelope and error.
func TestRunAgentPhaseReturnsAgentReportedBlockedReason(t *testing.T) {
	dir := t.TempDir()
	script := `#!/bin/sh
mkdir -p .sergeant
cat > .sergeant/envelope.json <<'EOF'
{"task_id":"run-1","repo":"svc","stage":"build","summary":"could not proceed","payload":{"blocked_reason":"requirement is ambiguous; needs a human decision"}}
EOF
exit 0
`
	agent := filepath.Join(dir, "goose")
	if err := os.WriteFile(agent, []byte(script), 0755); err != nil {
		t.Fatal(err)
	}
	pr, _ := newRunner(t, agent, 10*time.Second)

	_, blockedReason, err := pr.RunAgentPhase(context.Background(), "build", "brief", 0)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if blockedReason != "requirement is ambiguous; needs a human decision" {
		t.Errorf("blockedReason = %q, want the agent-reported reason verbatim", blockedReason)
	}
}

// An agent that names no blocked_reason gives RunAgentPhase nothing to
// report: the second return is "", not a guess.
func TestRunAgentPhaseReturnsNoBlockedReasonWhenAgentNamesNone(t *testing.T) {
	dir := t.TempDir()
	agent := fakeAgent(t, dir, "agent.sh", "echo done")
	pr, _ := newRunner(t, agent, 10*time.Second)

	_, blockedReason, err := pr.RunAgentPhase(context.Background(), "build", "brief", 0)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if blockedReason != "" {
		t.Errorf("blockedReason = %q, want empty for an envelope that named none", blockedReason)
	}
}

// R4.4: blocked_reason is read out of env.Payload after redact.JSON has
// already run over it, so a secret-shaped reason must come back redacted,
// the same as every other payload field.
func TestRunAgentPhaseRedactsTheReturnedBlockedReason(t *testing.T) {
	dir := t.TempDir()
	secret := "sk-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOP"
	script := `#!/bin/sh
mkdir -p .sergeant
cat > .sergeant/envelope.json <<EOF
{"task_id":"run-1","repo":"svc","stage":"build","summary":"could not proceed","payload":{"blocked_reason":"needs a key: ` + secret + `"}}
EOF
exit 0
`
	agent := filepath.Join(dir, "goose")
	if err := os.WriteFile(agent, []byte(script), 0755); err != nil {
		t.Fatal(err)
	}
	pr, _ := newRunner(t, agent, 10*time.Second)

	_, blockedReason, err := pr.RunAgentPhase(context.Background(), "build", "brief", 0)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if strings.Contains(blockedReason, secret) {
		t.Errorf("returned blockedReason leaked the secret: %q", blockedReason)
	}
	if !strings.Contains(blockedReason, "[REDACTED]") {
		t.Errorf("returned blockedReason was not redacted: %q", blockedReason)
	}
}

// An agent-authored envelope's Artifacts field must be redacted before
// pr.Router.SaveEnvelope writes it to the handoff file on disk, not only
// before pr.Store.RecordEnvelope — SaveEnvelope runs first, and
// internal/dag.Engine commits that file into downstream worktrees. Checking
// only the returned envelope or the DB row (as TestAgentAuthoredEnvelopeIsRedacted
// does) would miss this: RecordEnvelope's own redaction mutates the same
// backing array env.Artifacts already points to, after the unredacted bytes
// were already on disk (Review 018).
func TestAgentAuthoredEnvelopeArtifactsAreRedactedBeforeDiskWrite(t *testing.T) {
	dir := t.TempDir()
	secret := "sk-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOP"
	script := `#!/bin/sh
mkdir -p .sergeant
cat > .sergeant/envelope.json <<EOF
{"task_id":"run-1","repo":"svc","stage":"build","summary":"ok","artifacts":["API_KEY=` + secret + `"],"payload":{}}
EOF
exit 0
`
	agent := filepath.Join(dir, "goose")
	if err := os.WriteFile(agent, []byte(script), 0755); err != nil {
		t.Fatal(err)
	}
	pr, st := newRunner(t, agent, 10*time.Second)

	env, _, err := pr.RunAgentPhase(context.Background(), "build", "brief", 0)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	for _, a := range env.Artifacts {
		if strings.Contains(a, secret) {
			t.Errorf("returned envelope Artifacts leaked the secret: %q", a)
		}
	}

	handoffFile := filepath.Join(pr.Worktree, "handoff", "svc", "envelope_build.json")
	onDisk, err := os.ReadFile(handoffFile)
	if err != nil {
		t.Fatalf("reading handoff file: %v", err)
	}
	if strings.Contains(string(onDisk), secret) {
		t.Errorf("handoff file on disk leaked the secret: %s", onDisk)
	}
	if !strings.Contains(string(onDisk), "[REDACTED]") {
		t.Errorf("handoff file on disk was not redacted: %s", onDisk)
	}

	envelopes, err := st.ListEnvelopesForRun("run-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(envelopes) != 1 {
		t.Fatalf("expected 1 envelope record, got %d", len(envelopes))
	}
	for _, a := range envelopes[0].Artifacts {
		if strings.Contains(a, secret) {
			t.Errorf("persisted EnvelopeRecord.Artifacts leaked the secret: %q", a)
		}
	}
}

// A goose phase whose output has no banner (malformed or missing) completes
// exactly as it would without provenance parsing: the phase still passes, and
// model/provider are empty rather than a guess.
func TestBannerlessGooseOutputDoesNotFailPhase(t *testing.T) {
	dir := t.TempDir()
	agent := fakeAgent(t, dir, "goose", "echo 'not a recognisable banner at all'")
	pr, st := newRunner(t, agent, 10*time.Second)

	env, _, err := pr.RunAgentPhase(context.Background(), "build", "brief", 0)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if env == nil {
		t.Fatal("expected an envelope")
	}

	model, provider := payloadProvenance(t, env.Payload)
	if model != "" || provider != "" {
		t.Errorf("envelope payload model/provider = %q/%q, want empty/empty for banner-less output", model, provider)
	}

	phases, err := st.ListPhasesForRun("run-1")
	if err != nil {
		t.Fatal(err)
	}
	var final []store.PhaseRecord
	for _, p := range phases {
		if p.Name == "build" && p.Kind == "agent" {
			final = append(final, p)
		}
	}
	if len(final) != 1 || final[0].Status != "passed" {
		t.Fatalf("expected 1 passed phase, got %+v", final)
	}
}

// --- output-redaction-and-bounded: R4.4/R4.5 -------------------------------

// A fake agent that prints a secret-shaped string must never leak it into
// the persisted PhaseRecord or EnvelopeRecord payload. This exercises the
// real RunAgentPhase call site, not just redact.Text/Truncate in isolation:
// a pure-function guarantee that is never wired into production output is no
// guarantee at all.
func TestRunAgentPhaseRedactsSecretsFromPersistedRecords(t *testing.T) {
	dir := t.TempDir()
	secret := "sk-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOP"
	agent := fakeAgent(t, dir, "agent.sh", "echo 'API_KEY="+secret+"'")
	pr, st := newRunner(t, agent, 10*time.Second)

	env, _, err := pr.RunAgentPhase(context.Background(), "build", "brief", 0)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if env == nil {
		t.Fatal("expected an envelope")
	}
	if strings.Contains(string(env.Payload), secret) {
		t.Errorf("returned envelope payload leaked the secret: %s", env.Payload)
	}
	if !strings.Contains(string(env.Payload), "[REDACTED]") {
		t.Errorf("returned envelope payload was not redacted: %s", env.Payload)
	}

	phases, err := st.ListPhasesForRun("run-1")
	if err != nil {
		t.Fatal(err)
	}
	var final []store.PhaseRecord
	for _, p := range phases {
		if p.Name == "build" && p.Kind == "agent" && p.Status != "running" {
			final = append(final, p)
		}
	}
	if len(final) != 1 {
		t.Fatalf("expected 1 phase record, got %d", len(final))
	}
	if strings.Contains(string(final[0].Payload), secret) {
		t.Errorf("persisted PhaseRecord.Payload leaked the secret: %s", final[0].Payload)
	}
	if !strings.Contains(string(final[0].Payload), "[REDACTED]") {
		t.Errorf("persisted PhaseRecord.Payload was not redacted: %s", final[0].Payload)
	}

	envs, err := st.ListEnvelopesForRun("run-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(envs) != 1 {
		t.Fatalf("expected 1 envelope record, got %d", len(envs))
	}
	if strings.Contains(string(envs[0].Data), secret) {
		t.Errorf("persisted EnvelopeRecord.Data leaked the secret: %s", envs[0].Data)
	}
	if !strings.Contains(string(envs[0].Data), "[REDACTED]") {
		t.Errorf("persisted EnvelopeRecord.Data was not redacted: %s", envs[0].Data)
	}
}

// The same guarantee for RunCodeGate: a gate command that prints a
// secret-shaped string must not leak it into the persisted PhaseRecord.
func TestRunCodeGateRedactsSecretsFromPersistedRecords(t *testing.T) {
	tempDir := t.TempDir()
	st, err := store.Open(filepath.Join(tempDir, "test.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer st.Close()
	if err := st.CreateRun(&store.RunRecord{ID: "run-1", Project: "p", TaskID: "run-1", Status: "running"}); err != nil {
		t.Fatal(err)
	}

	router := handoff.NewRouter(filepath.Join(tempDir, "handoff"))
	pr := &PhaseRunner{
		Store:    st,
		Router:   router,
		Worktree: tempDir,
		RepoName: "backend",
		RunID:    "run-1",
	}

	secret := "AKIAIOSFODNN7EXAMPLE"
	res, err := pr.RunCodeGate(context.Background(), "secret-gate", "echo 'AWS_CREDENTIAL="+secret+"'")
	if err != nil {
		t.Fatalf("RunCodeGate error: %v", err)
	}
	if strings.Contains(res.Output, secret) {
		t.Errorf("GateResult.Output leaked the secret: %q", res.Output)
	}
	if !strings.Contains(res.Output, "[REDACTED]") {
		t.Errorf("GateResult.Output was not redacted: %q", res.Output)
	}

	phases, err := st.ListPhasesForRun("run-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(phases) != 1 {
		t.Fatalf("expected 1 phase record, got %d", len(phases))
	}
	if strings.Contains(string(phases[0].Payload), secret) {
		t.Errorf("persisted PhaseRecord.Payload leaked the secret: %s", phases[0].Payload)
	}
	if !strings.Contains(string(phases[0].Payload), "[REDACTED]") {
		t.Errorf("persisted PhaseRecord.Payload was not redacted: %s", phases[0].Payload)
	}
}

// A failing gate builds PhaseRecord.Error from a second, independent read of
// the raw output buffer (to prefix it with the exec error) — that read must
// reuse the already-redacted/bounded value, not the raw buffer a second
// time, or the guarantee GateResult.Output enforces is bypassed for Error.
func TestRunCodeGateRedactsSecretsFromFailureError(t *testing.T) {
	tempDir := t.TempDir()
	st, err := store.Open(filepath.Join(tempDir, "test.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer st.Close()
	if err := st.CreateRun(&store.RunRecord{ID: "run-1", Project: "p", TaskID: "run-1", Status: "running"}); err != nil {
		t.Fatal(err)
	}

	router := handoff.NewRouter(filepath.Join(tempDir, "handoff"))
	pr := &PhaseRunner{
		Store:    st,
		Router:   router,
		Worktree: tempDir,
		RepoName: "backend",
		RunID:    "run-1",
	}

	secret := "AKIAIOSFODNN7EXAMPLE"
	res, err := pr.RunCodeGate(context.Background(), "secret-gate", "echo 'AWS_CREDENTIAL="+secret+"'; exit 1")
	if err != nil {
		t.Fatalf("RunCodeGate error: %v", err)
	}
	if res.Passed {
		t.Fatal("expected the gate to fail")
	}

	phases, err := st.ListPhasesForRun("run-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(phases) != 1 {
		t.Fatalf("expected 1 phase record, got %d", len(phases))
	}
	if strings.Contains(phases[0].Error, secret) {
		t.Errorf("persisted PhaseRecord.Error leaked the secret: %q", phases[0].Error)
	}
	if !strings.Contains(phases[0].Error, "[REDACTED]") {
		t.Errorf("persisted PhaseRecord.Error was not redacted: %q", phases[0].Error)
	}
}

// A gate/agent whose output exceeds maxRawOutputBytes must be truncated with
// a visible marker before it is persisted, exercised at the real call sites.
func TestRunCodeGateBoundsOutputSize(t *testing.T) {
	tempDir := t.TempDir()
	st, err := store.Open(filepath.Join(tempDir, "test.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer st.Close()
	if err := st.CreateRun(&store.RunRecord{ID: "run-1", Project: "p", TaskID: "run-1", Status: "running"}); err != nil {
		t.Fatal(err)
	}

	router := handoff.NewRouter(filepath.Join(tempDir, "handoff"))
	pr := &PhaseRunner{
		Store:    st,
		Router:   router,
		Worktree: tempDir,
		RepoName: "backend",
		RunID:    "run-1",
	}

	// Print well over maxRawOutputBytes of output.
	res, err := pr.RunCodeGate(context.Background(), "big-gate", "yes | head -c 200000")
	if err != nil {
		t.Fatalf("RunCodeGate error: %v", err)
	}
	if len(res.Output) >= 200000 {
		t.Errorf("GateResult.Output was not bounded: got %d bytes", len(res.Output))
	}
	if !strings.Contains(res.Output, "bytes cut") && !strings.Contains(res.Output, "TRUNCATED") {
		t.Errorf("GateResult.Output has no visible truncation marker: last 100 bytes: %q", res.Output[len(res.Output)-100:])
	}
}

// detectModelProvider must never panic, regardless of agent name or output shape.
func TestDetectModelProviderNeverPanics(t *testing.T) {
	cases := []struct {
		agentExe string
		output   string
	}{
		{"", ""},
		{"goose", ""},
		{"goose", "garbage \x00\xff bytes"},
		{"/usr/local/bin/goose", "● new session · anthropic claude-sonnet-4-6"},
		{"claude", "● new session · anthropic claude-sonnet-4-6"},
	}
	for _, tc := range cases {
		func() {
			defer func() {
				if r := recover(); r != nil {
					t.Errorf("detectModelProvider(%q, %q) panicked: %v", tc.agentExe, tc.output, r)
				}
			}()
			_, _ = detectModelProvider(tc.agentExe, tc.output, "")
		}()
	}
}

// annotatePayloadWithProvenance must leave a non-object payload unchanged
// rather than error or panic.
func TestAnnotatePayloadWithProvenanceLeavesNonObjectPayloadUnchanged(t *testing.T) {
	cases := []json.RawMessage{
		nil,
		json.RawMessage(``),
		json.RawMessage(`not json`),
		json.RawMessage(`[1,2,3]`),
		json.RawMessage(`"a string"`),
	}
	for _, payload := range cases {
		got := annotatePayloadWithProvenance(payload, "some-model", "some-provider")
		if string(got) != string(payload) {
			t.Errorf("annotatePayloadWithProvenance(%q, ...) = %q, want unchanged", payload, got)
		}
	}
}

// annotatePayloadWithProvenance sets model/provider even when both are empty
// strings — an explicit empty is the honest "not knowable" signal, distinct
// from the key being absent.
func TestAnnotatePayloadWithProvenanceSetsEmptyKeysExplicitly(t *testing.T) {
	got := annotatePayloadWithProvenance(json.RawMessage(`{"agent":"opencode"}`), "", "")
	var m map[string]interface{}
	if err := json.Unmarshal(got, &m); err != nil {
		t.Fatalf("result is not valid JSON: %v", err)
	}
	modelVal, hasModel := m["model"]
	providerVal, hasProvider := m["provider"]
	if !hasModel || modelVal != "" {
		t.Errorf("model = %v (present=%v), want present and empty", modelVal, hasModel)
	}
	if !hasProvider || providerVal != "" {
		t.Errorf("provider = %v (present=%v), want present and empty", providerVal, hasProvider)
	}
	if m["agent"] != "opencode" {
		t.Errorf("existing key was lost: %+v", m)
	}
}

// A payload of JSON null unmarshals successfully into a nil map; assigning
// into it must not panic.
func TestAnnotatePayloadWithProvenanceHandlesJSONNull(t *testing.T) {
	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("annotatePayloadWithProvenance panicked on JSON null payload: %v", r)
		}
	}()
	got := annotatePayloadWithProvenance(json.RawMessage(`null`), "m", "p")
	model, provider := payloadProvenance(t, got)
	if model != "m" || provider != "p" {
		t.Errorf("model/provider = %q/%q, want m/p", model, provider)
	}
}

// --- independent-review: DiffAgainstBase ------------------------------------

// DiffAgainstBase feeds a review phase's prompt. A clean worktree has
// nothing to review; an uncommitted change must show up as the diff.
func TestDiffAgainstBaseReturnsUncommittedChanges(t *testing.T) {
	dir := t.TempDir()
	runGit(t, dir, "init", "-q", "-b", "main")
	runGit(t, dir, "commit", "--allow-empty", "-q", "-m", "seed")

	pr := &PhaseRunner{Worktree: dir}

	diff, err := pr.DiffAgainstBase(context.Background())
	if err != nil {
		t.Fatalf("DiffAgainstBase on a clean worktree: %v", err)
	}
	if diff != "" {
		t.Errorf("diff = %q, want empty for a clean worktree", diff)
	}

	if err := os.WriteFile(filepath.Join(dir, "feature.go"), []byte("package feature\n"), 0644); err != nil {
		t.Fatal(err)
	}
	runGit(t, dir, "add", "feature.go")

	diff, err = pr.DiffAgainstBase(context.Background())
	if err != nil {
		t.Fatalf("DiffAgainstBase with an uncommitted change: %v", err)
	}
	if !strings.Contains(diff, "feature.go") {
		t.Errorf("diff = %q, want it to mention feature.go", diff)
	}
	if !strings.Contains(diff, "package feature") {
		t.Errorf("diff = %q, want it to contain the added content", diff)
	}
}

func TestDiffAgainstBaseErrorsOutsideAGitRepo(t *testing.T) {
	dir := t.TempDir() // not a git repository

	pr := &PhaseRunner{Worktree: dir}
	if _, err := pr.DiffAgainstBase(context.Background()); err == nil {
		t.Fatal("expected an error diffing outside a git repository, got nil")
	}
}

// --- independent-review: findings survive the envelope-recording path -----

// Scenario: "Recorded findings are readable after the run concludes." A
// review agent's findings must round-trip through the same
// RunAgentPhase -> Store.RecordEnvelope path every other phase already uses,
// not just via a hand-built in-memory struct.
func TestReviewFindingsRoundTripThroughRunAgentPhase(t *testing.T) {
	dir := t.TempDir()
	script := `#!/bin/sh
mkdir -p .sergeant
cat > .sergeant/envelope.json <<'EOF'
{"task_id":"run-1","repo":"svc","stage":"review","summary":"reviewed the diff","payload":{"findings":[{"axis":"spec","severity":"error","summary":"missing failing test","disposition":"add one"},{"axis":"style","severity":"info","summary":"consider renaming x","disposition":"optional"}]}}
EOF
exit 0
`
	agent := filepath.Join(dir, "goose")
	if err := os.WriteFile(agent, []byte(script), 0755); err != nil {
		t.Fatal(err)
	}
	pr, st := newRunner(t, agent, 10*time.Second)

	env, _, err := pr.RunAgentPhase(context.Background(), "review", "review this diff", 0)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if env == nil {
		t.Fatal("expected an envelope")
	}

	envelopes, err := st.ListEnvelopesForRun("run-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(envelopes) != 1 {
		t.Fatalf("expected 1 persisted envelope, got %d", len(envelopes))
	}

	findings := handoff.ReviewFindings(envelopes[0].Data)
	if len(findings) != 2 {
		t.Fatalf("findings read back from the persisted envelope = %+v, want 2", findings)
	}
	if !handoff.HasBlockingFinding(findings) {
		t.Error("expected the persisted findings to still carry the blocking severity:error entry")
	}
	if findings[0].Summary != "missing failing test" || findings[1].Summary != "consider renaming x" {
		t.Errorf("findings = %+v, want summaries preserved in order", findings)
	}
}
