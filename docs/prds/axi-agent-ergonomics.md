# Product Requirements: AXI Agent Ergonomics

Status: Draft — Phase 1 implementation in progress on
`feat/implement-axi-native-sergeant-interfaces`

Research baseline commit: `a6af6854056c77a7a1ed73e61b74cd7fead52e30`

Related research: `docs/research/axi-agent-ergonomics-spike.md`

---

## Summary

Sergeant's command output is inconsistent, frequently unbounded, and structured
for human readers rather than agent consumers. The fleet discovery command
emits over 80 KB of unfiltered history; validation and cleanup reveal blockers
one at a time; structured errors and receipts are absent; and no agent-facing
home view exists.

This PRD specifies a hybrid ergonomics improvement: native bounded projections
and preflights added to existing commands, stable structured errors and minimal
receipts, and a thin `sgt-axi` facade for TOON rendering and discovery. The
existing intent, ownership, generation, pane, validation, and cleanup proof
chains are unchanged.

---

## Users

- **Coordinator agent:** navigates fleet state, task queues, and project context
  across multi-repository work; calls Sergeant commands and interprets their
  output to select next actions.
- **Worker agent:** reads task context and fleet handoff; calls status and
  respond commands during implementation.
- **Human operator:** runs Sergeant commands directly; reads human-formatted
  output from the same commands the agent uses.
- **Maintainer:** adds new commands and output fields; must not break agent or
  human consumers of existing output.

---

## Problem

Agent consumers of Sergeant commands face four concrete problems:

**Unbounded fleet discovery.** `sgt-watch --list` emits all retained history
with no limit or filter. A measured point sample produced 84,978 bytes and
1,846 lines from a single-project fleet. Agents must consume the full output
to extract a handful of actionable state fields.

**First-failure blocker revelation.** `sgt-validate` and `sgt-cleanup` expose
blockers one at a time. An agent must retry repeatedly to enumerate all
blockers before deciding whether to proceed or escalate.

**Absent structured errors.** Error output is prose on stderr with exit status
1. Agents cannot reliably distinguish a usage error from a stale state, an
ownership mismatch, a partial publication, or a retryable failure without
parsing prose.

**Absent receipts and state-valid next commands.** Successful `sgt-dispatch`
and `sgt-respond` invocations mix progress lines with result data. Agents have
no stable receipt containing the canonical identifiers (task ID, response ID,
generation, intent revision) and the state-valid next command needed to
continue safely.

---

## Product Principle

Native commands own state, proofs, snapshots, preflights, and receipts. A thin
facade renders those native outputs for ergonomic consumption. No proof chain,
safety check, or evidence boundary is weakened to improve output compactness.

---

## Outcomes

1. Fleet discovery is bounded by default and reports total and shown counts.
2. A single command call enumerates all blockers for validation and cleanup
   readiness.
3. Errors carry stable codes that distinguish error category, retryability, and
   actionable next steps without parsing prose.
4. Successful dispatch and respond invocations produce a compact receipt
   containing canonical identifiers and the state-valid next command.
5. A `sgt-axi` facade renders TOON and content-first views from native JSON
   schemas without duplicating lifecycle logic.
6. No change to any intent, ownership, generation, pane, validation, cleanup,
   or response proof check.

---

## Non-Goals

- Replacing the underlying evidence model with an opaque AXI session handle.
- Combining approved actions across approval or evidence boundaries.
- Adding `--force` to any command or allowing `--yes` in validation.
- Changing `sgt-respond` to accept response bodies anywhere except private
  stdin or file transport.
- Treating AXI browser or GitHub benchmark numbers as Sergeant effect sizes.
- Outputting response, intent, brief, prompt, or model response bodies in any
  agent-visible surface.
- Migrating all native output formats in a single flag-day change.

---

## Terminology

- **TOON:** Token-Optimized Output Notation, a compact structured text format
  designed for agent consumption.
- **Snapshot:** a read-only, single-call view of current fleet state computed
  once and exiting. Does not block; does not mutate.
- **Preflight:** a read-only enumeration of all current blockers for a
  destructive command. Execution must recheck; preflight output is not a
  capability token.
- **Receipt:** the structured success output of a mutating command, containing
  canonical identifiers and the state-valid next command.
- **State-valid next command:** a parameterized Sergeant command string that is
  correct given the state at the time of output.
- **Home view:** a no-argument invocation that shows live actionable state
  rather than usage text.

---

## Phase 1 — Native Read-Only Projections

### `sgt-watch --snapshot <task-id> [--repo <repo>]`

A new flag for a single bounded read of fleet state.

- Runs once, outputs state, and exits. Does not poll.
- Output contains: task ID, project, repos with their current status,
  health/progress evidence, state-valid next command per repo, and a summary
  count of states.
- Default output is under 8 KiB for any fleet size.
- Does not mutate state. Does not require a live pane.

### `sgt-watch --active` and `sgt-watch --recent <n>`

- `--active` restricts output to repos with non-terminal status.
- `--recent <n>` limits output to the n most recently modified repo records.
- Both can combine: `sgt-watch --active --recent 5`.
- Output includes `count` (matching) and `shown` (displayed) fields.

### `sgt-watch --list` default scope change

- Default output restricted to active and recent tasks (last 72 hours or
  configurable).
- `--all` restores full retained history.
- Every list output includes `total` (all retained) and `shown` (displayed).

### `sgt-validate --check <task-id> <repo>`

- Returns all blockers in a single call.
- Does not start or modify the validation process.
- Output schema: `{ "blockers": [...], "blocker_count": n, "ready": bool }`.
- A successful empty state emits `{ "blockers": [], "blocker_count": 0, "ready": true }`.
- Execution always rechecks; `--check` output is not a token for bypass.

### `sgt-cleanup --check <task-id> [<repo>]`

- Returns all blockers for the cleanup operation.
- Does not modify or remove any state.
- Output schema matches `sgt-validate --check`.
- Lists exact resources to be removed when `"ready": true`.
- Execution always rechecks; `--check` output is not a capability token.

### Acceptance criteria — Phase 1

1. `sgt-watch --snapshot <task>` completes once and exits; output is under
   8 KiB; state classifications match `sgt-watch <task>` for the same fleet
   fixtures.
2. `sgt-watch --list` default output is under 8 KiB for any fleet; `--all`
   restores full output.
3. `sgt-validate --check` returns all blockers in one call; executing
   `sgt-validate` always rechecks independently.
4. `sgt-cleanup --check` returns all blockers in one call; executing
   `sgt-cleanup` always rechecks independently.
5. No snapshot or preflight command mutates fleet, worktree, or task state.
6. Existing shell tests pass without modification.
7. `sgt-watch` still supports its current blocking monitoring mode.

---

## Phase 2 — Stable Structured Errors and Minimal Receipts

### Error contract

Every Sergeant command that fails operationally (not usage) exits with:

- A stable `error.code` string that does not change across versions.
- A `retryable: bool` field.
- Where applicable: `state`, `task_id`, `repo`, and the state-valid next
  command or suggested remediation.

Error codes must distinguish at minimum:

| Code | Meaning |
|---|---|
| `usage_error` | Invalid arguments or flags; not retryable |
| `not_found` | Task, repo, worktree, or fleet record not found |
| `stale_generation` | Response or notification generation has advanced |
| `ownership_mismatch` | Worktree, pane, or intent does not match fleet record |
| `partial_publication` | Response or ack files are in an intermediate state |
| `dirty_worktree` | Worktree has uncommitted changes blocking the operation |
| `missing_dependency` | Required upstream task, review, or approval not satisfied |
| `already_converged` | Operation is already in the expected terminal state |
| `terminal_required` | Fleet record is non-terminal; cleanup or cancel required first |

Human-readable messages remain on stderr. Machine-readable error JSON is on
stdout when `--format json` is requested or when stdout is not a TTY.

### Dispatch receipt

A successful `sgt-dispatch` invocation produces a compact structured receipt:

```
task_id: <id>
repos: [<name>, ...]
intent_revision: <sha>
branch: <branch>
watch: sgt-watch --snapshot <task_id>
respond: sgt-respond <task_id> <repo> < <response-file>
```

- Progress lines move to stderr.
- Body, brief, response, or intent content does not appear in the receipt.

### Respond receipt

A successful `sgt-respond` invocation produces:

```
response_id: <id>
generation: <n>
task_id: <id>
repo: <repo>
next: sgt-ack-response <task_id> <repo> <response_id>
```

### Acceptance criteria — Phase 2

1. Every error from `sgt-dispatch`, `sgt-respond`, `sgt-validate`,
   `sgt-cleanup`, and `sgt-watch` carries a stable `error.code` and
   `retryable` when `--format json` is requested.
2. `sgt-dispatch` success output contains `task_id`, `intent_revision`, and
   `watch` command; no body or brief content.
3. `sgt-respond` success output contains `response_id`, `generation`, and
   `next` command; no response body.
4. Stale generation, ownership mismatch, dirty worktree, and partial
   publication produce distinguishable error codes without prose parsing.
5. No protected content (intent, response, brief, prompt, or model output)
   appears in any error or receipt output.

---

## Phase 3 — `sgt-axi` Facade and Ambient Setup

### `sgt-axi` command

A thin wrapper over native Sergeant commands. `sgt-axi` must:

- Read native JSON output from existing commands; never read fleet state files
  directly.
- Render TOON and content-first views from native schemas.
- Provide a home view when invoked with no arguments: executable identity,
  project count, uniquely resolved current project if any, and parameterized
  next commands.
- Add `help[]` arrays to output when a state-valid next command exists.
- Cap ambient context output at 2 KiB per session.
- Require unique registry resolution; show candidates and stop when ambiguous.

`sgt-axi` must not:

- Reimplement lifecycle logic, guard checks, or state interpretation from fleet
  files.
- Expose response, intent, brief, or model output bodies.
- Add `--force` or bypass any existing proof check.
- Mutate state; all mutations go through native commands.

### Ambient setup

`sgt-axi setup` installs an opt-in session context hook that emits compact
project and fleet state at session start. Setup is explicit and idempotent.
The hook must not run automatically on every shell init.

### TOON rendering

TOON output is generated only at the output boundary. Native JSON remains the
internal contract. `sgt-axi` renders TOON from native JSON; it does not
generate TOON inside Sergeant shell scripts.

### Acceptance criteria — Phase 3

1. `sgt-axi` no-argument invocation shows project count, resolved project
   (or candidates), and parameterized next commands.
2. TOON output is generated only by `sgt-axi`; native commands emit text or
   JSON only.
3. Fleet state files are never read directly by `sgt-axi`.
4. Ambient context output is under 2 KiB.
5. `sgt-axi setup` is idempotent; re-running produces no duplicate hooks or
   error output.

---

## Phase 4 — Measure and Migrate

After Phase 3 ships, collect benchmark evidence before changing any native
command's default output format. A format change is approved only when all of:

- Success and recovery rates are no worse than baseline.
- Safety, provenance, and privacy violations remain zero.
- Median agent tokens or command-output bytes improve by at least 25%.
- Median turns improve by at least one on multi-step journeys.
- Median and p95 wall time do not regress by more than 10%.
- Bash 3.2 and repository-native tests remain green.

---

## Measurable Acceptance Criteria

1. Fleet discovery default output is under 8 KiB for any fleet size.
2. `sgt-validate --check` and `sgt-cleanup --check` return all blockers in a
   single call with `blocker_count` and `ready` fields.
3. Every stable error code is enumerated in this document and remains unchanged
   across versions; adding a new code is allowed, renaming an existing one is
   not.
4. Dispatch and respond receipts contain canonical identifiers and the
   state-valid next command with no body content.
5. `sgt-axi` home view is under 2 KiB; it reads only native command output.
6. No test in the existing shell test suite is removed or weakened.
7. All safety proof checks (intent, owner, generation, pane, response archive,
   cleanup phases) pass unchanged after every Phase 1–3 implementation.
8. Zero response, intent, brief, prompt, or model output bytes appear in any
   command output, receipt, error, TOON view, or ambient context.

---

## Delivery Boundary

This PRD governs all four phases. Each phase requires its own implementation
dispatch. Phase 1 (native projections) is the highest priority and may be
dispatched independently. Phases 2, 3, and 4 depend on Phase 1 landing and
its acceptance criteria being verified.
