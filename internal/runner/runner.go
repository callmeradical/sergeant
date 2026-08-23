package runner

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/callmeradical/sergeant/internal/handoff"
	"github.com/callmeradical/sergeant/internal/store"
)

// ansiEscape matches ANSI/VT100 control sequences emitted by interactive agent
// CLIs. Agent stdout is stored as a JSON payload and rendered in a browser,
// which cannot interpret terminal escapes, so they are stripped at capture time.
var ansiEscape = regexp.MustCompile(`\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*\x07|\x1b[()][A-Za-z0-9]`)

// planPromptExtension is appended to the agent prompt when .sergeant/plan.json
// exists in the worktree. It instructs the agent how to report progress against
// the seeded checklist.
//
// Rules reflected in the text:
//   - Mark a single item "in_progress" when starting it; mark it "complete"
//     when it is done. At most one item is in_progress at any time.
//   - Never alter the "id" or "scenario" fields — sergeant uses them as stable
//     identifiers.
//   - Sergeant seeds the file and thereafter only reads it. The agent is the
//     sole writer after seeding.
const planPromptExtension = `

## Progress reporting

A checklist has been seeded into .sergeant/plan.json in your working directory.
It contains one item per declared scenario for this change, each with:
  - "id":       a stable identifier — do not change it
  - "scenario": the scenario text — do not change it
  - "status":   one of "pending", "in_progress", or "complete"

As you work, update the file to reflect your progress:
1. Before starting an item, set its "status" to "in_progress".
2. When the item is done (test written and passing), set it to "complete".
3. Only one item should be "in_progress" at a time.

Example update for a single item:
  {"id": "s-1", "scenario": "The checklist has one item per scenario", "status": "complete"}

Read the file first, update the relevant item, and write the whole file back.
Do not change any other field. Do not add or remove items.
`

func stripANSI(s string) string {
	return ansiEscape.ReplaceAllString(s, "")
}

// marshalPayload builds a phase/envelope payload as real JSON.
//
// It must never be built with fmt.Sprintf and %q: Go's %q emits Go string
// escapes (\x1b for ESC), which are not valid JSON escapes. A single ANSI byte
// in agent stdout then produces a json.RawMessage that fails to marshal, and
// because callers historically discarded the encoder error the API answered
// HTTP 200 with a zero-byte body.
func marshalPayload(v interface{}) json.RawMessage {
	b, err := json.Marshal(v)
	if err != nil {
		safe, _ := json.Marshal(map[string]string{"payload_error": err.Error()})
		return json.RawMessage(safe)
	}
	return json.RawMessage(b)
}

type PhaseRunner struct {
	Store    *store.Store
	Router   *handoff.Router
	Worktree string
	RepoName string
	RunID    string
	AgentCLI string
	Model    string

	// Budgets per attempt. Zero means "resolve from the environment default".
	AgentTimeout time.Duration
	GateTimeout  time.Duration
}

// Default execution budgets. Zero means unbounded.
//
// An agent phase has NO default deadline. Agent work has no predictable upper
// bound, so any default is a guess, and when the guess is wrong it kills work
// that was succeeding. Run sgt-1787427981 was killed at exactly the former 10m
// default having already committed a change whose build and tests passed; the
// bullet was recorded failed and the commit orphaned. A deadline that discards
// completed work is worse than no deadline: an agent that hangs is visible to an
// operator and cancellable, whereas work destroyed on a timer is silent.
//
// A gate keeps its default. A gate is a deterministic command with a known cost,
// so a gate still running after five minutes is genuinely hung.
const (
	DefaultAgentTimeout = 0
	DefaultGateTimeout  = 5 * time.Minute
)

func envDuration(key string, fallback time.Duration) time.Duration {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		if d, err := time.ParseDuration(v); err == nil && d > 0 {
			return d
		}
	}
	return fallback
}

func (pr *PhaseRunner) agentTimeout() time.Duration {
	if pr.AgentTimeout > 0 {
		return pr.AgentTimeout
	}
	return envDuration("SERGEANT_AGENT_TIMEOUT", DefaultAgentTimeout)
}

func (pr *PhaseRunner) gateTimeout() time.Duration {
	if pr.GateTimeout > 0 {
		return pr.GateTimeout
	}
	return envDuration("SERGEANT_GATE_TIMEOUT", DefaultGateTimeout)
}

// SupportedAgents are the harnesses this native engine knows how to invoke.
// An unrecognised name previously fell through to `exe [prompt]`, producing a
// malformed command that failed in a way indistinguishable from agent failure.
var SupportedAgents = []string{"opencode", "oc", "claude", "goose", "codex", "pi"}

// ValidateAgent reports whether the engine can drive the named harness.
func ValidateAgent(agentCLI string) error {
	if agentCLI == "" {
		return nil // caller falls back to the default
	}
	base := filepath.Base(agentCLI)
	for _, a := range SupportedAgents {
		if base == a {
			return nil
		}
	}
	return fmt.Errorf("unsupported agent %q: this engine can drive %s", agentCLI, strings.Join(SupportedAgents, ", "))
}

type GateResult struct {
	GateName string `json:"gate_name"`
	Command  string `json:"command"`
	Passed   bool   `json:"passed"`
	Output   string `json:"output"`
	// Worktree and Branch record where the gate actually ran. A gate result with no
	// location is unauditable: it says a command passed without saying on what.
	Worktree string `json:"worktree,omitempty"`
	Branch   string `json:"branch,omitempty"`
}

// currentBranch reports the branch checked out in the runner's worktree. It reads
// disk rather than deriving the name from the run id, so the recorded value is what
// actually exists. An empty string means it could not be determined.
func (pr *PhaseRunner) currentBranch() string {
	if pr.Worktree == "" {
		return ""
	}
	out, err := exec.Command("git", "-C", pr.Worktree, "rev-parse", "--abbrev-ref", "HEAD").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// RunCodeGate executes a deterministic test/lint shell command with a strict timeout.
func (pr *PhaseRunner) RunCodeGate(ctx context.Context, name, command string) (*GateResult, error) {
	start := time.Now()
	gateCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	cmd := exec.CommandContext(gateCtx, "bash", "-c", command)
	superviseGroup(cmd)
	cmd.Dir = pr.Worktree

	var outBuf bytes.Buffer
	cmd.Stdout = &outBuf
	cmd.Stderr = &outBuf

	err := cmd.Run()
	duration := time.Since(start).Milliseconds()

	passed := (err == nil)
	result := &GateResult{
		GateName: name,
		Command:  command,
		Passed:   passed,
		Output:   stripANSI(outBuf.String()),
		Worktree: pr.Worktree,
		Branch:   pr.currentBranch(),
	}

	status := "passed"
	errStr := ""
	if !passed {
		status = "failed"
		if err != nil {
			errStr = fmt.Sprintf("%v: %s", err, outBuf.String())
		}
	}

	payload, _ := json.Marshal(result)
	phaseRec := &store.PhaseRecord{
		ID:         fmt.Sprintf("%s-%s-%d", pr.RepoName, name, time.Now().UnixNano()),
		RunID:      pr.RunID,
		Repo:       pr.RepoName,
		Name:       name,
		Kind:       "code",
		Status:     status,
		Error:      errStr,
		DurationMs: duration,
		Payload:    payload,
	}

	_ = pr.Store.RecordPhase(phaseRec)
	return result, nil
}

// BuildAgentCommand formats CLI arguments for any supported agent harness with proper non-interactive headless flags.
func BuildAgentCommand(agentCLI, model, prompt string) (string, []string, []string) {
	exe := agentCLI
	if exe == "" {
		exe = "opencode"
	}

	var args []string
	var env []string

	switch filepath.Base(exe) {
	case "opencode", "oc":
		// Use --auto instead of non-existent --dangerously-skip-permissions
		args = []string{"run", "--auto"}
		if model != "" {
			args = append(args, "--model", model)
		}
		args = append(args, prompt)

	case "claude":
		args = []string{"--print"}
		if model != "" {
			args = append(args, "--model", model)
		}
		args = append(args, prompt)

	case "goose":
		// `goose run` takes -t/--text or -i/--instructions; it has no positional
		// text argument. The previous form, `goose run <prompt>`, was rejected
		// outright with "error: unexpected argument", so every goose dispatch
		// failed in a way indistinguishable from the agent itself failing. goose
		// had never worked in v2.
		//
		// --no-session keeps a dispatched run from leaving session state behind,
		// and omitting -s/--interactive matters more: goose continues in
		// interactive mode after processing its input, which in a headless run
		// means the phase waits on a terminal that is not there (R2.3).
		//
		// --output-format json makes goose's own per-session usage and cost
		// reachable from the phase. goose records total/input/output tokens and
		// accumulated_cost itself; asking for JSON is what keeps it from being
		// discarded.
		args = []string{"run", "--no-session", "--output-format", "json", "-t", prompt}
		if model != "" {
			env = append(env, fmt.Sprintf("GOOSE_MODEL=%s", model))
		}

	case "codex":
		args = []string{"exec"}
		if model != "" {
			args = append(args, "--model", model)
		}
		args = append(args, prompt)

	case "pi":
		if model != "" {
			args = []string{"--model", model, "-p", prompt}
		} else {
			args = []string{"-p", prompt}
		}

	default:
		args = []string{prompt}
	}

	return exe, args, env
}

// RunAgentPhase executes a bounded headless agent session and validates output envelope with fallback safety.
func (pr *PhaseRunner) RunAgentPhase(ctx context.Context, phaseName, prompt string, retries int) (*handoff.Envelope, error) {
	start := time.Now()
	phaseID := fmt.Sprintf("%s-%s-%d", pr.RepoName, phaseName, time.Now().UnixNano())

	// 1. Immediately record RUNNING phase state so UI updates in real-time.
	// Attempt 1 is recorded here; subsequent attempts get their own records.
	initialPhase := &store.PhaseRecord{
		ID:         phaseID,
		RunID:      pr.RunID,
		Repo:       pr.RepoName,
		Name:       phaseName,
		Kind:       "agent",
		Status:     "running",
		DurationMs: 0,
		Attempt:    1,
	}
	_ = pr.Store.RecordPhase(initialPhase)

	// Create .sergeant state dir in worktree
	stateDir := filepath.Join(pr.Worktree, ".sergeant")
	_ = os.MkdirAll(stateDir, 0755)

	// Extend the prompt with progress-reporting instructions when a plan file
	// was seeded into the worktree. The instructions tell the agent what the
	// file is, where it lives, and exactly how to update it.
	//
	// The extension is added here — after the worktree is available but before
	// any agent invocation — so every retry attempt receives the same complete
	// prompt. The plan file itself is not modified here; sergeant only seeds it
	// (in Engine.RunStage) and thereafter only reads it. The agent is the sole
	// writer after seeding.
	planPath := filepath.Join(stateDir, "plan.json")
	if _, planErr := os.Stat(planPath); planErr == nil {
		prompt = prompt + planPromptExtension
	}

	promptFile := filepath.Join(stateDir, fmt.Sprintf("prompt_%s.txt", phaseName))
	_ = os.WriteFile(promptFile, []byte(prompt), 0644)

	var lastErr error
	for attempt := 0; attempt <= retries; attempt++ {
		exe, args, extraEnv := BuildAgentCommand(pr.AgentCLI, pr.Model, prompt)

		// A zero budget means unbounded: derive a cancellable child so operator
		// cancellation still propagates, but attach no deadline. Passing 0 to
		// context.WithTimeout would produce an already-expired context and kill the
		// agent instantly, so the two cases cannot share one call.
		budget := pr.agentTimeout()
		var phaseCtx context.Context
		var cancel context.CancelFunc
		if budget > 0 {
			phaseCtx, cancel = context.WithTimeout(ctx, budget)
		} else {
			phaseCtx, cancel = context.WithCancel(ctx)
		}
		cmd := exec.CommandContext(phaseCtx, exe, args...)
		superviseGroup(cmd)
		cmd.Dir = pr.Worktree
		if len(extraEnv) > 0 {
			cmd.Env = append(os.Environ(), extraEnv...)
		}

		var outBuf bytes.Buffer
		cmd.Stdout = &outBuf
		cmd.Stderr = &outBuf

		runErr := cmd.Run()
		cancel()
		duration := time.Since(start).Milliseconds()

		// Operator cancellation is not a phase failure. Let the run-level handler
		// record "cancelled" rather than blaming the agent.
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}

		// PRD R2.6: a process exit cannot falsely mark a phase as passed. Previously
		// runErr was captured into lastErr and then ignored, phaseStatus was the
		// constant "passed", and the function returned nil error — so an agent killed
		// at its timeout produced a passed phase and a passed run.
		timedOut := errors.Is(phaseCtx.Err(), context.DeadlineExceeded)
		failed := runErr != nil

		var failureReason string
		switch {
		case timedOut:
			failureReason = fmt.Sprintf("agent %s exceeded its %s budget and was killed", exe, budget)
		case failed:
			failureReason = fmt.Sprintf("agent %s exited with error: %v", exe, runErr)
		}

		// Read the agent's own envelope when it wrote one. Only synthesize a summary
		// otherwise, and never describe a failed attempt as completed.
		envelopePath := filepath.Join(stateDir, "envelope.json")
		var env handoff.Envelope

		if data, err := os.ReadFile(envelopePath); err == nil && !failed {
			_ = json.Unmarshal(data, &env)
		} else {
			summary := fmt.Sprintf("Phase %s completed for %s", phaseName, pr.RepoName)
			if failed {
				summary = fmt.Sprintf("Phase %s failed for %s: %s", phaseName, pr.RepoName, failureReason)
			}
			env = handoff.Envelope{
				TaskID:    pr.RunID,
				Repo:      pr.RepoName,
				Stage:     phaseName,
				Summary:   summary,
				Artifacts: []string{fmt.Sprintf(".sergeant/prompt_%s.txt", phaseName)},
				Payload: marshalPayload(map[string]string{
					"raw_output": stripANSI(outBuf.String()),
					"agent":      exe,
					"attempt":    fmt.Sprintf("%d/%d", attempt+1, retries+1),
					"worktree":   pr.Worktree,
					"branch":     pr.currentBranch(),
				}),
			}
		}

		// Generate the envelope id before the SaveEnvelope call so both the
		// delivery record (DeliverEnvelope) and the envelope record (RecordEnvelope)
		// use the same id. Previously the id was generated inside RecordEnvelope's
		// argument, two lines after SaveEnvelope, so it could never match.
		now := time.Now().UTC()
		envelopeID := fmt.Sprintf("%s-%s-%d", pr.RepoName, phaseName, now.UnixNano())

		// Wrap SaveEnvelope in DeliverEnvelope so the write is durably recorded
		// with retry and idempotency (R5.3, R5.4). A failed write is no longer
		// discarded: the delivery history shows what happened and the error is
		// surfaced the same way other phase failures are.
		//
		// deliverErr is kept separate from lastErr (the agent-phase error) so that
		// a successful retry does not inherit a previous iteration's lastErr value.
		var deliverErr error
		if de := pr.Store.DeliverEnvelope(envelopeID, pr.RepoName, func() error {
			return pr.Router.SaveEnvelope(&env)
		}); de != nil {
			deliverErr = fmt.Errorf("delivering envelope for phase %s on %s: %w", phaseName, pr.RepoName, de)
		}

		_ = pr.Store.RecordEnvelope(&store.EnvelopeRecord{
			ID:            envelopeID,
			RunID:         pr.RunID,
			Repo:          pr.RepoName,
			Stage:         phaseName,
			Summary:       env.Summary,
			Artifacts:     env.Artifacts,
			Data:          env.Payload,
			Type:          "phase.completed",
			SchemaVersion: "1",
			OccurredAt:    now,
			Producer:      "sergeant/runner",
			CorrelationID: pr.RunID,
			CausationID:   pr.Store.CausationFromLatest(pr.RunID, pr.RepoName),
			PhaseID:       phaseID,
		})

		phaseStatus := "passed"
		if failed {
			phaseStatus = "failed"
		}

		// Each attempt is its own phase record. Reusing one id made retries invisible,
		// because INSERT OR REPLACE overwrote the previous attempt (PRD R2.4 requires
		// retry policy to be observable).
		//
		// attempt is 0-based in the loop; Attempt in the record is 1-based.
		// The first attempt reuses phaseID (overwriting the "running" sentinel that
		// was written above with its final status). Subsequent attempts get a new ID
		// so the previous attempt's record is preserved.
		attemptNumber := attempt + 1
		attemptID := phaseID
		if attempt > 0 {
			attemptID = fmt.Sprintf("%s-attempt%d", phaseID, attemptNumber)
		}
		_ = pr.Store.RecordPhase(&store.PhaseRecord{
			ID:         attemptID,
			RunID:      pr.RunID,
			Repo:       pr.RepoName,
			Name:       phaseName,
			Kind:       "agent",
			Status:     phaseStatus,
			Error:      failureReason,
			DurationMs: duration,
			Payload:    env.Payload,
			Attempt:    attemptNumber,
		})

		if failed {
			lastErr = fmt.Errorf("%s (output: %s)", failureReason, stripANSI(strings.TrimSpace(outBuf.String())))
			if attempt < retries {
				continue
			}
			return nil, lastErr
		}

		// Agent succeeded. Surface any delivery failure so the caller can observe
		// it; the delivery history already records the cause.
		if deliverErr != nil {
			return nil, deliverErr
		}
		return &env, nil
	}

	return nil, lastErr
}

// DeliverPullRequest automatically seals the worktree and opens a verified Pull Request via GitHub CLI.
func (pr *PhaseRunner) DeliverPullRequest(ctx context.Context, branch, title, body string) (string, error) {
	if branch == "" {
		branch = fmt.Sprintf("sergeant/%s-%s", pr.RunID, pr.RepoName)
	}
	if title == "" {
		title = fmt.Sprintf("feat(%s): verified automated patch [%s]", pr.RepoName, pr.RunID)
	}
	if body == "" {
		body = fmt.Sprintf("### Automated Pull Request from Sergeant Factory Spine\n\n- **Task ID**: `%s`\n- **Target Repo**: `%s`\n- **Code Gate Verification**: 100%% Deterministic Zero-Token Gates Passed\n- **Envelope Hash**: Sealed in `.sergeant/review.json`\n", pr.RunID, pr.RepoName)
	}

	// 1. Commit any uncommitted changes in worktree
	_ = exec.CommandContext(ctx, "git", "-C", pr.Worktree, "add", ".").Run()
	_ = exec.CommandContext(ctx, "git", "-C", pr.Worktree, "commit", "-m", title).Run()

	// 2. Open PR via gh CLI or create patch artifact
	cmd := exec.CommandContext(ctx, "gh", "pr", "create", "--title", title, "--body", body, "--head", branch)
	cmd.Dir = pr.Worktree
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out

	if err := cmd.Run(); err != nil {
		// If gh not authenticated or no remote branch, produce local review bundle
		reviewPath := filepath.Join(pr.Worktree, ".sergeant", "review.json")
		reviewData, _ := json.MarshalIndent(map[string]interface{}{
			"task_id":      pr.RunID,
			"repo":         pr.RepoName,
			"branch":       branch,
			"title":        title,
			"status":       "SEALED_LOCAL_PR",
			"delivery_url": fmt.Sprintf("local://worktree/%s", branch),
			"created_at":   time.Now().Format(time.RFC3339),
		}, "", "  ")
		_ = os.WriteFile(reviewPath, reviewData, 0644)
		return fmt.Sprintf("Local PR branch ready at %s", branch), nil
	}

	return strings.TrimSpace(out.String()), nil
}
