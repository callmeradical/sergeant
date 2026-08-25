# Product Requirements: Task-Tracking Export

Status: Draft, awaiting explicit human PRD approval

Extends: `docs/prd-sergeant-v2.md`, section 8 open question "What
task-tracking integration is required in the Go-native model?", and D4
("Sergeant stores intents and bullets itself... Exporting a read-only copy
to a task tracker is optional.")

## Summary

v1 integrated directly and bidirectionally with Marcus `td`: `sgt-td-create`,
`sgt-td-list`, and `sgt-td-memory` created tasks, read them back, and used
`td` as a secondary source of truth for fleet state. AGENTS.md (D7) forbids
v2 from closing this gap by shelling out to `td` or any v1 script, and D4
already settles the shape the replacement must take: Sergeant owns intents
and bullets as first-class rows with referential integrity to worktree,
branch, commit, and PR — it cannot enforce its own rules (D2, D3, D5, D6)
about data it does not own. A second system holding writable, authoritative
copies of that state would let the two disagree about what is actually true.

This PRD defines a **read-only export** of intents and bullets to an
external task tracker, not a second integration point for Sergeant's own
state machine.

## Problem

Today, an operator who wants to see Sergeant's work items alongside their
other team or personal task tracking has no way to do so — the only view is
Sergeant's own dashboard. `internal/config/config.go`'s `DAGStage.TD` field
is parsed from project YAML and never read anywhere in `internal/`; it is a
stub left over from an earlier design, not a working integration. There is
no path today, partial or otherwise, from an Intent or Bullet row to
anything outside Sergeant's own store.

Without this, "what task-tracking integration is required in the Go-native
model" (the open question this PRD answers) remains unanswered, and the gap
AGENTS.md names is real: an operator who relied on v1's `td` integration for
visibility loses it outright with no replacement.

## Proposal

Add an optional, one-way export of intent and bullet state to an external
tracker:

- Sergeant remains the sole writer of intent/bullet lifecycle state (D4
  unchanged — no new inbound integration, no CAS, no second authority).
- A project may configure an export target (initially: a single tracker
  backend, chosen for having a stable JSON-in/JSON-out CLI contract — the
  specific backend is an implementation decision for OpenSpec, not this
  PRD's concern).
- Export is triggered by the same lifecycle transitions that already drive
  the dashboard (bullet status change, intent creation, seal/approval,
  merge) — no separate polling loop, no new source of truth for "did this
  happen."
- Exported records are labeled read-only / generated in the external
  tracker where the backend supports it, so an operator does not mistake
  them for something Sergeant will read back.
- If the export target is unreachable, exporting must never block, delay,
  or fail the underlying Sergeant operation it is exporting — this is
  observability, not part of the critical path (consistent with D5: state
  changes "just show up," they do not become a fourth interruption).

## Out of scope

- **Any inbound integration.** Sergeant never reads task state, holds, or
  transitions from the external tracker back into its own store. This
  PRD does not revisit D4.
- **Bidirectional sync, conflict resolution, or a merge protocol.** There is
  nothing to reconcile because the external copy is never authoritative.
- **Choosing the specific backend or its schema mapping.** That is an
  OpenSpec `design.md` decision informed by whatever tracker is actually in
  use when this is implemented, not a product requirement.
- **Migrating or importing existing v1 `td` task history.** v1 and v2 do not
  share a store; this PRD does not propose a one-time import.
- **`docs/prds/tasks-axi-migration.md`.** That document specifies migrating
  v1's own `_sgt-lib.sh` shell integration from `td` to Tasks AXI — it is a
  v1-scoped change to code this repository already deleted from `v2`
  (see the v1 shell-toolbelt removal). It is superseded, not extended, by
  this PRD and is not a dependency of it.

## Open questions

- Which external tracker is the first export target? Needs an operator
  decision before OpenSpec `design.md` can name a concrete API/CLI contract.
- Is export per-project opt-in configuration, or a global Sergeant setting?
  Leaning per-project (consistent with how every other view already scopes
  by project), but not settled here.
