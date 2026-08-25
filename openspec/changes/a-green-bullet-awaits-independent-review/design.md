# Design — A green bullet awaits independent review

## Ownership

One repository, `sergeant-v2`. Touches `internal/dag/engine.go` (`RunStage`'s
phase switch), `internal/handoff/envelope.go` (new `ReviewFinding` type and
`ReviewFindings` reader, mirroring the existing `BlockedReason`), and
`internal/runner/runner.go` (a new small helper to produce the diff a review
prompt needs — no changes to `RunAgentPhase`'s signature or dispatch
mechanism).

## Finding shape, mirroring `BlockedReason`'s existing convention

`internal/handoff/envelope.go` gains:

```go
// ReviewFinding is one judgment an independent review phase recorded about
// a bullet's diff. Severity values below "error" (info, warning) are
// recorded but change nothing; "error" fails the review phase, which — via
// the same path a-stuck-bullet-is-blocked-not-failed already built — moves
// the bullet to blocked, carrying Summary as BlockedReason.
type ReviewFinding struct {
	Axis        string `json:"axis"`
	Severity    string `json:"severity"` // "error" | "warning" | "info"
	Summary     string `json:"summary"`
	Disposition string `json:"disposition"`
}

// ReviewFindings reads an optional findings array out of an envelope
// payload, the same nesting BlockedReason already uses and for the same
// reason: payload is already unconditionally redact.JSON'd before
// persistence, so nesting here is redacted for free rather than needing a
// second call site. Returns nil, never an error, for a payload that is not
// a JSON object, carries no findings key, or whose findings do not decode —
// a malformed report is "no findings", not a crash.
func ReviewFindings(payload json.RawMessage) []ReviewFinding {
	if len(payload) == 0 {
		return nil
	}
	var fields struct {
		Findings []ReviewFinding `json:"findings"`
	}
	if err := json.Unmarshal(payload, &fields); err != nil {
		return nil
	}
	return fields.Findings
}

// HasBlockingFinding reports whether any finding is severity "error" — the
// one predicate RunStage needs to decide whether a review phase passed.
func HasBlockingFinding(findings []ReviewFinding) bool {
	for _, f := range findings {
		if f.Severity == "error" {
			return true
		}
	}
	return false
}
```

## `RunStage` special-cases `"review"` the same shape as `"test"`

`internal/dag/engine.go:332-365` today: `"test"` runs deterministic gates
via `PhaseRunner.RunCodeGate`; every other name (including `"review"`
today, since nothing recognizes it) falls to `default` and runs as an
ordinary `RunAgentPhase` call with a generic prompt. Add a case between
them:

```go
case "review":
	if e.phasePassed(runID, repoName, "review") {
		continue
	}
	diff, err := pr.DiffAgainstBase(ctx) // new; see below
	if err != nil {
		return fmt.Errorf("collecting diff for review phase on %s: %w", repoName, err)
	}
	prompt := reviewPrompt(diff, stage, repoName) // new; see below
	env, _, err := pr.RunAgentPhase(ctx, "review", prompt, e.Project.ResolvedRetries(repoName))
	if err != nil {
		return fmt.Errorf("review phase failed on repo %s: %w", repoName, err)
	}
	findings := handoff.ReviewFindings(env.Payload)
	if handoff.HasBlockingFinding(findings) {
		return fmt.Errorf("review phase on %s reported a blocking finding", repoName)
	}
```

Returning an error from `RunStage` for a blocking finding is exactly what
the existing `"test"` case already does for a failed gate (line 345) — it
is what makes the run conclude `"failed"`, which
`bulletStatusForRunOutcome`/`AdvanceBulletsForRun`
(`internal/ui/server.go:2255-2262`) already turns into a `"blocked"` bullet
with a reason. This proposal writes zero new store code for that
transition; `blockedReasonForRun` (`internal/ui/server.go:2278`) already
calls `handoff.BlockedReason` on each of the run's envelopes to build the
reason — it needs one addition: when the envelope is a `"review"` phase's
and carries a blocking `ReviewFinding`, use that finding's `Summary`
(joined, if more than one) as the reason with the same "last envelope
naming a reason wins" precedence the function already documents, instead of
falling through to the generic synthesized string.

## `PhaseRunner.DiffAgainstBase` — the new helper

```go
// DiffAgainstBase returns the unified diff of the worktree's current HEAD
// against the branch it was created from, for a review phase's prompt.
// Shells to git directly, the same way internal/dag/engine.go already
// creates and inspects worktrees (os/exec, no library dependency) — no new
// pattern introduced.
func (pr *PhaseRunner) DiffAgainstBase(ctx context.Context) (string, error) {
	cmd := exec.CommandContext(ctx, "git", "-C", pr.Worktree, "diff", "--merge-base", "HEAD")
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("git diff in %s: %w", pr.Worktree, err)
	}
	return string(out), nil
}
```

`--merge-base HEAD` (not a specific base ref) is deliberate: the worktree
was created by `internal/dag/engine.go` at a merge-base with the operator's
branch already recorded in git itself, so `git diff --merge-base` needs no
extra bookkeeping to name that ref — consistent with this codebase's
existing preference (seen in `a-sealed-bullet-awaits-explicit-approval`'s
design.md) for reusing what git already knows over adding a parallel
record of it.

## `reviewPrompt` — independence lives in what the prompt excludes

```go
// reviewPrompt builds the review agent's prompt from the diff and the
// stage/repo context only — deliberately NOT from any prior phase's
// envelope in this run. "Independent" (PRD) means the reviewer starts from
// the diff and the spec, not from reading the implementing agent's own
// account of itself; RunAgentPhase gives every phase a fresh headless
// process already, so the only thing that can leak shared context is what
// this function chooses to put in the prompt string.
func reviewPrompt(diff string, stage *config.DAGStage, repoName string) string {
	return fmt.Sprintf(
		"Review this diff for repo %s against its intent and OpenSpec change, if one is referenced. "+
			"Judge only what is in the diff and the referenced spec — you have not seen and must not assume "+
			"the implementing agent's own reasoning. Report findings as JSON: "+
			"{\"findings\":[{\"axis\":...,\"severity\":\"error\"|\"warning\"|\"info\",\"summary\":...,\"disposition\":...}]}.\n\nDiff:\n%s",
		repoName, diff,
	)
}
```

An OpenSpec change id, when the bullet resolves to one (O3), is resolved
the same way any other phase's brief would reference it — this design does
not add a second mechanism for finding a bullet's change id.

## Rejected alternatives

**Routing findings to an external tracker as their record of truth.**
Rejected per D4, same reasoning `prd-task-tracking-export.md` already
settled: Sergeant cannot enforce D5's routing rules (blocking → blocked,
non-blocking → just visible) about data an external system owns. Any
export is downstream and read-only, not this proposal's write path.

**A new top-level `Envelope.ReviewFindings` field instead of nesting in
`Payload`.** Rejected for the same reason `a-stuck-bullet-is-blocked-not-failed`
rejected a top-level `BlockedReason` field: `Payload` is already
unconditionally `redact.JSON`'d before persistence; a new top-level field
would need its own explicit redaction call site, reintroducing exactly the
"new field, new call site, easy to forget" shape that produced this
project's past redaction gaps.

**Making `"review"` part of `DefaultPipeline()`.** Rejected: the PRD is
explicit that this is additive, not required for every factory. Changing
`DefaultPipeline()` would silently add cost and a new failure mode
(a review agent dispatch) to every repo that configures no pipeline at all,
with no factory author having asked for it.

**A separate dispatch mechanism for "no shared context" instead of prompt
construction alone.** Considered rejected: every `RunAgentPhase` call
already starts an independent headless CLI process (confirmed in
`internal/runner/runner.go`) — there is no persistent session across phases
to isolate from in the first place. The only real risk is prompt
*content* accidentally carrying a prior phase's envelope forward, which
`reviewPrompt`'s signature (diff + stage/repo only, no envelope parameter)
makes structurally impossible rather than a convention to remember.

**Failing the whole run on any finding, not just `severity: "error"`.**
Rejected: the PRD explicitly carries over v1's severity family split
(`error` blocks, `warning`/`info` are recorded and visible only) —
collapsing that distinction would make every review phase as disruptive as
a blocking one, defeating the "everything else just shows up in the fleet
view" half of D5.
