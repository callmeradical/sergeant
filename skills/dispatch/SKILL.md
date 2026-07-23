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

### Step 1 — Confirm the plan

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

Ask for confirmation before dispatching.

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

```bash
bin/sgt-watch <task-id>
```

This polls every 5 seconds, syncs `.sergeant-status`, `.sergeant-message`, and `.sergeant-result` from worktrees into fleet state, and prints a live status table. `needs_input` and `blocked` are distinct nonterminal states: the watcher prints message changes and keeps running. A worker waiting on CI, review threads, or dependencies remains `in_progress` unless it needs to escalate.

When a worker escalates:

1. Read its context, evidence, exact question/blocker, recommendation, and options in the watcher output.
2. Get the human decision; do not infer consequential intent.
3. Run `sgt-respond <task-id> <repo> "<response>"`. Sergeant writes the response to fleet state and `.sergeant-response`, then nudges the recorded local tmux pane when available.
4. The worker consumes/removes the response, clears `.sergeant-message`, logs the decision to td, returns to `in_progress`, and continues.

You can also attach to the tmux session directly to observe or assist a worker:

```bash
tmux attach -t sgt-<task-id>
# Switch windows with: Ctrl-b <window-number>
```

### Step 4 — Reconcile results

When all workers are done, review the PRs:
- Verify each repo's completion evidence: pinned-base scope, focused/full validation, separate standards/spec review artifacts with zero blocking findings, required CI, and resolved non-outdated review threads
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
- Cleanup via `treehouse return <path> --force`

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

Each dispatched agent is expected to:

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
7. For `needs_input` or `blocked`, write `.sergeant-message`, notify Sergeant, remain alive, and wait. Consume/remove `.sergeant-response`, clear the message, log the decision to td, restore `in_progress`, and continue
8. Run focused tests and typechecking/lint regularly and the full required suite at the end. Do not run no-mistakes for routine worker completion, prototypes, investigations, documentation drafts, intermediate commits, or remediation loops; an explicit user instruction overrides this default
9. At an explicit final shipping boundary only, after implementation and repository-native validation, run `no-mistakes axi run --intent "<objective and approved tradeoffs>"`, skip only proven-irrelevant gates, treat findings as validation-only, and stop at `checks-passed`
10. Route each no-mistakes finding through `sgt-no-mistakes-finding`: every actionable finding creates or updates separate deduplicated owning-repo td work; correctness/security/data-integrity/test and ask-user work is P1 and remains gated, warning debt is P2, informational debt is P3, and cosmetic/evidence noise is ignored. Never remediate findings in the validation run
11. Load the canonical `code-review` skill when available, then launch separate parallel subagents for independent reviews: a standards axis over the pinned diff and documented standards plus concise Fowler smells, and a spec axis over requirements and scope. Keep evidence separate and skip the spec axis explicitly when no spec exists
12. Remediate all blocking repository-native test and independent-review findings, rerun affected tests and both axes until each reports zero blocking findings. No-mistakes findings require a separate td dispatch
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
| Worker stuck, no status update | `tmux attach -t sgt-<task-id>` and check the window |
| Worktree creation fails | Check if branch already exists; use `--branch` with a unique name |
| Fleet state is stale | Run `bin/sgt-watch --sync <task-id>` to force a one-shot sync |
| Need to recover a waiting or orphaned worker | Use `bin/sgt-respond <task-id> <repo> "<response>"`; do not mark it done manually |
| Need to retry a failed repo | Fix the underlying issue, then write both `.sergeant-result` and `.sergeant-status=done` only after every completion gate passes |
