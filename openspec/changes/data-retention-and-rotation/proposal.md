# Proposal — Data retention and rotation

## Repository

One repository: `sergeant-v2`. Standalone.

## Requirements served

`docs/prd-data-retention-and-rotation.md` (full text), answering
`docs/prd-sergeant-v2.md` §8's open question "What evidence retention,
export, and operator deletion controls are required?" Also governs the
long-term lifecycle `docs/prd-pipeline-artifacts.md` explicitly defers to
this change.

## Problem

`Store.AllRunsForAnalytics`/`AllBulletsForAnalytics` (`internal/store/analytics.go`)
scan every run/bullet row, unbounded, every time `work-analytics` is
computed. Envelopes and deliveries accumulate one append-only row per
state transition by design (R5.3), with no described end. Once
`pipeline-artifacts` ships, captured screenshots/traces become the
fastest-growing storage class by bytes. Nothing today rotates, aggregates,
or bounds any of this — a long-running self-hosted factory (the product's
actual target use, per `docs/prd-sergeant-v2.md`'s vision) accumulates
history indefinitely.

## Proposal

- A project opts in via a new `retention:` block in its YAML (nil/absent
  means retention is disabled for that project — same "unset, not silently
  a zero value" convention `Export`/`Graphify` already use), naming a
  runs/phases/envelopes/deliveries horizon and a separate, typically
  shorter, artifacts horizon.
- A background loop, same shape as `automated-fleet-cleanup`'s
  `runFleetCleanupLoop`, periodically rotates each opted-in project: for
  runs past their horizon, in a **terminal** state, whose intent's bullets
  (if any) are **all merged**, it folds that run's contribution into a
  durable per-project rollup row (`retention_rollups`) and deletes the raw
  run/phase/envelope/delivery rows. Artifacts rotate independently, on
  their own horizon, regardless of whether their parent run has rotated.
- `work-analytics`' aggregate counts are computed as rollup totals plus
  whatever raw rows have not yet rotated — historical totals stay accurate
  after detailed rows are gone.
- Rotation is observable: the existing `GET /api/analytics` response and
  its dashboard drawer gain a small retention summary (last rotation time,
  rows/artifacts rotated last pass) — an operator never discovers rotation
  by noticing data is simply gone.
- Export via `task-tracking-is-a-readonly-export` remains available before
  rotation deletes anything, but rotation does not block on or require it.

## Out of scope

- General backup/restore.
- Per-row, operator-triggered manual deletion.
- Cross-project aggregation or reporting.
- Any change to what `automated-fleet-cleanup` does to worktree disk
  space — a different resource from the database rows and artifact files
  this change governs.
