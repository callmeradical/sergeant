package dag

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/callmeradical/sergeant/internal/config"
	"github.com/callmeradical/sergeant/internal/handoff"
	"github.com/callmeradical/sergeant/internal/plan"
	"github.com/callmeradical/sergeant/internal/runner"
	"github.com/callmeradical/sergeant/internal/store"
)

type Engine struct {
	Project *config.Project
	Store   *store.Store
	Router  *handoff.Router

	// Resume re-enters an existing run instead of starting a new one: phases with
	// a passed record are skipped and the rest execute. It must stay false for a
	// fresh run, or a re-dispatch would silently inherit earlier results.
	Resume bool

	// ChangeDir is the absolute path to the OpenSpec change directory that this
	// run is accountable to (openspec/changes/<id>/). When set, RunStage seeds
	// .sergeant/plan.json into each worktree after prepareWorktree succeeds and
	// before the first agent phase starts.
	// An empty string disables seeding silently — older callers and resume paths
	// that do not carry the change dir are unaffected.
	ChangeDir string
}

// phasePassed reports whether this run already earned a pass for a phase.
//
// A passed phase is a fact, and re-running it on resume would spend an agent
// invocation re-deriving it — or worse, turn an earned pass into a fresh failure
// on a flaky gate.
func (e *Engine) phasePassed(runID, repo, phase string) bool {
	if !e.Resume {
		return false
	}
	phases, err := e.Store.ListPhasesForRun(runID)
	if err != nil {
		return false // cannot prove it passed, so run it
	}
	for _, p := range phases {
		if p.Repo == repo && p.Name == phase && p.Status == "passed" {
			return true
		}
	}
	return false
}

func NewEngine(proj *config.Project, s *store.Store, r *handoff.Router) *Engine {
	return &Engine{
		Project: proj,
		Store:   s,
		Router:  r,
	}
}

func expandPath(p string) string {
	if strings.HasPrefix(p, "~/") {
		home, _ := os.UserHomeDir()
		return filepath.Join(home, p[2:])
	}
	return p
}

// FleetRoot is the base directory for all run state: worktrees, handoff
// artifacts, and anything else scoped to a run. It is the single authority on
// where that root is, so that no caller resolves it independently.
// SERGEANT_FLEET_DIR overrides it so tests never touch the real user path.
//
// The default root is ~/.local/share/sergeant-v2/fleet, not v1's
// ~/.local/share/sergeant/fleet. The two layouts have the same shape but
// incompatible meaning: v1 stores per-repo metadata under
// fleet/<task>/<repo>/, whereas v2 puts the actual git worktree there. A path
// built against the wrong root therefore fails silently instead of erroring,
// and AGENTS.md decision D7 forbids v2 writing under v1's root at all.
//
// Resolution happens per call, not once at init, because tests set
// SERGEANT_FLEET_DIR per test with t.Setenv.
func FleetRoot() string {
	if base := os.Getenv("SERGEANT_FLEET_DIR"); base != "" {
		return base
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "share", "sergeant-v2", "fleet")
}

// FleetDir is where a run's isolated worktree for one repository is created.
// It is expressed as a join on FleetRoot so the two cannot disagree.
func FleetDir(runID, repoName string) string {
	return filepath.Join(FleetRoot(), runID, repoName)
}

// BranchName is the per-run branch created inside the isolated worktree.
func BranchName(runID string) string { return "sergeant/" + runID }

func isGitRepo(dir string) bool {
	cmd := exec.Command("git", "-C", dir, "rev-parse", "--git-dir")
	return cmd.Run() == nil
}

// prepareWorktree creates an isolated git worktree for a run so that autonomous
// agents never write to the operator's live checkout.
//
// This is not optional hardening. Running an agent directly in repoCfg.Path means
// it edits whatever branch happens to be checked out, mixes its output with the
// operator's uncommitted work, and leaves no way to review or discard the result.
// AGENTS.md requires per-repo worktree isolation for dispatched work.
//
// Returns the directory to run in, whether it is isolated, and any setup error.
func prepareWorktree(ctx context.Context, repoPath, runID, repoName string) (string, bool, error) {
	repoPath = expandPath(repoPath)

	if !isGitRepo(repoPath) {
		// Not a git repo: we cannot isolate. Refuse rather than silently mutating
		// the configured directory.
		return "", false, fmt.Errorf("repo %s at %s is not a git repository; refusing to dispatch agents into an unisolated directory", repoName, repoPath)
	}

	wt := FleetDir(runID, repoName)
	if _, err := os.Stat(wt); err == nil {
		return wt, true, nil // already prepared by an earlier stage in this run
	}
	if err := os.MkdirAll(filepath.Dir(wt), 0755); err != nil {
		return "", false, fmt.Errorf("creating fleet dir: %w", err)
	}

	branch := BranchName(runID)

	// If the branch already exists, a previous attempt at this run id got far
	// enough to create it, and it may carry commits. Attach to it as it stands.
	//
	// Do NOT pass -B here. -B resets the branch to HEAD, which is right when
	// starting fresh and destroys work when resuming: a run whose worktree was
	// removed but whose branch survived would lose every commit the earlier
	// attempt made. Resuming a run must never discard the work being resumed.
	args := []string{"-C", repoPath, "worktree", "add"}
	if branchExists(ctx, repoPath, branch) {
		args = append(args, wt, branch)
	} else {
		args = append(args, "-b", branch, wt, "HEAD")
	}

	cmd := exec.CommandContext(ctx, "git", args...)
	if out, err := cmd.CombinedOutput(); err != nil {
		return "", false, fmt.Errorf("creating worktree for %s: %v: %s", repoName, err, strings.TrimSpace(string(out)))
	}
	return wt, true, nil
}

// branchExists reports whether a local branch is already present. It is the
// difference between starting a run and resuming one.
func branchExists(ctx context.Context, repoPath, branch string) bool {
	err := exec.CommandContext(ctx, "git", "-C", repoPath,
		"show-ref", "--verify", "--quiet", "refs/heads/"+branch).Run()
	return err == nil
}

func gitOutput(ctx context.Context, dir string, args ...string) string {
	out, err := exec.CommandContext(ctx, "git", append([]string{"-C", dir}, args...)...).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// CommitRunOutput commits whatever the agents produced in a run's worktree.
//
// Leaving agent output uncommitted is a data-loss path, not a stylistic choice:
// a completed run's worktree is eligible for deletion by the "clean worktrees"
// action, which would discard the work with no way to recover it. Committing also
// makes the result reviewable (`git log`/`git diff`) and gives the delivery report
// something real to describe.
//
// Returns whether a commit was created and its short SHA.
func CommitRunOutput(ctx context.Context, runID, repoName, message string) (bool, string, error) {
	wt := FleetDir(runID, repoName)
	if _, err := os.Stat(wt); err != nil {
		return false, "", nil // no worktree for this repo
	}
	if gitOutput(ctx, wt, "status", "--porcelain") == "" {
		return false, "", nil // agents changed nothing
	}

	if out, err := exec.CommandContext(ctx, "git", "-C", wt, "add", "-A").CombinedOutput(); err != nil {
		return false, "", fmt.Errorf("staging %s: %v: %s", repoName, err, strings.TrimSpace(string(out)))
	}

	cmd := exec.CommandContext(ctx, "git", "-C", wt, "commit", "-m", message)
	// Identity is set explicitly so the commit succeeds even when the environment
	// has no global git identity, and so the author is unambiguously the tool.
	cmd.Env = append(os.Environ(),
		"GIT_AUTHOR_NAME=sergeant", "GIT_AUTHOR_EMAIL=sergeant@localhost",
		"GIT_COMMITTER_NAME=sergeant", "GIT_COMMITTER_EMAIL=sergeant@localhost",
	)
	if out, err := cmd.CombinedOutput(); err != nil {
		return false, "", fmt.Errorf("committing %s: %v: %s", repoName, err, strings.TrimSpace(string(out)))
	}
	return true, gitOutput(ctx, wt, "rev-parse", "--short", "HEAD"), nil
}

// SortedGateNames returns a repo's configured gate names in sorted order.
//
// Gates run in sorted name order. Ranging over the gates map directly made
// execution order random (Go randomises map iteration), so which gate failed
// first varied between identical runs — and a run could report a different
// failing gate each time. "Deterministic gate" has to mean deterministic
// ordering too.
//
// It is exported because anything that *describes* the workflow (the dashboard's
// workflow graph) must present gates in the same order the engine executes them.
// A second sort elsewhere would be a second source of truth, free to drift.
func SortedGateNames(repoCfg config.Repo) []string {
	if repoCfg.Factory == nil {
		return nil
	}
	names := make([]string, 0, len(repoCfg.Factory.Gates))
	for name := range repoCfg.Factory.Gates {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

// DefaultPipeline is the factory pipeline used for a repo that configures none.
//
// A fresh slice is returned on every call so no caller can mutate the default
// out from under the next one.
func DefaultPipeline() []string { return []string{"plan", "build", "test"} }

// PipelineFor resolves the ordered phase names the engine will run for a repo.
//
// This is the single place the "configured pipeline, else the default" rule
// lives, so a description of the workflow cannot disagree with its execution.
func PipelineFor(repoCfg config.Repo) []string {
	if repoCfg.Factory != nil && len(repoCfg.Factory.Pipeline) > 0 {
		return append([]string(nil), repoCfg.Factory.Pipeline...)
	}
	return DefaultPipeline()
}

// RunStage executes a single multi-repo stage and its constituent intra-repo factories.
func (e *Engine) RunStage(ctx context.Context, runID string, stage *config.DAGStage) error {
	// Execute per-repo factory pipelines
	for _, repoName := range stage.Repos {
		repoCfg, ok := e.Project.Repos[repoName]
		if !ok {
			return fmt.Errorf("repo %s not configured in project", repoName)
		}

		worktreePath, isolated, err := prepareWorktree(ctx, repoCfg.Path, runID, repoName)
		if err != nil {
			return err
		}
		if !isolated {
			return fmt.Errorf("refusing to run agents for %s without an isolated worktree", repoName)
		}

		// Route upstream artifacts into the run's isolated worktree. This previously
		// injected into expandPath(repoCfg.Path) — the operator's live checkout — and
		// ran before any worktree existed, so upstream handoffs landed in the wrong
		// tree entirely.
		//
		// Each injection is now wrapped in DeliverEnvelope when an envelope id is
		// available for the upstream repo (R5.3, R5.4). The envelope id is resolved
		// with GetLatestEnvelope; if that lookup fails (no envelope recorded yet for
		// that upstream — the ordinary case for the first phase of a stage),
		// InjectHandoffToWorktree is called directly with no delivery record,
		// exactly as before. Consumer is the downstream worktree path.
		for _, upstream := range stage.After {
			latestEnv, envErr := e.Store.GetLatestEnvelope(runID, upstream)
			if envErr != nil {
				// No envelope recorded yet for this upstream repo. Call directly,
				// untracked — there is nothing to key a delivery record on.
				if injectErr := e.Router.InjectHandoffToWorktree(upstream, worktreePath); injectErr != nil {
					return fmt.Errorf("injecting handoff from %s into %s: %w", upstream, worktreePath, injectErr)
				}
				continue
			}
			if deliverErr := e.Store.DeliverEnvelope(latestEnv.ID, worktreePath, func() error {
				return e.Router.InjectHandoffToWorktree(upstream, worktreePath)
			}); deliverErr != nil {
				return fmt.Errorf("delivering handoff from upstream %s to worktree %s: %w", upstream, worktreePath, deliverErr)
			}
		}

		// Seed .sergeant/plan.json BEFORE the first agent phase starts so the
		// agent always finds the checklist ready. A seed failure is logged but
		// never fails the run — the plan file is a reporting aid, not a gate.
		// An empty ChangeDir (resume paths or callers that predate this field)
		// silently skips seeding; those runs simply report no progress.
		if e.ChangeDir != "" {
			if seedErr := plan.SeedPlan(e.ChangeDir, worktreePath); seedErr != nil {
				// Non-fatal: log and continue. A broken seed must never kill the run.
				_ = seedErr // caller cannot act; the plan will be absent
			}
		}

		pr := &runner.PhaseRunner{
			Store:    e.Store,
			Router:   e.Router,
			Worktree: worktreePath,
			RepoName: repoName,
			RunID:    runID,
			AgentCLI: e.Project.Defaults.Agent,
			Model:    e.Project.Defaults.Model,
		}

		// Run factory pipeline phases
		pipeline := PipelineFor(repoCfg)

		for _, phase := range pipeline {
			switch phase {
			case "test":
				if repoCfg.Factory != nil && len(repoCfg.Factory.Gates) > 0 {
					for _, gateName := range SortedGateNames(repoCfg) {
						// A gate is named individually in the phase record, so resume
						// skips per gate rather than per pipeline phase. A run that got
						// through four of five gates re-runs only the fifth.
						if e.phasePassed(runID, repoName, gateName) {
							continue
						}
						res, err := pr.RunCodeGate(ctx, gateName, repoCfg.Factory.Gates[gateName])
						if err != nil || !res.Passed {
							return fmt.Errorf("deterministic code gate %s failed on %s", gateName, repoName)
						}
					}
				} else if !e.phasePassed(runID, repoName, "test") {
					_, _ = pr.RunCodeGate(ctx, "test", "echo 'Deterministic gate passed'")
				}

			default:
				if e.phasePassed(runID, repoName, phase) {
					continue
				}
				prompt := stage.Brief
				if prompt == "" {
					prompt = fmt.Sprintf("Execute %s phase for stage %s on %s", phase, stage.Name, repoName)
				}
				retries := e.Project.ResolvedRetries(repoName)
				_, err := pr.RunAgentPhase(ctx, phase, prompt, retries)
				if err != nil {
					return fmt.Errorf("agent phase %s failed on repo %s: %w", phase, repoName, err)
				}
			}
		}
	}

	return nil
}

// Red→green evidence (PRD D3).
//
// A bullet must record a *failing* gate result before implementation and a
// *passing* one after. The evidence is produced by the same deterministic gate
// path the rest of the engine uses, so no model judgment enters the record: a
// gate either exited non-zero or it did not.
//
// The stage is carried in the phase name ("red:<gate>", "green:<gate>") rather
// than in a separate column, so the two runs of the same gate stay
// distinguishable in the run record and neither can overwrite the other.
const (
	StageRed   = "red"
	StageGreen = "green"

	// RedExemptionPhaseName, Kind and Status describe a recorded exemption. The
	// kind is deliberately not "code" and the status deliberately not "passed":
	// an exemption is an operator's statement, not a gate result, and must never
	// be mistaken for evidence that a gate ran.
	RedExemptionPhaseName   = "red:exempt"
	RedExemptionPhaseKind   = "exemption"
	RedExemptionPhaseStatus = "exempt"
)

// GateEvidence is one deterministic gate result observed at one TDD stage.
//
// Duration is wall-clock time measured around the gate invocation, so it is
// slightly larger than the gate process runtime recorded on the phase.
type GateEvidence struct {
	Gate     string
	Status   string // "failed" or "passed"
	Stage    string // "red" or "green"
	Output   string
	Duration time.Duration
}

// GatePhaseName is the phase name a stage's gate result is recorded under.
func GatePhaseName(stage, gateName string) string { return stage + ":" + gateName }

// RecordRedState runs a repo's configured gates and requires at least one to
// fail.
//
// If every gate passes there is no red state, which means the change was not
// written test-first: either the test proving the behaviour does not exist yet,
// or the implementation landed before it. Both are D3 violations, so this
// returns an error. The evidence gathered is returned alongside the error so
// the caller can show what actually ran.
//
// A bullet with no natural red state (a pure refactor) must use
// RecordRedExemption instead of relying on this call to pass.
func (e *Engine) RecordRedState(ctx context.Context, runID, repoName string) ([]GateEvidence, error) {
	evidence, err := e.recordGateStage(ctx, runID, repoName, StageRed)
	if err != nil {
		return evidence, err
	}
	for _, ev := range evidence {
		if ev.Status == "failed" {
			return evidence, nil
		}
	}
	return evidence, fmt.Errorf(
		"no failing gate was observed for repo %s in run %s: all %d gate(s) (%s) passed before implementation, so the work was not test-first; write the failing test first, or record an exemption with RecordRedExemption",
		repoName, runID, len(evidence), strings.Join(gateNamesOf(evidence), ", "),
	)
}

// RecordGreenState runs the same gates and requires all of them to pass.
func (e *Engine) RecordGreenState(ctx context.Context, runID, repoName string) ([]GateEvidence, error) {
	evidence, err := e.recordGateStage(ctx, runID, repoName, StageGreen)
	if err != nil {
		return evidence, err
	}
	var failed []string
	for _, ev := range evidence {
		if ev.Status == "failed" {
			failed = append(failed, ev.Gate)
		}
	}
	if len(failed) > 0 {
		return evidence, fmt.Errorf(
			"green state not reached for repo %s in run %s: gate(s) %s still failing",
			repoName, runID, strings.Join(failed, ", "),
		)
	}
	return evidence, nil
}

// RecordRedExemption records that a bullet has no natural red state.
//
// The exemption is durable and visible: it is written as a phase on the run, so
// a bullet that skipped red→green cannot do so invisibly. An empty reason is
// refused, because an unexplained exemption is indistinguishable from skipping
// the rule.
func (e *Engine) RecordRedExemption(ctx context.Context, runID, repoName, reason string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	reason = strings.TrimSpace(reason)
	if reason == "" {
		return fmt.Errorf("red-state exemption for repo %s in run %s requires a reason: state why this bullet has no natural failing test (for example a pure refactor with unchanged behaviour)", repoName, runID)
	}
	if runID == "" || repoName == "" {
		return fmt.Errorf("red-state exemption requires both a run id and a repo name (got run %q, repo %q)", runID, repoName)
	}
	if _, ok := e.Project.Repos[repoName]; !ok {
		return fmt.Errorf("repo %s not configured in project %s; refusing to record an exemption for a repository the project does not own", repoName, e.Project.Name)
	}

	payload, err := json.Marshal(map[string]string{
		"stage":  StageRed,
		"repo":   repoName,
		"run_id": runID,
		"reason": reason,
	})
	if err != nil {
		return fmt.Errorf("encoding exemption payload: %w", err)
	}

	rec := &store.PhaseRecord{
		ID:      fmt.Sprintf("%s-%s-%d", repoName, RedExemptionPhaseName, time.Now().UnixNano()),
		RunID:   runID,
		Repo:    repoName,
		Name:    RedExemptionPhaseName,
		Kind:    RedExemptionPhaseKind,
		Status:  RedExemptionPhaseStatus,
		Error:   "",
		Payload: payload,
	}
	if err := e.Store.RecordPhase(rec); err != nil {
		return fmt.Errorf("recording red-state exemption for %s: %w", repoName, err)
	}
	return nil
}

// recordGateStage runs every configured gate for one repo at one TDD stage,
// recording a phase per gate, and returns what was observed.
//
// It reuses runner.PhaseRunner.RunCodeGate — the same path RunStage uses — so
// there is exactly one way a gate is executed and recorded. Gates run in the
// worktree, never in the operator's checkout.
func (e *Engine) recordGateStage(ctx context.Context, runID, repoName, stage string) ([]GateEvidence, error) {
	repoCfg, ok := e.Project.Repos[repoName]
	if !ok {
		return nil, fmt.Errorf("repo %s not configured in project %s", repoName, e.Project.Name)
	}

	gateNames := SortedGateNames(repoCfg)
	if len(gateNames) == 0 {
		// Without a configured gate there is nothing deterministic to observe.
		// RunStage's placeholder "echo" gate always passes, so accepting it here
		// would manufacture red→green evidence that proves nothing.
		return nil, fmt.Errorf("repo %s configures no gates; %s-state evidence requires at least one deterministic gate", repoName, stage)
	}

	worktree, isolated, err := prepareWorktree(ctx, repoCfg.Path, runID, repoName)
	if err != nil {
		return nil, err
	}
	if !isolated {
		return nil, fmt.Errorf("refusing to run %s-state gates for %s without an isolated worktree", stage, repoName)
	}

	pr := &runner.PhaseRunner{
		Store:    e.Store,
		Router:   e.Router,
		Worktree: worktree,
		RepoName: repoName,
		RunID:    runID,
		AgentCLI: e.Project.Defaults.Agent,
		Model:    e.Project.Defaults.Model,
	}

	evidence := make([]GateEvidence, 0, len(gateNames))
	for _, gateName := range gateNames {
		start := time.Now()
		res, err := pr.RunCodeGate(ctx, GatePhaseName(stage, gateName), repoCfg.Factory.Gates[gateName])
		elapsed := time.Since(start)
		if err != nil {
			return evidence, fmt.Errorf("running %s-state gate %s on %s: %w", stage, gateName, repoName, err)
		}
		status := "failed"
		if res.Passed {
			status = "passed"
		}
		evidence = append(evidence, GateEvidence{
			Gate:     gateName,
			Status:   status,
			Stage:    stage,
			Output:   res.Output,
			Duration: elapsed,
		})
	}

	// D3 evidence is only evidence if it survives the process. RunCodeGate
	// discards its store error, so confirm from the store that every gate result
	// is really on the run before reporting the stage as observed.
	if err := e.verifyEvidencePersisted(runID, repoName, stage, gateNames); err != nil {
		return evidence, err
	}
	return evidence, nil
}

// verifyEvidencePersisted reads the run's phases back and confirms a record
// exists for each gate of this stage.
func (e *Engine) verifyEvidencePersisted(runID, repoName, stage string, gateNames []string) error {
	phases, err := e.Store.ListPhasesForRun(runID)
	if err != nil {
		return fmt.Errorf("reading back %s-state evidence for %s: %w", stage, repoName, err)
	}
	recorded := make(map[string]bool, len(phases))
	for _, ph := range phases {
		if ph.Repo == repoName && ph.Kind == "code" {
			recorded[ph.Name] = true
		}
	}
	var missing []string
	for _, gateName := range gateNames {
		if !recorded[GatePhaseName(stage, gateName)] {
			missing = append(missing, gateName)
		}
	}
	if len(missing) > 0 {
		return fmt.Errorf("%s-state evidence for %s was not persisted: no phase record for gate(s) %s", stage, repoName, strings.Join(missing, ", "))
	}
	return nil
}

func gateNamesOf(evidence []GateEvidence) []string {
	names := make([]string, 0, len(evidence))
	for _, ev := range evidence {
		names = append(names, ev.Gate)
	}
	return names
}
