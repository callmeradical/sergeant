# Product Requirements: Data Retention and Rotation

Status: Draft, awaiting explicit human PRD approval

Extends: `docs/prd-sergeant-v2.md` §8's open question "What evidence
retention, export, and operator deletion controls are required?" — this
PRD answers it. It also governs `docs/prd-pipeline-artifacts.md`'s
long-term lifecycle, which that PRD explicitly defers here.

## Summary

Every run, phase, envelope, delivery, and (once `prd-pipeline-artifacts.md`
ships) artifact sergeant records is currently kept forever in
`sergeant.db` and, for artifacts, on disk. `automated-fleet-cleanup`
already reclaims worktree disk space on a schedule, but nothing rotates,
aggregates, or bounds the growth of the durable *record* — the database
rows and artifact files themselves. Left unaddressed, a long-running
self-hosted factory accumulates history indefinitely: query latency
degrades, disk usage grows without bound, and the one export path that
exists today (`task-tracking-is-a-readonly-export`) is read-only and
opt-in, not a retention mechanism.

## Problem

Analytics (`work-analytics`) already computes aggregate counts by scanning
every run/phase/bullet row directly — a design that gets slower, not just
larger, as history accumulates, since there is no pre-aggregated rollup to
read instead. Artifacts (once shipped) are the fastest-growing storage
class by bytes (images/traces vs. text rows). Envelopes and deliveries
accumulate one append-only row per state transition, by design (R5.3), with
no described end to that growth. None of this has ever been a problem
during this session's short-lived testing, but it is a correctness and
operability gap for the product's actual target use (a long-running,
self-hosted factory), and it is the PRD's own explicitly named open
question.

## Proposal

- **Retention horizon is configurable per project**, not hardcoded — a
  factory owner decides how long to keep detailed records, the same
  posture as every other factory-level policy (gates, retries) in
  `config.Project`.
- **Aggregate before deleting, don't just delete.** Before a run/phase/
  envelope/delivery row passes its retention horizon, its contribution to
  `work-analytics`' aggregate counts (run/phase/bullet totals by outcome,
  agent, model, provider, work type) is rolled into a durable summary row,
  so historical totals remain accurate after the detailed rows are gone.
  This is the same principle `output-redaction`/`envelope-schema` already
  apply to individual fields — never silently lose truth, make what's kept
  and what's dropped explicit — applied to whole rows instead of field
  content.
- **Artifacts rotate on their own, likely shorter, horizon.** Given
  artifacts are the largest-by-bytes class and are supplementary evidence
  (the phase/gate's pass/fail result and text output remain the
  authoritative record even after an artifact is pruned), they are
  expected to have their own, likely shorter, configurable retention
  horizon rather than sharing the run/phase horizon.
- **Export before delete is available, not mandatory.** An operator who
  wants to keep full history beyond the configured horizon can already use
  `task-tracking-is-a-readonly-export` (or a future equivalent) to pull
  records out before rotation deletes them; rotation itself does not block
  on or require a successful export.
- **Rotation is observable.** The dashboard/CLI can report when rotation
  last ran, how many rows/artifacts it aggregated or removed, and how many
  historical rows remain — an operator should never discover retention
  behavior by noticing data is simply gone.
- **Rotation never removes evidence for a run that is not yet in a
  terminal state**, and never removes evidence for a bullet that has not
  reached `merged` — mirroring R6.5's existing "cleanup refuses to remove
  active or diagnostically incomplete" principle, extended from worktrees
  to database rows.

## Out of scope

- **A general-purpose backup/restore feature.** This PRD is about bounding
  ongoing growth, not disaster recovery.
- **Per-row operator-triggered deletion** ("delete this one run's
  evidence") — that is a distinct, smaller feature `docs/prd-sergeant-v2.md`
  §8 also gestures at ("operator deletion controls") but this PRD scopes
  itself to scheduled, policy-driven rotation, not ad hoc manual deletion.
- **Cross-project or cross-factory data aggregation/reporting.** Rotation
  and its aggregate rollups are scoped per project, matching every other
  policy in this PRD family.
- **Changing what `automated-fleet-cleanup` already does to worktree
  disk space.** That capability is unchanged by this PRD; this PRD is
  about database rows and artifact files, a different resource.

## Open questions

- Exact default retention horizons (for runs/phases, envelopes/deliveries,
  and artifacts respectively) — a design/config-default decision, not fixed
  by this PRD.
- Whether the aggregate rollup is a new dedicated table or computed
  on-the-fly and cached — an implementation decision for OpenSpec's
  `design.md`.
- Whether rotation runs as a background loop (same shape as
  `runFleetCleanupLoop`) or only on explicit operator/CLI trigger for v1 of
  this capability.
