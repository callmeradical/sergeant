# Proposal — A green bullet awaits independent review

## Repository

One repository: `sergeant-v2`.

## Requirements served

**D3** — "TDD is enforced, not assumed." D3's gates prove a diff passes its
own deterministic checks. They cannot and do not prove the diff does what
the intent (or, per O3, the OpenSpec change it resolves to) actually asked
for. This proposal adds the second, independent check AGENTS.md names as
missing v2 scope ("independent review workers").

**D2** — "Trust the workflow, review the inference." A factory-configured
`review` phase is workflow-defined the same way `plan`/`build`/`test` are —
it executes because the factory's author configured it, not because a
model decided a bullet needed reviewing.

**D5** — "Three interruptions only": (a) an inferred plan awaits approval,
(b) a bullet is blocked on a human decision, (c) a bullet is ready for an
irreversible step. This proposal adds **no fourth interruption type**. A
review finding either changes nothing a human is notified about (recorded,
visible in the fleet view) or routes through (b), reusing the exact
mechanism `a-stuck-bullet-is-blocked-not-failed` already built
(`Store.AdvanceBulletsForRun` writing `"blocked"` with a
`BulletRecord.BlockedReason`, sourced via `internal/handoff`'s envelope
payload convention). No new bullet status, no new notification path.

PRD: `docs/prd-independent-review-phase.md`.

## Problem

`internal/dag/engine.go`'s `RunStage` (line 332) iterates a repo's pipeline
(`PipelineFor`, default `["plan","build","test"]`) and special-cases exactly
one phase name, `"test"` (line 334), running it as deterministic gates via
`PhaseRunner.RunCodeGate`. Every other phase name, including any factory
author already writes as `"review"` in their `Pipeline` config today, falls
through to the `default` case (line 352): it is dispatched as an ordinary
agent phase via `PhaseRunner.RunAgentPhase` with a generic constructed
prompt (`"Execute %s phase for stage %s on %s"`, line 358) when the factory
sets no `stage.Brief`. Its outcome is judged by the same pass/fail logic as
any other agent phase — a "review" phase today is agent-authored work, not
an independent judgment of other agent-authored work, and its result cannot
route a bullet anywhere but the run's own pass/fail path
(`bulletStatusForRunOutcome`, `internal/ui/server.go:2320`, mapping
`passed→green`, `failed→blocked`).

There is no point in the pipeline where a second, differently-purposed
agent judges a first agent's diff against the intent it was given, and no
data shape for what that judgment produces (a severity-tagged finding, not
a pass/fail exit code).

## Proposal

Special-case `"review"` in `RunStage`'s phase switch, the same shape as
`"test"`:

- Construct the review agent's prompt from the bullet's diff, its intent
  (via the canonical rendering, if `prd-canonical-intent-brief.md` has
  landed; otherwise the existing brief construction used for other
  phases), and — when the bullet resolves to an OpenSpec change (O3) — that
  change's `proposal.md`/`design.md`/`specs/*/spec.md` contents. The prompt
  MUST NOT include any prior phase's envelope payload or reasoning from
  this same run: independence means the reviewer starts from the diff and
  the spec, not from reading the implementing agent's own explanation of
  itself.
- Dispatch via `PhaseRunner.RunAgentPhase` exactly as any other phase is
  dispatched — no new dispatch mechanism, since every `RunAgentPhase` call
  already starts a fresh headless CLI process with no persistent
  cross-phase session (see design.md for exactly how the prompt's own
  content, not the dispatch mechanism, is what must change to be
  "independent").
- The review agent reports structured findings — `axis`, `severity`,
  `summary`, `disposition` — nested inside its envelope's existing
  `payload` object, mirroring the `blocked_reason` convention
  `a-stuck-bullet-is-blocked-not-failed` established (payload is already
  redacted unconditionally before persistence; a new top-level `Envelope`
  field would need its own redaction call site).
- A `RunStage` review phase that reports any blocking-severity finding
  fails the phase (mirroring how a failed gate fails the `"test"` phase),
  which makes the run conclude `"failed"` and, via the existing
  `bulletStatusForRunOutcome`/`AdvanceBulletsForRun` path, the bullet
  becomes `"blocked"` with the finding as `BlockedReason` — no new status,
  no new store method for the state transition itself.
- Non-blocking findings do not fail the phase. They are recorded (see
  design.md) and visible in the fleet view; they interrupt no one.
- A repo whose `Factory.Pipeline` does not list `"review"` is entirely
  unaffected — `RunStage`'s loop only special-cases a name that is present.

## Out of scope

- **Routing findings to an external task tracker as their record of
  truth.** D4: Sergeant owns this data. See `prd-task-tracking-export.md`
  for the read-only export path, which this proposal does not depend on or
  implement.
- **A default/mandatory review phase.** `PipelineFor` and `DefaultPipeline`
  are unchanged; a factory that never lists `"review"` behaves exactly as
  today. This proposal adds a phase name the engine knows how to
  special-case, not a new default.
- **Per-axis review phases** (mirroring v1's `--axis <axis>` routing into
  several independent checks). One review phase producing axis-tagged
  findings is this proposal's scope; splitting further is a future
  extension the PRD explicitly defers.
- **A dashboard UI surface for browsing findings.** Findings are recorded
  and readable via the same store access pattern as any other bullet
  evidence; a dedicated findings view is not this proposal's scope.
- **Any change to `a-stuck-bullet-is-blocked-not-failed`'s mechanism.**
  This proposal is a new *caller* of the existing blocked path, not a
  change to how blocking or `BlockedReason` work.
