# Using Sergeant

## Start with project context

```bash
sgt-list
sgt-context <project>
sgt-td-list <project>
```

Use resolved project output to identify repository ownership and instructions.
Do not infer ownership from the current working directory.

## Choose direct or dispatch mode

### Direct mode

Use when the user explicitly requests work in the current session and one
repository owns the complete outcome.

1. Run `sgt-context <project>` and `td context <id>`.
2. Reconcile existing worktrees/workers before editing.
3. Create or reuse a feature branch; never implement on the default branch.
4. Start the task and implement TDD-first.
5. Run repository-native validation and independent review.
6. Run the final shipping gate only at the approved shipping boundary.
7. Open a PR and satisfy required CI, review threads, and merge authorization.
8. Record handoff, PR, merge, deployment, and cleanup state.

### Dispatch mode

Use for cross-repository work, independent repository-owned tasks, isolated
review workers, or an explicit request for workers.

From an existing task:

```bash
sgt-dispatch <project> --td <task-id>
```

From a free-form brief when no task exists:

```bash
sgt-dispatch <project> "<objective and constraints>" \
  --repos repo-a,repo-b \
  --branch feat/example \
  --deps 'repo-a>repo-b'
```

Sergeant creates or reuses td work, creates isolated worktrees, writes worker
briefs, starts agent panes, and records fleet state.

## Monitor work

Foreground:

```bash
sgt-watch <fleet-task-id>
```

For OpenCode, run long watches as managed background processes so the coordinator
remains available. Until native `--background` support ships, a Linux example is:

```bash
systemd-run --user --unit="sgt-watch-<fleet-task-id>" --collect \
  sgt-watch <fleet-task-id>
```

Inspect all records:

```bash
sgt-watch --list
```

Do not equate `in_progress` with health. Require exact live pane/process identity
plus recent meaningful log activity or an active child operation.

## Worker states

| State | Meaning | Operator action |
|---|---|---|
| `in_progress` | Worker reports active work | Verify progress evidence before calling it healthy |
| `needs_input` | Human decision required | Read exact message and respond once per generation |
| `blocked` | Durable dependency or external blocker | Preserve worktree/handoff; resume after dependency resolution |
| `orphaned` | Expected supervisor identity disappeared without a durable waiting state | Reconcile process, pane, worktree, branch, task, and handoff before recovery |
| `done` | Completion evidence recorded | Verify PR/CI/review/dependencies before cleanup |
| `failed` | Unrecoverable terminal failure recorded | Preserve evidence and decide retry/reassignment |

## Respond to a worker

```bash
sgt-respond <fleet-task-id> <repo> "<approved response>"
```

Before responding:

1. Read the exact finding/question and recommendation.
2. Ask only for missing product, risk, security, privacy, destructive, or
   irreversible decisions.
3. Record the decision in the owning td task.
4. Verify no unconsumed response generation already exists.
5. After sending, require the matching worker to acknowledge/consume it.

## Reconcile results

For each repository require:

- intended fixed point and diff scope;
- repository-native tests/lint/typecheck/build;
- independent Standards and Spec reviews;
- Accessibility review for UI-facing work;
- required CI and zero unresolved active review threads;
- dependency and deployment order;
- truthful td handoff/review state.

## Final no-mistakes boundary

Run no-mistakes once after implementation and native validation:

```bash
no-mistakes axi run --intent "<objective and approved tradeoffs>"
```

Treat it as validation-only. Route each actionable finding into separate,
deduplicated owning-repository td work. Do not modify source inside the retained
validation run. Stop at `checks-passed`; merge only under recorded authorization.

## Clean completed fleet state

```bash
sgt-cleanup <fleet-task-id>
```

Cleanup requires terminal/reconciled state, owner and lease identity, preserved
evidence, and no uncommitted or in-use worktree state. Never use cleanup to resolve
a waiting, blocked, or orphaned worker.

## Common project operations

```bash
sgt-status <project>          # repo status across project
sgt-sync <project>            # clone/pull configured repos
sgt-graphify <project>        # publish project-level graph
sgt-treehouse-init <project>  # optional worktree pools
sgt-td-create <project> "<title>" --repos repo-a
```

## Wiki operations

Automatic captures are written by dispatch, notify, and cleanup commands.
Curated digest commands:

```bash
wiki-daily-digest --dry-run --date YYYY-MM-DD
wiki-daily-digest --date YYYY-MM-DD
wiki-daily-digest --since YYYY-MM-DD
```

Read [Skills and their sources](skills.md) for engineering workflow skills and
[Troubleshooting](troubleshooting.md) for recovery guidance.
