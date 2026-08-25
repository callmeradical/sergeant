# Proposal — Task tracking is a read-only export

## Repository

One repository: `sergeant-v2`.

## Requirements served

**D4** — "Sergeant stores intents and bullets itself... Exporting a
read-only copy to a task tracker is optional." This change is that optional
export; it is not a second write path for intent/bullet state.

**`docs/prd-sergeant-v2.md` section 8**, open product question: "What
task-tracking integration is required in the Go-native model?" This change
answers it: a read-only export, not an integration a caller writes back
through.

PRD: `docs/prd-task-tracking-export.md`.

## Problem

`internal/config/config.go`'s `DAGStage.TD` field (line 87) is parsed from
project YAML and never read anywhere in `internal/` — confirmed by grepping
every reference to `.TD`; the only hit is the struct field itself. There is
no code path today, partial or otherwise, from an `IntentRecord` or
`BulletRecord` to anything outside Sergeant's own SQLite store. An operator
who wants Sergeant's work items visible alongside other task tracking has
only the dashboard.

Sergeant already has exactly the mechanism this needs, unused for this
purpose: `internal/store/changes.go`'s durable, ordered `changes` table.
Every intent/bullet write already appends a transition there
(`CreateIntent`, `UpdateIntentStatus`, `CreateBullet`, `UpdateBulletStatus`,
`updateBulletStatusAndReason`, all via `recordTransition`) purely so the
dashboard's SSE stream can replay from a cursor instead of polling on a
timer (D10's subscribe/snapshot/replay model). Nothing today reads that log
for any purpose other than the dashboard.

## Proposal

Add a second, independent reader of the existing `changes` log — not a new
write hook, and not a change to `recordTransition` or any of its callers:

- A new `internal/export` package defines `Target`, a small interface
  (`Export(ctx context.Context, rec Record) error`) for "something that can
  receive one exported record." It is defined in `internal/export` (the
  consumer), not by whichever backend implements it later — the backend
  itself is out of scope for this change (PRD, "Out of scope").
- A `Runner` (`internal/export/runner.go`) holds a `*store.Store` and a
  `Target`. It polls `Store.ListChangesSince(cursor, 0)` filtered to
  `store.ChannelIntent`/`store.ChannelBullet`, projects each matching
  `ChangeRecord` into a `Record` (id, project, repo, status, position,
  merge-order, timestamps — see design.md for the exact shape and
  redaction), calls `Target.Export`, and advances its cursor only after a
  successful call.
- The cursor is durable (a new one-row table, `migrateAddTables`
  convention) so a restart resumes rather than re-exporting or silently
  skipping. A failed `Target.Export` call is logged and retried on the next
  tick with the same cursor — it never advances past a record it could not
  deliver, and it never blocks, delays, or fails the Sergeant operation
  that produced the original transition, because this reader runs
  entirely out of band from the write path that already returned before
  the export loop even wakes up.
- Configuration: a new optional `Export *ExportConfig` field on
  `config.Project`, following the exact pattern `Graphify *Graphify`
  (D9) already established — a pointer, so "no `export:` block" is
  distinguishable from "an empty one," and preserved on save by the
  existing YAML-node round-trip the same way `Graphify` already is.

## Out of scope

- **Which backend implements `Target` first.** An implementation decision
  for whoever builds against this interface, informed by whatever tracker
  is actually in use — not a product requirement (PRD, "Out of scope").
- **Any inbound path.** `Target` has no method that returns tracker state
  into Sergeant. D4 is not revisited.
- **Modifying `recordTransition` or any of its callers.** The export
  `Runner` is a new consumer of the existing log, not a change to how or
  when transitions are written.
- **Exporting anything other than `ChannelIntent`/`ChannelBullet`.**
  `ChannelRun`, `ChannelPhase`, `ChannelEnvelope`, and `ChannelProgress`
  changes are not task-tracker-shaped and are not exported by this change.
