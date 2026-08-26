# Tasks AXI Configurable Workflows Research

**Date:** 2026-07-25
**Task:** td-ea7511 (wayfinder epic td-6986b6)
**Sources inspected:**
- `/tmp/opencode/tasks-axi` — tasks-axi v0.2.3 full TypeScript source
- `/home/larscromley/dev/firstmate` — live firstmate installation (consumer of tasks-axi)
- Key files: `src/model.ts`, `src/store.ts`, `src/context.ts`, `src/config.ts`, `src/derive.ts`, `src/toon.ts`, `src/view.ts`, `src/errors.ts`, `src/backends/markdown.ts`, `src/backends/lock.ts`, `src/public-followup.ts`, `src/skill.ts`, `bin/fm-decision-hold.sh`, `bin/fm-backlog-handoff.sh`, `bin/fm-tasks-axi-lib.sh`, `.agents/skills/decision-hold-lifecycle/SKILL.md`

---

## Question

What is the smallest deep interface Tasks AXI needs to support a configurable
Sergeant seven-state machine, compare-and-set (CAS) transitions, structured
holds, attempt history, and TOON projection without hard-coding Sergeant?

---

## What Tasks AXI v0.2.3 Actually Provides

### Persistent state model (`src/model.ts`)

Tasks AXI uses **three explicit states** mapped directly to markdown sections:

```
"queued" | "in_flight" | "done"
```

Two additional states are **derived in the CLI layer** (never stored):

```
"blocked"  — queued + unresolved blocked-by dep
"held"     — queued + active Hold struct
```

The `Hold` struct is fully structured (`reason: string`, `kind?: HoldKind`,
`until?: YYYY-MM-DD`). `HoldKind` is a closed enum: `captain | external | load | parked | future`.

The `Task` struct carries a free-form `meta?: Record<string, unknown>` bag — the
one official escape hatch for caller-specific fields not in the schema.

### Store interface — the single narrow seam (`src/store.ts`)

```typescript
interface Store {
  capabilities(): Capabilities;
  create(input: TaskInput): Promise<Task>;
  get(id: string): Promise<Task | null>;
  update(id: string, patch: TaskPatch): Promise<TaskUpdateResult>;
  remove(id: string): Promise<Task>;
  list(query: TaskQuery): Promise<{ items: Task[]; total: number }>;
  transition(id: string, to: State, opts?: TransitionOpts): Promise<Task>;
  addDep(id: string, dep: Dep): Promise<boolean>;
  removeDep(id: string, dep: Dep): Promise<boolean>;
  updatePublicFollowup(id: string, mutation: PublicFollowupMutation): Promise<Task>;
  prune?(options: PruneOptions): Promise<PruneResult>;
  render?(): Promise<number>;
}
```

`Store` is the only seam between the CLI command layer and any backend. The
command layer calls only `Store` methods — it has no knowledge of the concrete
backend class. Swapping in a new backend requires only satisfying this interface.

### CAS — where it lives

Tasks AXI has **two CAS patterns**:

1. **`assertUnchanged` in `MarkdownStore`** (`src/backends/markdown.ts:477-485`):
   Load source → mutate in memory → compare disk snapshot → atomic rename write.
   This is a file-level CAS on the entire backlog (avoids lost-update with
   concurrent writers). It throws `CONFLICT` if the file changed between load and
   write. This is **not** field-level CAS.

2. **`updatePublicFollowup`** (`src/store.ts:74-78`, `src/backends/markdown.ts:1015-1099`):
   A full CAS on the `public_followup` struct using `expectedRevision` (integer)
   plus `expectedPublicFollowup` (full pre-mutation payload). Throws `CONFLICT` if
   the revision or canonical JSON does not match. This is the only **field-level
   CAS** in the current API surface.

There is **no generic field-level CAS** for arbitrary state transitions. The
`transition(id, to, opts)` call is unconditional — it does not accept an
`expectedState` guard.

### Structured holds — fully operational (`src/model.ts`, `src/commands/state.ts`)

Hold creation: `tasks-axi hold <id> --reason "<text>" [--until YYYY-MM-DD] [--kind captain|...]`

The `Hold` struct is stored in the task record and survives round-trips. The
`ready` command excludes active holds by default. `heldTasks()` and
`isHoldActive()` in `src/derive.ts` are CLI-layer pure functions derived from
the full task list, not stored enums. Date gates are evaluated at query time
against a mockable clock.

**firstmate's usage** (`bin/fm-decision-hold.sh`): Creates `captain`-kind holds
with identity `<origin>-decision-<key>`, blocks dependent work against those
holds, verifies the hold before resolution, records a SHA-256 digest of the
captain decision, routes via `unblock`, then marks done. Full lifecycle from
hold → resolve is ~450 lines of shell atop tasks-axi's structured hold API.
This is the most advanced hold usage observable in the codebase and it uses
exactly the existing hold surface — no extension required.

### Attempt history — not present

There is **no attempt history, retry counter, or attempt log** in the core
`Task` struct or in the `Store` interface. The `PublicFollowup` struct carries
`attempt_count` and `last_error` for its delivery sub-machine — but that is
specific to the public-followup obligation pattern, not a general task concept.

The closest general mechanism is:
- `task.meta: Record<string, unknown>` — untyped, no validation, no schema
- Body append: `TaskPatch.addBodyLines?: string[]` — idempotent line addition,
  good for prose logs but no structured schema

Any Sergeant-specific attempt history must be stored in `meta` or in a body
append. There is no structured attempt schema Tasks AXI will validate.

### TOON projection (`src/toon.ts`, `src/view.ts`)

TOON output is produced by `renderList` / `renderDetail` from `src/toon.ts`,
which call into the `@toon-format/toon` package's `encode()` function. The
projection is driven by `FieldDef[]` — an array of either `{ type: "field", key, as? }` 
or `{ type: "custom", as, fn }` extractors applied to flat task rows.

The full TOON row schema (`src/view.ts:toRow`) contains 17 derived fields:
`id, title, state, blocked, blocked_by, held, hold_reason, hold_kind, hold_until,
kind, repo, priority, created, closed, delivery_state, deps, links, body`

The `--fields` flag selects from `LIST_EXTRA_FIELDS` — an allow-listed set of
extra columns. Adding a custom field requires adding it to `toRow()` and
`LIST_EXTRA_FIELDS`. There is no plugin/hook system for custom field projection.

### Configurable workflow — what it means today

The `kind` field is a free-form string tag (`ship | scout | docs | status | task | captain | ...`).
The `Capabilities.customStates: boolean` flag in the store interface signals
whether a backend can represent states beyond `queued | in_flight | done` — but
no current backend implements this; `markdown` returns `customStates: true` as a
capability flag, but `transition()` only accepts the three core states.

**Configuration** in `.tasks.toml` covers: `backend`, `markdown.path`,
`markdown.archive`, `markdown.done_keep`. There is no workflow definition in
config — the three-state machine is hardcoded in `model.ts` and the commands.

---

## Source Seams — Exact Files

| Seam | File | Lines | What it owns |
|------|------|-------|--------------|
| State enum | `src/model.ts` | 12-13 | `STATES` const, `State` type |
| Hold struct | `src/model.ts` | 18-34 | `Hold`, `HoldKind`, hold kinds enum |
| Task struct | `src/model.ts` | 60-90 | Full task record, including `meta` |
| TaskPatch | `src/model.ts` | 112-128 | Mutation patch surface |
| TransitionOpts | `src/model.ts` | 149-158 | Options accepted by `transition()` |
| Store interface | `src/store.ts` | 56-84 | The only seam every backend must satisfy |
| Capabilities | `src/store.ts` | 18-32 | Backend capability negotiation |
| CAS (file-level) | `src/backends/markdown.ts` | 477-490 | `assertUnchanged` / `persist` |
| CAS (field-level) | `src/backends/markdown.ts` | 1015-1099 | `updatePublicFollowup` |
| CAS struct | `src/public-followup.ts` | 190-199 | `PublicFollowupMutation` (expectedRevision + expectedPublicFollowup) |
| TOON row | `src/view.ts` | 29-65 | `toRow` — all projectable fields |
| TOON schema | `src/view.ts` | 67-90 | `LIST_DEFAULT`, `LIST_EXTRA_FIELDS` |
| TOON encode | `src/toon.ts` | 39-55 | `renderList`, `renderDetail` |
| Context factory | `src/context.ts` | 18-41 | How backends are wired to CLI |
| Config | `src/config.ts` | 203-248 | `resolveConfig`, `.tasks.toml` parsing |
| Derive (projections) | `src/derive.ts` | 35-118 | `blockedIds`, `heldTasks`, `readyTasks`, `isHoldActive` |
| Lock + CAS (filesystem) | `src/backends/lock.ts` | all | Advisory lock, `atomicWrite`, `withLock` |
| Error codes | `src/errors.ts` | 7-13 | `CONFLICT` is the CAS failure code |

---

## Mapping to the Sergeant Seven-State Machine

The destination states are: `queued → dispatching → executing → reviewing → validating → delivering → done`.

Tasks AXI's persistent states are: `queued | in_flight | done`.

The gap: five of the seven Sergeant states map to no existing Tasks AXI state.
Tasks AXI's three-state machine is hardcoded in `STATES` (`model.ts:12`),
enforced in `transition()` (`store.ts:70`), and encoded in markdown section
headers (`backends/markdown.ts:68-70`).

### Three options, ranked by invasiveness

**Option A — Use `kind` + `meta` for Sergeant state within `in_flight`**

Map Sergeant's `dispatching | executing | reviewing | validating | delivering`
to sub-states stored in `task.meta.sergeant_state: string` and read at the CLI
layer. Tasks AXI's `in_flight` is the envelope; Sergeant's workflow is a
projection over `meta`. TOON output requires a custom `tasks-axi` wrapper or
a `--fields` extension that reads `meta.sergeant_state`.

- Cost: zero changes to Tasks AXI
- Tradeoff: `ready` and `list --state in_flight` return all in-flight items
  regardless of sub-state; Sergeant's caller must filter `meta.sergeant_state`
  client-side
- CAS: still file-level only; a CAS on `meta.sergeant_state` requires the
  caller to implement its own compare loop atop `update()` with full backlog
  reload

**Option B — Extend `transition()` to accept a guard (CAS over state)**

Add `expectedState?: State` to `TransitionOpts` (`model.ts:149`). The store
checks `task.state === opts.expectedState` before writing; throws `CONFLICT` if
not. This is a single-field CAS over the three core states.

- Cost: one-line model change + guard in `MarkdownStore.transition()` (≈15 lines)
- Doesn't address the five missing Sergeant states
- Useful even without state expansion to prevent lost-update on worker handoffs

**Option C — Configurable workflow definition (deep change)**

Add a `WorkflowDef` to config: an ordered list of state names with allowed
transitions. `model.ts` reads the configured list at init; `STATES` becomes
`string[]`; `transition()` validates against the configured machine;
`assertUnchanged` catches file races as before. Markdown sections are generated
from the configured state list.

- Cost: significant: model.ts, config.ts, all three markdown section patterns,
  the grammar parser, every command that hardcodes state names
- Breaks firstmate's current backlog format (three fixed section headers)
- Backward compat: existing backlog files have three sections; migration
  required for every home with an existing `data/backlog.md`
- This is the only option that gives Sergeant native TOON projection of its
  seven states without client-side re-mapping

---

## Compatibility and Version Implications

**Current pinned usage**: firstmate probes `>= 0.1.1` + `--archive-body` +
multi-ID `mv` (`bin/fm-tasks-axi-lib.sh`). Effective floor is **0.2.2** (where
`mv [<id>...]` landed).

**Sergeant would introduce a new floor**:
- For Option A: no version change required
- For Option B (`expectedState` guard): new minor version (0.3.0 or 1.0.0 if
  the project treats this as API-stable)
- For Option C (configurable workflow): breaking change; new major version;
  firstmate's existing backlogs would need scaffold migration

**Node.js requirement**: `>= 20` (from `package.json`). Sergeant's worker
environments must satisfy this.

**`@toon-format/toon ^2.1.0` and `axi-sdk-js ^0.1.7`**: both are runtime
dependencies. Sergeant's wrapper must carry or peer-depend on them if it
produces TOON output directly (vs. shelling out to the CLI).

---

## Attempt History — Concrete Design Gap

The seven-state machine implies failed/orphaned attempts return the item to
`queued` (or a `held` sub-state) with history. Tasks AXI has no attempt history
schema. The practical options are:

1. **Body append** — `addBodyLines: ["attempt 3 failed: timeout 2026-07-25"]`
   Survives round-trips, human-readable, searchable in body. Not structured —
   cannot be machine-queried without parsing prose.

2. **`meta.attempts: AttemptRecord[]`** — structured JSON in `meta`. Readable
   via `task.meta.attempts` but: `TaskPatch.meta` is a shallow merge
   (`{ ...task.meta, ...patch.meta }`); appending to an array requires
   read-modify-write with file-level CAS; no Tasks AXI validation.

3. **Separate Tasks AXI items for each attempt** — each dispatch creates a new
   task (e.g., `<id>-attempt-3`) that transitions to done/failed. The parent
   item accumulates `blocked-by` edges that clear as attempts complete. Verbose
   but fully native and queryable.

4. **Out-of-band Sergeant state** — keep attempt history in Sergeant's own
   fleet state files (`bin/_sgt-lib.sh` patterns) and write only current state
   into Tasks AXI. Tasks AXI is the canonical view; Sergeant's state dir is the
   attempt journal.

The firstmate `fm-decision-hold.sh` usage shows the most sophisticated pattern
in practice: it stores a SHA-256 digest, resolution identity, and routing list
in the task `body` field — structured enough to be parseable deterministically
but using the body as a durable record rather than `meta`.

---

## TOON Projection for Sergeant's States

The `toRow()` function in `src/view.ts` builds a flat record with all
projectable fields. The `--fields` flag selects from `LIST_EXTRA_FIELDS`.

For Sergeant's custom states to appear in TOON output, one of:

1. **Option A (meta)**: wrap the `tasks-axi list --json` output and inject
   `meta.sergeant_state` into a TOON-encoded output. No Tasks AXI change; 
   Sergeant builds its own projection layer.

2. **Option B/C**: extend `toRow()` to include a `sergeant_state` field derived
   from `meta.sergeant_state` (or from a configured state if Option C), and add
   it to `LIST_EXTRA_FIELDS`. Two files: `src/view.ts` and optionally
   `src/model.ts`. This requires forking tasks-axi or contributing upstream.

The `custom` extractor in `FieldDef` (`src/toon.ts:17-22`) allows arbitrary
computed fields from the flat row — so a caller-assembled row can include any
derived field — but this is only usable from TypeScript code calling the library
directly, not from the CLI.

---

## Rejected Alternatives

**Regex-parse the markdown backlog directly**: firstmate had an awk-based parser
that caused the body-orphaning bug fixed in PR #401. `fm-backlog-handoff.sh`
documents this explicitly: "Delegating the move is the durability end-state: it
removes the awk that used to re-implement block extraction." Sergeant must not
re-implement the parser; Tasks AXI's `mv` command is the atomic move primitive.

**Storing Sergeant state in the markdown section header**: e.g., `## Dispatching`.
This would work as a minimal format hack but is incompatible with tasks-axi's
three-section `STATES` enum. The parser only recognizes `## In flight`,
`## Queued`, and `## Done`. Custom section headers become `passthrough` sections
(no `state` field, never operated on by id).

**Using `blocked-by` dependencies to model worker holds**: firstmate already
does this — a captain-held item blocks dependent work. This is semantically
correct for "cannot proceed" but creates overhead (requires a separate hold item
per blocker) and does not express attempt history or retry state.

**Implementing a custom backend** (the `Capabilities.customStates` path):
`context.ts:24-29` currently throws `UNSUPPORTED` for any backend other than
`"markdown"`. A new backend satisfying `Store` could implement arbitrary states,
but the CLI command layer (`commands/state.ts:transition()`) only calls `store.transition(id, to)` 
with hardcoded `to: State` values. The commands do not pass custom state names —
a custom backend's extended state set is invisible to the CLI.

---

## Decisions Still Needed

1. **State storage strategy**: Option A (meta sub-state, zero Tasks AXI changes),
   Option B (add `expectedState` guard to transition), or Option C (configurable
   workflow)? Only Option A requires no upstream change. Options B and C require
   either a fork or an upstream contribution that firstmate must then adopt.

2. **Attempt history schema**: Which of the four patterns above? The choice
   determines whether Sergeant's attempt/evidence data is in Tasks AXI's record
   (body or meta) or in Sergeant's own fleet state files.

3. **CAS boundary**: File-level CAS (current) is sufficient for single-process
   Sergeant workers per backlog. If multiple simultaneous workers share one
   backlog file, the 2.5-second lock timeout (`LOCK_TIMEOUT_MS = 2500`,
   `src/backends/lock.ts:9`) becomes a concurrency constraint. Decision needed:
   one backlog per project-repo pair, or one shared backlog per Sergeant project?

4. **TOON projection ownership**: Does Sergeant shell out to `tasks-axi list --json`
   and post-process, or does it call the TypeScript library directly? If the
   former, custom fields require a Sergeant-side TOON formatter. If the latter,
   Sergeant is a Node.js/TypeScript project that embeds tasks-axi as a library.

5. **Upstream contribution vs. fork**: Options B and C require Tasks AXI changes.
   Does Sergeant contribute these upstream (with firstmate as another adopter),
   or does Sergeant maintain a fork? A fork means dual maintenance of a file-
   format-critical parser; contributing upstream means coordinating with firstmate
   on migration and version gating.

6. **Hold kinds**: The current enum is `captain | external | load | parked | future`.
   Sergeant's structured holds for `needs_input` and `blocked` states may fit
   `captain` (decision pending) and `external` (waiting on another system) — but
   this mapping needs explicit confirmation. Adding Sergeant-specific hold kinds
   would require a Tasks AXI change.

7. **Importer verification**: The epic requires atomic cutover from td. The
   importer reads td's JSON output and calls `tasks-axi add` for each item.
   Decision needed on rollback strategy if the import fails mid-way (Tasks AXI
   has no batch-add transaction; each `create()` is independent).

---

## Smallest Deep Interface Summary

For the destination (configurable seven-state machine, CAS, structured holds,
attempt history, TOON projection, no Sergeant hardcoding), the minimum additions
to Tasks AXI's existing interface are:

| Need | Minimal addition | File | Lines est. |
|------|-----------------|------|-----------|
| CAS on transition | `expectedState?: State` in `TransitionOpts` | `src/model.ts` + `src/backends/markdown.ts` | ~20 |
| Custom state names | `STATES` as configurable, or accept `string` in `transition()` | `src/model.ts`, `src/config.ts`, grammar, commands | ~200+ |
| Attempt history | `meta.attempts` convention (no code change) or body append | none (convention only) | 0 |
| TOON custom field | `meta`-reading custom extractor in Sergeant wrapper | Sergeant-side only | ~30 |
| Hold kinds extension | Add Sergeant kinds to `HOLD_KINDS` enum | `src/model.ts` | ~5 |

The **narrowest complete interface** that doesn't hardcode Sergeant is:
1. `transition(id, to, { expectedState? })` — CAS guard (Option B)
2. Convention: store Sergeant sub-state in `meta.sergeant_state`
3. Convention: store attempt history in `meta.attempts` (array of structured records)
4. Sergeant CLI wrapper that reads `--json` output and emits TOON with custom fields

This requires ~20 lines of Tasks AXI changes (Option B only), zero format changes,
zero firstmate migration, and keeps all Sergeant-specific semantics in Sergeant.
