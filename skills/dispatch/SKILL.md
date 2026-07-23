# Skill: dispatch

Plan and execute a cross-repo task by dispatching autonomous subagents — one per repo — each in an isolated git worktree.

---

## When to use

Load this skill when:
- A task spans multiple repos and you want to run them in parallel
- The user says "dispatch this", "spin up agents", or "run this across all repos"
- The cross-repo-work skill has produced a plan and the user wants to execute it
- An existing fleet must be monitored, answered, recovered, reconciled, or cleaned

Prerequisites:
- **load-project** skill complete — you know the repos, paths, and instructions
- **cross-repo-work** skill complete (or you've manually confirmed) — you know which repos, dependency order, and what each one needs to do

---

## Protocol

### Step 0 — Check the td queue

Before planning from scratch, see if the task already exists in td:

```bash
sgt-td-list <project>
sgt-td-list <project> --priority P1
```

If the user's request maps to an open td task, use `--td <id>` when dispatching. The brief, branch name, and full task context are pulled from td automatically — and the worker's brief will include `td start`, `td log`, `td handoff`, and `td review` instructions so the task lifecycle is tracked end-to-end.

### Step 1 — Record the dispatch contract

Before dispatching, state clearly:

```
Repos to dispatch:
  smith-infra  →  add OAuth secret to values + mount as env var
  smith        →  add POST /auth/google endpoint
  smith-app    →  add "Continue with Google" button + wire to API

Dependency order:
  smith-infra must complete before smith and smith-app can merge
  (API reads the secret at startup; app talks to the API)

Branch: feat/add-oauth
Backend: local tmux
```

Ask only when repository ownership, dependency order, user-visible behavior,
security/privacy policy, destructive action, or an irreversible tradeoff remains
unresolved. Do not ask again when the conversation or td already records the
decision or standing dispatch authorization.

### Step 2 — Dispatch

**From a td task (preferred when one exists):**

```bash
# Auto-detects repo, derives brief and branch from the task
sgt-dispatch <project> --td <task-id>

# Override repo if the task touches more than the owning repo
sgt-dispatch <project> --td <task-id> --repos smith,smith-app
```

**From a free-form brief:**

```bash
sgt-dispatch <project> "<brief>" \
  --repos <repo1>,<repo2>,<repo3> \
  --branch <branch-name> \
  --deps "<prereq>><dependent>,..."
```

The script:
1. Generates a task ID
2. Creates a git worktree per repo at `<repo-path>/../<repo-name>-sgt-<task-id>/`
3. Writes a `.sergeant-brief.md` into each worktree with: the mission, merged agent instructions, dependency notes, and delivery requirements
4. Spawns an agent in each local tmux window
5. Creates fleet state at `~/.local/share/sergeant/fleet/<task-id>/`

### Step 3 — Monitor

`sgt-watch <task-id>` polls every 5 seconds, syncs `.sergeant-status`,
`.sergeant-message`, and `.sergeant-result` from worktrees into fleet state, and
prints a live status table. In OpenCode, run it in a managed background process
and verify the process started. Use bounded one-shot inspection when managed
background execution is unavailable; do not hold the coordinator in a blocking
watch call.

`needs_input` and `blocked` are distinct nonterminal states. A waiting worker may
remain alive or may exit after atomically recording a durable handoff and status.
Do not infer progress from pane/process liveness, and do not rewrite an expected
blocked exit as orphaned.

For a bounded one-shot worktree-to-fleet synchronization, run:

```bash
sgt-watch --sync <task-id>
```

This command returns after one sync and does not follow the fleet.

When a worker escalates:

1. Read its context, evidence, exact question/blocker, recommendation, and options in the watcher output.
2. Get the human decision; do not infer consequential intent.
3. Run `sgt-respond <task-id> <repo> "<response>"`. Sergeant writes a generation-bound response to fleet state and `.sergeant-response`, then nudges or relaunches the exact recorded local worker when supported.
4. Require acknowledgement/consumption of the intended response generation before sending another. The worker clears or archives the message, logs the decision to td, restores truthful status, and continues or records a new blocker.

You can also attach to the tmux session directly to observe or assist a worker:

```bash
tmux attach -t sgt
# Select the task/repo window shown by sgt-dispatch.
```

### Step 4 — Reconcile results

When all workers are done, review the PRs:
- Verify each repo's completion evidence: pinned-base scope, focused/full validation, separate standards/spec review artifacts, an accessibility review artifact for UI-facing work, zero blocking findings, required CI, and resolved non-outdated review threads
- Check dependency order: merge infra before API before app if there are runtime dependencies; a worker is not done until its dependency gate is satisfied
- If any repo failed, read the failure reason from fleet state and decide: retry, fix manually, or reassign
- Note any cross-repo implications in each PR description (e.g., "merge after smith-infra #42")
- Do not reconcile or clean up a fleet merely because every worker has opened a PR; all completion gates must be met

```bash
bin/sgt-watch --list      # see all tasks
bin/sgt-cleanup <task-id> # remove worktrees and fleet state
```

---

## Treehouse worktrees

Sergeant prefers [treehouse](https://github.com/kunchenguid/treehouse) for worktree management. Treehouse maintains a pool of pre-warmed worktrees per repo — leasing one is faster than `git worktree add` and cleanup is pooled.

**Setup treehouse in the project's repos (one-time):**

```bash
bin/sgt-treehouse-init <project>                      # all repos
bin/sgt-treehouse-init <project> --groups core,frontend,infra  # specific groups
```

This runs `treehouse init` in each repo and creates a `treehouse.toml`. Commit those files so the pool config is tracked.

**How dispatch uses treehouse:**
- If `treehouse.toml` exists in a repo → `treehouse get --lease --lease-holder "sgt-<task-id>-<repo>"`
- Branch is checked out in the leased worktree: `git checkout -b <branch>`
- Pool is in `~/.treehouse/<repo-slug>/<n>/<repo-name>/`
- Cleanup is performed through `sgt-cleanup`, which validates task paths, terminal
  state, owner identity, lease identity, and preserved evidence before returning
  a Treehouse lease.

**If treehouse is not initialized** in a repo, dispatch falls back to plain `git worktree add` (sibling path: `<repo-parent>/<repo-name>-sgt-<task-id>/`).

---

## Dependency ordering

Use `--deps` to express ordering constraints:

```
--deps "smith-infra>smith,smith-infra>smith-app"
```

This means: `smith-infra` must finish before `smith` and `smith-app`. The brief written into each dependent repo will include an instruction to wait for the prereq's `.sergeant-status` to read `done` before opening a PR.

The workers themselves are responsible for honoring this. The brief makes it explicit.

---

## Worker contract

Each dispatched agent must:

1. Read `.sergeant-brief.md` at session start
2. Pin the fixed point, normally the merge-base with current `origin/main`, and record the base SHA, commit list, and diff scope
3. Triage the full td issue/spec/comments, linked material, prior or redundant work, category, and readiness. Identify the originating spec or explicitly record that none exists
4. Route before implementation using the canonical engineering skill for that phase when available, in this order:
   - Huge/foggy work: surface `wayfinder`, `to-spec`, and Sergeant's custom `to-tickets` as HITL escalation/planning paths; do not silently execute them as implementation
   - Hard bug/performance: load `diagnosing-bugs`, then use a deterministic red command, minimal reproduction, falsifiable hypotheses, and one-variable instrumentation
   - Uncertain logic/UI: load `prototype`, create throwaway evidence for HITL feedback, and never promote prototype code directly
   - Approved implementation: load `tdd` before implementation and use tracer-bullet vertical slices
   - Merge/rebase conflict: load `resolving-merge-conflicts`, trace both intents, preserve both where possible, and never abort automatically
5. Establish public behavioral seams from td/spec before tests. If a consequential seam is undecided, escalate `needs_input` rather than guessing
6. Implement one vertical slice at a time: focused red test, minimum green implementation, then refactor. Reject tautological tests, internal mocking, horizontal test/implementation phases, and speculative refactoring
7. For `needs_input` or `blocked`, atomically write the status and
   `.sergeant-message`, notify Sergeant once per generation, and record a td
   handoff. The worker may wait alive or exit cleanly; after a matching
   `.sergeant-response` is consumed, clear/archive the message, log the decision,
   restore truthful status, and continue
8. Run focused tests and typechecking/lint regularly and the full required suite at the end. Do not run no-mistakes for routine worker completion, prototypes, investigations, documentation drafts, intermediate commits, or remediation loops; an explicit user instruction overrides this default
9. At an explicit final shipping boundary only, after implementation and repository-native validation, run `no-mistakes axi run --intent "<objective and approved tradeoffs>"`, skip only proven-irrelevant gates, treat findings as validation-only, and stop at `checks-passed`
10. Route each no-mistakes finding through `sgt-no-mistakes-finding`: every actionable finding creates or updates separate deduplicated owning-repo td work; correctness/security/data-integrity/test and ask-user work is P1 and remains gated, warning debt is P2, informational debt is P3, and cosmetic/evidence noise is ignored. Never remediate findings in the validation run
11. Load the canonical `code-review` skill when available, then launch separate parallel subagents for independent reviews: a standards axis over the pinned diff and documented standards plus concise Fowler smells, and a spec axis over requirements and scope. For UI-facing work identified by frontend, UI, visual, interaction, accessibility, or user-facing output language in the mission, repo role, or repo group, also launch a separate accessibility axis. Keep evidence separate and skip the spec axis explicitly when no spec exists
12. Remediate all blocking repository-native test and independent-review findings, rerun affected tests and all required axes until each reports zero blocking findings. No-mistakes findings require a separate td dispatch
13. Commit, open a PR, wait for required CI, resolve all non-outdated review threads, and satisfy dependency order
14. For tracked work, log td decisions, handoff, then run `td review` only when implementation and review evidence are ready
15. Write `.sergeant-result` and set `.sergeant-status=done` only after every gate passes. `failed: <exact reason>` is reserved for an unrecoverable terminal failure

If a canonical skill cannot be loaded, the generated brief's embedded rules remain mandatory for that phase.

`sgt-watch` polls for those files and surfaces them.

---

## td task creation

When you dispatch from a freeform brief, `sgt-dispatch` creates exactly one td task in each target repo before spawning any worker. If td is unavailable, task creation fails, generated task metadata cannot be injected, or any selected repo does not get a generated task, dispatch aborts before spawning and rolls back the generated cards. `--td` dispatch keeps using the existing task instead of generating replacements.

The generated task IDs are written into fleet state and injected into each worker's `.sergeant-brief.md` with the full `td start` / `td log` / `td handoff` / `td review` lifecycle.

To create tasks manually without dispatching:
```bash
sgt-td-create <project> "<title>" --repos repo1,repo2 --priority P1
```

---

## Flags reference

| Flag | Description |
|---|---|
| `--repos repo1,repo2` | Which repos to dispatch (required) |
| `--td <task-id>` | Dispatch from an existing td task; brief derived from task title |
| `--branch <name>` | Branch name used in all worktrees (default: derived from brief) |
| `--deps "a>b,a>c"` | `a` must complete before `b` and `c` can merge |
| `--dry-run` | Print what would happen, don't create worktrees or spawn agents |

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Worker stuck, no status update | Reconcile recent log events, active child process, exact pane identity, and td handoff; attach with `tmux attach -t sgt` only for evidence. |
| Worktree creation fails | Check if branch already exists; use `--branch` with a unique name |
| Fleet state is stale | Run `sgt-watch --sync <task-id>`, then reconcile fleet/worktree files and pane identity. |
| Need to recover a waiting or orphaned worker | Use `bin/sgt-respond <task-id> <repo> "<response>"`; do not mark it done manually |
| Need to retry a failed repo | Fix the underlying issue, then write both `.sergeant-result` and `.sergeant-status=done` only after every completion gate passes |
