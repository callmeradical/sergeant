# Proposal — Pipeline artifacts

## Repository

One repository: `sergeant-v2`. Standalone.

## Requirements served

`docs/prd-pipeline-artifacts.md` (full text). Extends R4.3-R4.5 (captured
output is sanitized, redacted, and bounded before storage) with a second,
binary evidence channel governed by the same boundedness principle, and
R5.6/R7.5 (dashboard exposes durable evidence).

## Problem

`internal/runner/runner.go`'s `RunCodeGate` and `RunAgentPhase` capture only
text (stdout/stderr, redacted and bounded via `redact.Text`/`redact.Truncate`).
A gate or phase that exercises the UI (a Playwright script, for example) has
no sanctioned place to leave a screenshot or trace that survives past the
run: anything written into the worktree is reclaimed by
`automated-fleet-cleanup`, and nothing durable ever records it. This is a
concrete, current gap — this session alone produced dozens of such
screenshots that sergeant has no record of.

Note on naming: `internal/dag/engine.go` already uses the word "artifact"
for a different concept (upstream handoff envelopes routed into a
downstream worktree, `RunStage`'s "Route upstream artifacts..." comment).
This proposal's "pipeline artifact" is unrelated — a file a gate/phase
command writes for evidence purposes — and the code introduced here uses
distinct names (`captured artifact`, `artifacts` table/package) to avoid
colliding with that existing usage.

## Proposal

- A gate/phase command receives `SERGEANT_ARTIFACT_DIR` in its environment,
  an empty directory created fresh inside the worktree before the command
  runs. Anything the command writes there is a candidate captured artifact.
- Immediately after `RunCodeGate`/`RunAgentPhase`'s command finishes
  (success or failure), sergeant reads that directory, copies each file it
  finds into a durable, per-run location outside the worktree
  (`~/.local/share/sergeant/artifacts/<run_id>/<phase_id>/<filename>`), and
  records one `ArtifactRecord` row per file. This happens synchronously,
  before the phase's own result is returned — well before any worktree
  reclaim, which only ever considers a run's *terminal* state, reached
  after every one of its phases has already returned.
- Capture is bounded (fixed max file count and total bytes per phase) and
  best-effort: a capture failure, or exceeding the bound, is recorded as a
  note on the phase (not silently dropped) but never turns a passing gate
  into a failing one.
- `GET /api/artifacts?run_id=<id>` lists a run's captured artifacts.
  `GET /api/artifacts/<id>/content` serves one artifact's bytes with its
  recorded content type, for inline image rendering.
- The dashboard's run detail view gains an "Artifacts" section directly
  beneath the existing pipeline/gates/delivery workflow graph
  (`#workflow-graph`), grouped by the phase/gate that produced them, shown
  only when the run has at least one.

## Out of scope

- Ad hoc artifacts from anything other than a dispatched run's own
  gate/phase execution.
- Video, streaming, or mid-run artifact preview.
- Artifact editing, annotation, or operator deletion.
- Long-term retention/rotation of captured artifacts — governed by the
  separate `data-retention-and-rotation` change.
