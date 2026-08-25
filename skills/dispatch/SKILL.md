---
name: dispatch
description: Plan and execute a cross-repo task by dispatching autonomous subagents — one per repo — each in an isolated git worktree.
---

# Skill: dispatch

Plan and execute a cross-repo task by dispatching autonomous subagents — one per repo — each in an isolated git worktree.

---

## When to use

Load this skill when:
- A task spans multiple repos and you want to run them in parallel
- The user says "dispatch this", "spin up agents", "run this across all repos", or "take it from here"
- The cross-repo-work skill has produced a plan and the user wants to execute it

Prerequisites:
- **load-project** skill complete — you know the repos, paths, and instructions
- **cross-repo-work** skill complete (or you've manually confirmed) — you know which repos, merge order, and what each one needs to do

---

## Protocol

### Step 0 — Check for existing tracked work

v2's task-tracking is a read-only export (decision D4); there is no command that pulls a brief from an external tracker into a dispatch. If the user's request maps to an existing ticket in an external tracker, use it for context only — state the brief yourself in the dispatch call below. Sergeant's own durable record of the work is the Intent/Bullet rows a dispatch creates, not an external task.

### Step 1 — Confirm the plan

Before dispatching, state clearly:

```
Repos to dispatch:
  smith-infra  →  add OAuth secret to values + mount as env var
  smith        →  add POST /auth/google endpoint
  smith-app    →  add "Continue with Google" button + wire to API

Merge order:
  smith-infra before smith and smith-app
  (API reads the secret at startup; app talks to the API)

Branch: feat/add-oauth
Isolation: one git worktree per repo
```

Confirm the plan is accurate before dispatching. Merge order is stated as the bullet order within the intent (decision D6) — there is no per-dispatch dependency flag; see "Merge order" below.

### Step 2 — Dispatch

`POST /api/dispatch` with a JSON body:

| Field | Description |
|---|---|
| `project` | Registered project name (required) |
| `brief` | The work statement (required) |
| `repos` | Target repo names; omit to record a proposed plan awaiting approval (decision D2) instead of dispatching immediately |
| `agent` | Which agent CLI drives the phase; falls back to the project's default |
| `type` | One of `feat`, `fix`, `refactor`, `docs`, `chore`, `test` (decision O2) — required, and names the dispatched branch's `<type>/` prefix |
| `change_id` | An existing OpenSpec change id; when omitted, one is resolved from the brief and scaffolded (decision O3) |
| `request_id` | Optional idempotency key (decision D10) — a repeat of the same key returns the original run instead of starting a duplicate |

Example:

```bash
curl -X POST http://127.0.0.1:8484/api/dispatch \
  -H 'content-type: application/json' \
  -d '{"project":"myapp","brief":"Add Google OAuth","repos":["myapp-infra","myapp-api","myapp-app"],"agent":"claude","type":"feat","change_id":"add-oauth"}'
```

Per dispatch call:
1. An OpenSpec change is resolved (decision O3) before any run row, worktree, or branch exists — a failure here leaves nothing behind.
2. A run record is created in the store.
3. A git worktree is created per repo (plain `git worktree add`); a non-git or missing path is refused rather than cloned.
4. Each repo's agent phase runs headlessly, receiving its brief via the `sergeant_get_brief` MCP tool or the equivalent rendered prompt the dispatch engine builds into the phase — both draw on the same rendering, so the two dispatch paths never describe the same work differently.
5. Phase and envelope records are written to the store as the run progresses. There is no fleet file to sync and no tmux window.

### Step 3 — Monitor

```
GET /api/runs?project=<name>          # list runs for a project
GET /api/run-details?id=<run-id>      # phase-level detail for one run
```

Status is read directly from the store — there is no separate sync step and no file to poll. `blocked` is a bullet status, not a run status; a run whose bullet is blocked keeps running until the bullet's cause is resolved.

### Step 4 — Resolve a blocked bullet

There is no structured response-message channel in v2. When a bullet is `blocked`:

1. Read `GET /api/run-details?id=<run-id>` for the blocked reason.
2. Resolve the underlying cause directly — in the bullet's worktree, under `~/.local/share/sergeant-v2/fleet/<run-id>/<repo>/`, or by fixing the OpenSpec change/spec mismatch a review finding named.
3. `POST /api/run-resume` with `{"id": "<run-id>"}` — this is v2's actual, coarser equivalent of a response-message exchange: it resumes a `failed`, `blocked`, `cancelled`, `timed_out`, or `interrupted` run, skipping phases already recorded `passed`.

There is no persistent interactive pane to attach to — a dispatched agent phase runs headlessly to completion or a bounded timeout.

### Step 5 — Reconcile results

When every bullet is done, review the PRs:
- Verify each repo's completion evidence: pinned-base scope, passing gates, and — when a review phase is configured — zero blocking findings and resolved non-outdated review threads
- Check merge order: the intent's bullet order (decision D6) is the merge order; Sergeant releases a bullet's PR only once its upstream bullets are reviewed and merged
- If a bullet failed, read its blocked/failed reason via `GET /api/run-details?id=` and decide: fix and `POST /api/run-resume`, or reassign
- `GET /api/bullets?run_id=<run-id>` for the run's terminal bullet state
- Note any cross-repo implications in each PR description
- Do not report the run complete merely because every bullet opened a PR — `POST /api/create-pr` enforces the sealed-bullet gate and, once every bullet is sealed, the shipping gate

Worktree cleanup is handled by the existing fleet-cleanup mechanism, not by a per-dispatch command.

---

## Merge order

Merge order is a property of the intent itself, not a per-dispatch argument. There is no dependency-flag equivalent. State ordering as the bullet order the intent was decomposed into (decision D2) — the cross-repo-work skill produces that order before dispatch.

---

## Worker contract

Each dispatched agent phase is expected to:

1. Read its brief (rendered from the stored intent) at session start.
2. Pin the fixed point, normally the merge-base with current `origin/main`, and record the base SHA, commit list, and diff scope.
3. Triage the full spec/comments, linked material, prior or redundant work, category, and readiness. Identify the originating OpenSpec change (decision O3) or explicitly record that none exists.
4. Route before implementation using the canonical engineering skill for that phase when available, in this order:
   - Huge/foggy work: surface `wayfinder`, `to-spec`, and Sergeant's custom `to-tickets` as HITL escalation/planning paths; do not silently execute them as implementation
   - Hard bug/performance: load `diagnosing-bugs`, then use a deterministic red command, minimal reproduction, falsifiable hypotheses, and one-variable instrumentation
   - Uncertain logic/UI: load `prototype`, create throwaway evidence for HITL feedback, and never promote prototype code directly
   - Approved implementation: load `tdd` before implementation and use tracer-bullet vertical slices
   - Merge/rebase conflict: load `resolving-merge-conflicts`, trace both intents, preserve both where possible, and never abort automatically
5. Establish public behavioral seams from the spec before tests. If a consequential seam is undecided, transition the bullet to `blocked` with an explicit reason rather than guessing.
6. Implement one vertical slice at a time: focused red test, minimum green implementation, then refactor. Reject tautological tests, internal mocking, horizontal test/implementation phases, and speculative refactoring.
7. When blocked, record the exact reason on the bullet rather than guessing; resolution is the fix-then-resume path in Step 4 above.
8. Run focused tests and typechecking/lint regularly and the full required gate suite at the end. Gates run in sorted name order; a failed or timed-out phase records `failed`, never `passed`.
9. Report findings via the envelope payload, read by the review phase if one is configured for this run. A blocking finding transitions the bullet to `blocked`, resolved as described in Step 4.
10. Commit, open a PR, wait for required CI, resolve all non-outdated review threads, and satisfy merge order.
11. A bullet reaches `sealed` only after every gate passes and, once configured review has run, carries zero blocking findings.

Task tracking is out of scope for a dispatched agent to create or mutate — v2's task-tracking is a read-only export (decision D4); Intent/Bullet rows in Sergeant's own store are the durable record.

If a canonical skill cannot be loaded, the generated brief's embedded rules remain mandatory for that phase.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Worktree creation fails | Check if branch already exists; dispatch with a distinct brief/branch |
| Bullet stuck at a phase | `GET /api/run-details?id=<run-id>` for the stalled phase |
| Need to recover a blocked or failed run | Fix the underlying cause, then `POST /api/run-resume` with `{"id": "<run-id>"}` |
| Need to retry a failed repo | Fix the underlying issue, then `POST /api/run-resume`; a bullet only reaches `sealed` after every gate passes |
