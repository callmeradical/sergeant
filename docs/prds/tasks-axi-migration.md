# Product Requirements: Tasks AXI Migration

Status: Draft

Related research: `docs/research/tasks-axi-configurable-workflows.md`

Related epic: td-6986b6 "Wayfinder: replace td with Tasks AXI state machine"

---

## Summary

Sergeant currently uses Marcus `td` as its task tracking backend. Tasks AXI
(`tasks-axi` v0.2.3) is a structured alternative that offers TOON projection,
advisory file locks, atomic writes, a narrow `Store` interface for backend
swapping, and firstmate integration patterns that are directly relevant to
Sergeant's dispatch lifecycle.

This PRD specifies the requirements for migrating Sergeant's task integration
from Marcus `td` to Tasks AXI. It defines the state storage strategy,
compare-and-set boundaries, attempt history, TOON projection, compatibility
with firstmate's current backlog format, and the import cutover.

---

## Users

- **Coordinator agent:** creates tasks, transitions them across the Sergeant
  lifecycle, reads handoffs, and drives fleet state using the task tracker.
- **Worker agent:** reads task context, logs progress, records handoffs, and
  transitions to terminal states.
- **Human operator:** runs `tasks-axi` commands directly; reviews and filters
  the task backlog.
- **Maintainer:** must be able to swap the Tasks AXI version or backend without
  rewriting Sergeant command logic.

---

## Problem

Marcus `td` provides JSON output and `--work-dir` support that Sergeant depends
on, but it has four gaps for Sergeant's use:

**No configurable state machine.** Sergeant uses lifecycle states
(`dispatching`, `executing`, `reviewing`, `validating`, `delivering`) that have
no representation in `td`. These are currently tracked in fleet state files,
not in the task tracker.

**No structured compare-and-set.** Sergeant's response, acknowledgement, and
cleanup phases require that a state transition is only valid from an expected
prior state. Marcus `td` offers no CAS guard; Sergeant implements ad hoc
locking outside the tracker.

**No structured holds.** Sergeant's `needs_input` and `blocked` states require
holding a task with reason and kind metadata. Marcus `td` has no equivalent.
Sergeant models these as fleet-file status strings only.

**No TOON projection.** Marcus `td` output is plain text or JSON. Agent output
ergonomics require compact structured output, which Tasks AXI provides natively
through its `@toon-format/toon` integration.

---

## Product Principle

Tasks AXI is the canonical task view. Sergeant's fleet state files remain the
attempt journal and operational evidence store. Tasks AXI is never the sole
authority for response bodies, intent revisions, pane identities, or cleanup
evidence; those remain in fleet files. Migration must be atomic: either the
full import succeeds or td remains the active backend.

---

## Outcomes

1. All Sergeant commands that currently call `td` call `tasks-axi` instead.
2. Sergeant lifecycle states beyond `queued | in_flight | done` are stored in
   `task.meta.sergeant_state` and read at the CLI layer.
3. Transition idempotency is enforced at the file level by Tasks AXI's
   `assertUnchanged` CAS; Sergeant's generation-bound guards remain in fleet
   files.
4. `needs_input` and `blocked` states are represented as structured holds with
   the `captain` or `external` kind respectively.
5. Attempt history is stored in body appends (durable, human-readable) and
   in `task.meta.attempts` (structured, for machine queries).
6. Tasks AXI TOON output is available for all task listings.
7. The import from td to Tasks AXI is atomic: a failed mid-import leaves td
   as the active backend with no partial Tasks AXI records.
8. firstmate's existing backlog format is not modified by the migration.

---

## Non-Goals

- Modifying the Tasks AXI `STATES` enum or adding custom state names to the
  core model (Option C from the research). All Sergeant-specific states live
  in `meta.sergeant_state`.
- Contributing `expectedState` CAS guard upstream to Tasks AXI (Option B)
  as a prerequisite. Sergeant may do so later but does not block on it.
- Implementing a custom Tasks AXI backend.
- Replacing Sergeant's fleet state files with Tasks AXI records.
- Exposing response, intent, brief, or model content through Tasks AXI fields.
- Merging Sergeant tasks into firstmate's backlog file.

---

## Terminology

- **Sub-state:** a Sergeant-specific lifecycle state stored in
  `task.meta.sergeant_state`. Distinct from the Tasks AXI core states
  (`queued`, `in_flight`, `done`).
- **Hold:** a structured Tasks AXI hold (`Hold.reason`, `Hold.kind`,
  `Hold.until`) that suspends a task from appearing in the ready queue.
- **CAS:** compare-and-set. A conditional write that only succeeds if the
  current value matches an expected value.
- **TOON:** Token-Optimized Output Notation. The structured agent-facing output
  format provided by Tasks AXI.
- **Backlog file:** the Tasks AXI markdown backend file (`data/backlog.md` by
  default), one per configured repository.
- **Attempt record:** a structured entry in `task.meta.attempts` or a body
  append describing one dispatch attempt's outcome.

---

## State Storage Strategy

Sergeant uses Option A: `meta` sub-state, zero Tasks AXI changes.

Tasks AXI's `in_flight` state is the envelope for all active Sergeant work.
Sergeant's lifecycle sub-states (`dispatching`, `executing`, `reviewing`,
`validating`, `delivering`) are stored in `task.meta.sergeant_state` and read
by Sergeant's CLI layer using `tasks-axi list --json`.

`queued` maps to Sergeant's `open` (not yet dispatched).
`in_flight` + `meta.sergeant_state` maps to Sergeant's active states.
`done` maps to Sergeant's `done` and `failed` terminal states.
`held` (derived) maps to Sergeant's `needs_input` (captain kind) and
`blocked` (external kind).

### Sub-state lifecycle

| Sergeant state | Tasks AXI state | `meta.sergeant_state` | Hold? |
|---|---|---|---|
| `open` | `queued` | absent or `"open"` | no |
| `dispatching` | `in_flight` | `"dispatching"` | no |
| `executing` | `in_flight` | `"executing"` | no |
| `reviewing` | `in_flight` | `"reviewing"` | no |
| `validating` | `in_flight` | `"validating"` | no |
| `delivering` | `in_flight` | `"delivering"` | no |
| `needs_input` | `queued` (held) | `"needs_input"` | captain |
| `blocked` | `queued` (held) | `"blocked"` | external |
| `done` | `done` | absent | no |
| `failed` | `done` | `"failed"` | no |

---

## Compare-and-Set

File-level CAS (Tasks AXI's `assertUnchanged`) is sufficient for Sergeant's
single-process-per-backlog model. Sergeant must not rely on field-level CAS
within Tasks AXI for transition guards; those guards remain in Sergeant fleet
files using existing generation-bound checks.

One backlog file per project-repo pair. Multiple workers in the same repo
share one backlog; the 2.5-second advisory lock timeout in
`src/backends/lock.ts` is the concurrency boundary. Sergeant must not start
more than one simultaneous writer per backlog.

---

## Attempt History

Attempt history uses two parallel stores:

**Body appends** (durable, human-readable): Each dispatch attempt appends a
line to the task body using `TaskPatch.addBodyLines`. Format:
`attempt <n> [dispatched|failed|orphaned]: <reason> <ISO-timestamp>`.
Body appends survive round-trips and are searchable in the backlog.

**`meta.attempts`** (structured, machine-queryable): Each attempt appends a
structured record to `task.meta.attempts` (array). Record fields: `attempt`
(integer), `status` (string), `reason` (string), `timestamp` (ISO-8601),
`worktree` (path), `branch` (string). Reads use `tasks-axi get --json` and
parse `task.meta.attempts`. Writes use `update()` with a full `meta` patch
(shallow merge). Concurrent writers must use file-level CAS via the lock.

The `fm-decision-hold.sh` SHA-256 body pattern is the precedent for structured
durable records in the task body; Sergeant's attempt log uses the same
approach.

---

## TOON Projection

Sergeant uses `tasks-axi list --json` output as the input to a Sergeant-side
TOON formatter. Sergeant does not call the TypeScript library directly.

The formatter adds a `sergeant_state` column derived from
`task.meta.sergeant_state` using the `custom` extractor pattern. The formatter
is a thin shell or Node.js script that reads JSON on stdin and emits TOON to
stdout.

Sergeant's TOON formatter must not expose `task.meta.attempts`, response
bodies, intent content, or fleet file paths.

---

## Structured Holds

`needs_input` maps to a `captain`-kind hold. Reason contains the exact
decision requested (not the response body). Hold identity follows the pattern
`sergeant-decision-<task_id>-<generation>`.

`blocked` maps to an `external`-kind hold. Reason contains the external
dependency or blocker description. Hold identity follows the pattern
`sergeant-blocked-<task_id>-<dependency_id>`.

Hold resolution uses `tasks-axi unblock <hold-identity>` followed by
`tasks-axi transition <id> in_flight` to resume execution.

Sergeant must verify the hold exists before attempting resolution; a missing
hold is a non-fatal warning, not an error.

---

## Import Cutover

The migration from Marcus `td` to Tasks AXI is atomic at the repository level.

1. The importer reads `td list --json --work-dir <repo>` for all tasks in a
   repository.
2. For each task, it calls `tasks-axi add` with mapped fields.
3. If any `tasks-axi add` call fails, the entire import for that repository is
   aborted and td remains active. No partial Tasks AXI records are left.
4. After all tasks import successfully, a `tasks-axi-backend` marker file is
   written to the repository's Sergeant state directory. Sergeant commands
   check this marker to select the backend.
5. The operator verifies output before promoting the marker to active.

The importer must not migrate response bodies, intent content, or fleet file
paths into Tasks AXI fields.

---

## Backend Selection

Sergeant commands select the backend by checking for a
`.sergeant/tasks-backend` file in the repo's Sergeant state directory.

- Absent or `td`: use Marcus `td` commands.
- `tasks-axi`: use `tasks-axi` commands with the configured backlog path.

Both backends must support the same Sergeant task lifecycle operations:
create, start, log, handoff, review, approve/reject. The backend abstraction
lives in a single shared-lib function in `_sgt-lib.sh`; individual commands
call the abstraction, not the backend directly.

---

## Compatibility

- firstmate's `data/backlog.md` format is not modified. Sergeant uses a
  separate per-repo backlog path (`sergeant/backlog.md` or equivalent).
- Tasks AXI `>= 0.2.3` is required; Sergeant validates the version at startup
  when the tasks-axi backend is active.
- Node.js `>= 20` is required when the tasks-axi backend is active; Sergeant
  checks `node --version` and prints an actionable error if absent.
- Marcus `td` commands remain functional for repositories that have not
  migrated; no existing command changes behavior before the backend marker is
  written.

---

## Measurable Acceptance Criteria

1. All Sergeant commands that call `td` emit functionally equivalent output
   when the tasks-axi backend is active, with no behavioral regression in
   dispatch, respond, watch, validate, or cleanup.
2. `meta.sergeant_state` is written on every sub-state transition and read
   correctly by Sergeant's task list and context commands.
3. `needs_input` creates a `captain`-kind hold with the correct identity; the
   hold appears in `tasks-axi list --state held` output.
4. `blocked` creates an `external`-kind hold with the correct identity.
5. Hold resolution transitions the task back to `in_flight` and removes the
   hold from the held task list.
6. Each dispatch attempt appends a body line and a structured `meta.attempts`
   entry.
7. A failed mid-import leaves no Tasks AXI records; td remains active for
   that repository.
8. The TOON formatter emits a `sergeant_state` column derived from
   `meta.sergeant_state` and does not emit attempt records, response bodies,
   or fleet paths.
9. Tasks AXI version and Node.js version are checked at startup when the
   tasks-axi backend is active; absent or incompatible versions print an
   actionable error and exit non-zero before any mutation.
10. Repository-native tests and the full Sergeant shell test suite pass with
    both backends active in their respective test fixtures.

---

## Open Decisions

The following decisions remain open and must be resolved before implementation
dispatch:

1. **Backlog file path per repo.** Confirm the path convention for per-repo
   Tasks AXI backlogs (e.g., `<repo>/.sergeant/backlog.md`) that does not
   conflict with firstmate's `data/backlog.md`.

2. **Hold kinds sufficiency.** Confirm that `captain` (needs_input) and
   `external` (blocked) hold kinds adequately represent Sergeant's hold
   semantics, or whether Sergeant-specific kinds must be proposed upstream.

3. **TOON formatter runtime.** Decide whether the Sergeant TOON formatter is
   a shell script (no new runtime dependency) or a small Node.js script
   (consistent with tasks-axi's runtime).

4. **Upstream CAS contribution.** Decide whether to contribute the
   `expectedState` guard (Option B) to Tasks AXI upstream as a separate
   effort, independent of this migration.

---

## Delivery Boundary

This PRD authorizes specification and implementation of the Tasks AXI migration
for Sergeant. It does not authorize changes to firstmate's backlog format or
runtime. Open decisions must be resolved and recorded before implementation
dispatch.
