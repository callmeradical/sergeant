# Product Requirements: Pipeline Artifacts

Status: Draft, awaiting explicit human PRD approval

Extends: `docs/prd-sergeant-v2.md` R4.3-R4.5 (captured output must be
sanitized, redacted, and bounded before it is stored) and R5.6/R7.5
(dashboard exposes durable evidence). This PRD adds a second evidence
channel — binary artifacts, not text — governed by the same durability and
boundedness principles, and gives it a home in the dashboard: beneath the
pipeline/gates/delivery graph for the run that produced it.

## Summary

A gate or agent phase that exercises the UI (this session's own Playwright
verification scripts are the concrete case) produces screenshots and traces
that currently live only in a scratch directory on the machine that ran
them. Nothing durable records them, nothing in the dashboard shows them,
and the worktree they'd naturally land in is reclaimed by
`automated-fleet-cleanup` on a schedule — so even an ad hoc "just leave the
files in the worktree" approach loses them. This PRD adds a durable,
bounded artifact channel: a phase/gate writes files to a known directory,
sergeant copies them out before the worktree can be reclaimed, records
them against that run, and the dashboard renders them beneath the
pipeline/gates/delivery graph for the run that produced them.

## Problem

Text evidence (captured output) already has a full lifecycle: captured,
redacted, bounded, stored, rendered (`output-redaction` capability). Binary
evidence has none of that. A Playwright-based UI gate that wants to prove
"the button moved, here's the screenshot" has no sanctioned place to put
the screenshot that survives past the run. This is a real, current gap —
not a hypothetical one — since this session generated dozens of such
screenshots that exist nowhere sergeant knows about.

## Proposal

- **Capture convention.** A phase or gate command receives a directory
  path (via an environment variable, e.g. `SERGEANT_ARTIFACT_DIR`) scoped
  to that phase, inside its worktree. Anything the command writes there
  before exiting is a candidate artifact. Nothing is required — a phase
  that writes nothing produces no artifacts, same as today.
- **Durable capture, before reclaim.** Immediately after the phase/gate
  finishes (success or failure — a failing UI test's screenshot is often
  the most valuable one), sergeant copies every file found in that
  directory out of the worktree into a durable, per-run location
  independent of the worktree's lifecycle, and records one metadata row
  per file (run id, phase kind/name, repo, filename, content type, size,
  durable path, captured_at). This must happen before
  `automated-fleet-cleanup` can reclaim that worktree — the same ordering
  guarantee that capability's own eligibility check already respects for
  "diagnostically incomplete" runs (R6.5).
- **Bounded, not redacted.** R4.4's redaction requirement is a text-scrubbing
  rule and does not apply to binary content — a PNG cannot be
  string-matched for a credential shape. Instead, boundedness (R4.5's
  sibling principle) applies: a fixed cap on artifact count and total bytes
  per phase, with anything over the cap dropped and the drop made visible
  in the recorded metadata, not silent.
- **Never fails the phase.** Artifact capture is best-effort, the same
  posture already established for other side-channel capture in this
  codebase (e.g. SSE progress sampling in `dispatch.go`): a failure to copy
  or record an artifact must never turn a passing gate into a failing one.
- **Surfaced in the dashboard beneath the workflow graph.** The run detail
  view's existing pipeline/gates/delivery graph gets a new "Artifacts"
  section directly beneath it, listing this run's captured artifacts
  (image thumbnails inline, other file types as named links), grouped by
  the phase/gate that produced them. Absent for a run with none — this is
  additive, not a mandatory new element every run must show.

## Out of scope

- **Ad hoc/manual artifacts not produced by a dispatched run.** A
  screenshot an operator or agent takes outside of a phase/gate execution
  (e.g., manual exploratory testing) has no dispatched run to attach to and
  is not this PRD's concern.
- **Video, streaming, or live artifact preview during a running phase.**
  Artifacts are captured and shown only after the phase that produced them
  has finished.
- **Artifact editing, annotation, or deletion tooling.** Read-only evidence,
  same posture as captured output today.
- **A general-purpose file upload or attachment feature.** Artifacts are
  strictly the output of a phase/gate's own execution, not operator-supplied
  files.
- **Long-term retention policy for artifacts.** How long a captured artifact
  is kept is governed by `docs/prd-data-retention-and-rotation.md`, not this
  PRD — this PRD only establishes that artifacts are captured durably and
  bounded per-phase; overall lifecycle/rotation is a separate concern.

## Open questions

- Exact durable storage location (filesystem tree under
  `~/.local/share/sergeant/artifacts/<run_id>/`, vs. SQLite blob storage) —
  an implementation decision for OpenSpec's `design.md`, not a product
  requirement. Given images can be several hundred KB to a few MB each, a
  filesystem tree with DB-recorded metadata (mirroring how delivery
  evidence already separates metadata from content) is the likely answer,
  but is not binding here.
- Exact per-phase count/byte cap values — a design decision, not fixed by
  this PRD.
- Whether the MCP surface should also expose artifact listing/retrieval for
  a dispatched agent to read back its own prior run's evidence — left open,
  not required for v1 of this capability.
