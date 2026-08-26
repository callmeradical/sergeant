# Product Requirements: Agent-Phase Prompts Are Durable, Run-Scoped Artifacts

Status: Draft, awaiting explicit human PRD approval

Extends: `docs/prd-pipeline-artifacts.md` (the capture mechanism this PRD
routes prompt files through) and `docs/prd-data-retention-and-rotation.md`
(the rotation mechanism this PRD closes a gap in).

## Summary

An agent phase's actual prompt (`.sergeant/prompt_<phase>.txt`) is real,
already-generated evidence — a record of exactly what an agent was asked to
do — but it is written directly into the worktree's `.sergeant/` directory,
a sibling of `.sergeant/artifacts/`, not inside it. `captureArtifacts` only
reads the latter, so the prompt is never captured durably: once
`automated-fleet-cleanup` reclaims the worktree (as soon as 7 days after
the run goes terminal), the prompt is gone, and the dashboard's Activity
view has been showing a dead worktree path this whole time (currently
rendered as an inert, non-clickable label — not a live link either).

Separately, closing that gap surfaced a second, real one: once an
artifact *is* captured durably (as `pipeline-artifacts` already does for
gate/phase-produced evidence), nothing ties its lifetime to its parent
run's. `data-retention-and-rotation`'s `rotateOneRun` deletes a run's
phases/envelopes/deliveries/row but never touches the `artifacts` table —
so an artifact can outlive the run that produced it indefinitely, as an
orphaned row, unless its own independent horizon happens to fire first.

## Problem

Decision D6/R4's evidence principles (durable, but not necessarily
forever, and never a dangling reference) are violated two ways today: the
most basic, always-present evidence (what was the agent actually asked to
do) isn't captured at all, and the mechanism that *does* capture evidence
has no upper bound tied to the thing it's evidence for.

## Proposal

- **An agent phase's prompt file is captured the same way any other
  pipeline artifact is** — written into (or copied into)
  `$SERGEANT_ARTIFACT_DIR` so `captureArtifacts`' existing capture,
  bounding, and durability guarantees apply to it with no new mechanism.
- **An artifact never outlives its parent run.** When a run rotates
  (`RotateProject`/`rotateOneRun`), every artifact recorded against that
  run's id is deleted (row and durable file) at the same time as its
  phases/envelopes/deliveries — an artifact's own configured horizon
  (`ArtifactsAfterDays`) can still delete it *sooner*, but the run's own
  rotation is now always the outer bound. "Once the pipeline goes away, we
  don't need to preserve it" — durable while the run exists, gone at the
  latest when the run is.

## Out of scope

- Changing what counts as a pipeline artifact for gate-produced evidence
  (screenshots, traces) — unaffected, already correct per
  `docs/prd-pipeline-artifacts.md`.
- Any change to `ArtifactsAfterDays`' own semantics as a possibly-shorter,
  independent horizon — this PRD only adds an upper bound, not a new lower
  one.
- Rendering the captured prompt in the dashboard's Activity view (showing
  it as a real, openable/readable artifact instead of today's inert
  label) — a natural follow-on once the prompt is actually captured
  durably, but a separate UI decision from the capture/retention question
  this PRD answers.
