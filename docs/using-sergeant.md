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

1. Run `sgt-context <project>` and `td context <id> --work-dir <owning-repo-path>`.
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
  --agent opencode \
  --stage implementation \
  --branch feat/example \
  --deps 'repo-a>repo-b' \
  --intent-file intent.md
```

Sergeant creates or reuses td work, creates isolated worktrees, writes worker
briefs, starts agent panes, and records fleet state. It writes the same
`.sergeant-intent.md` revision to fleet state and every selected worktree. This
artifact is canonical for implementation decisions, reviews, PR text,
successor/recovery work, and final validation.

`--agent` selects `opencode`, `goose`, or `claude`; `SERGEANT_AGENT` provides the
same override and OpenCode is the default. `--stage` is a lowercase slug used in
the `<stage>-<repo>-<task>` tmux window name and defaults to `implementation`.
Workers always run as persistent
interactive TTY sessions. Sergeant never starts one-shot run, prompt, print, or
automatic modes. It launches OpenCode with `--dangerously-skip-permissions`,
Goose with `goose session`, and Claude without prompt arguments. Initial briefs
and later responses remain in durable files. A worker-owned loop retries only a
fixed ID-bearing terminal nudge until the agent acknowledges that ID before
acting, so delayed TUI startup and coordinator crashes do not lose or duplicate
the mission, and no body appears in process arguments.

`--intent-file` is required when the objective names auth/OAuth, security,
secrets or credentials, payments, databases or migrations, stateful/production
work, destructive work, persistent state, or state transitions. The file must
contain the eight sections shown by `sgt-dispatch`; malformed, missing,
traversing, symlinked, or oversized input fails before dispatch mutation. Other
objectives use the named `standard-isolated` lighter path.

## Worker review policy

Every generated worker brief encodes `review_level=medium`. Workers run focused
tests during implementation and at most one repository-required full suite. They
then run one bounded independent review pass covering documented standards and
mission/spec correctness, prioritizing correctness, regressions, and material
scope errors while ignoring cosmetic observations and speculative refactoring.
A separate accessibility review is required only for UI-facing changes; an extra
risk review is required only when repository or task policy explicitly says so.
After remediation, rerun only affected tests and review checks rather than every
axis or the full suite.

Required CI, unresolved active review threads, and dependency order remain
completion gates. The final coordinator-owned no-mistakes run uses the default
medium profile once; workers and remediation loops do not repeat it.

## Monitor work

Background (default for OpenCode — returns promptly with monitor identity and control commands):

```bash
sgt-watch <fleet-task-id> --background
```

Foreground (for humans and debugging — blocks until the fleet reaches terminal state):

```bash
sgt-watch <fleet-task-id>
```

If managed background execution is unavailable (no systemd user services), use
`sgt-watch --sync <fleet-task-id>` for bounded one-shot inspection or run
`sgt-watch <fleet-task-id>` in a separate terminal or tmux pane.

Inspect all records:

```bash
sgt-watch --list
```

Reconcile every durable record before starting new work:

```bash
sgt-watch --sync-all
```

Bulk reconciliation syncs worktree status into fleet state, stops only
identity-verified `done` or `failed` worker panes, and marks interrupted
`dispatched` records failed when they have neither a worktree nor an owned live
pane after a 300-second grace period by default. Set
`SERGEANT_DISPATCH_GRACE_SECONDS` to change that window. It preserves
`needs_input`, `blocked`, and `orphaned` worktrees. Dispatch runs this
reconciliation automatically before creating new tasks.

Workers wake the coordinator by updating one shared per-task notify marker in
fleet state. `sgt-watch` polls that marker, so simultaneous repo updates can at
worst collapse into a delayed wakeup rather than duplicate delivery.

Do not equate `in_progress` with health. Require exact live worker-pane identity
plus recent meaningful progress evidence. `sgt-watch` prefers tmux
`pane_activity`, falls back to the worker's recorded `progress_ts`, and uses the
`.sergeant-status` mtime only when no better timestamp exists. When that
evidence stays older than the default 300-second grace window,
`sgt-watch --sync` keeps the repo `in_progress` and records a nonterminal
`live worker stalled` diagnostic instead. Set `SERGEANT_STALL_GRACE_SECONDS` to
change the grace window and `SERGEANT_STALL_DIAG_BUCKET` to control how often
the elapsed-seconds text is rewritten during repeated syncs. After reconciling
the exact pane identity, worktree, td handoff, and response/notification state,
use `sgt-recover <fleet-task-id> <repo>` only for that exact `live worker
stalled` case.

## Worker states

| State | Meaning | Operator action |
|---|---|---|
| `in_progress` | Worker reports active work and may carry a nonterminal stall diagnostic | Verify progress evidence before calling it healthy |
| `needs_input` | Human decision required | Read exact message and respond once per generation |
| `blocked` | Durable dependency or external blocker | Preserve worktree/handoff; resume after dependency resolution |
| `waiting` | Deferred work published a durable wake condition and may have exited cleanly | Let `sgt-wake` resume it automatically, or use `sgt-respond` only for a human-response gate |
| `orphaned` | Expected supervisor identity disappeared without a durable waiting state | Reconcile process, pane, worktree, branch, task, and handoff before recovery |
| `done` | Completion evidence recorded | Verify PR/CI/review/dependencies before cleanup |
| `failed` | Unrecoverable terminal failure recorded | Preserve evidence and decide retry/reassignment |

## Resume deferred work

Use `waiting` instead of sleep loops for CI checks, dependency completion, and
time-based delays. The worker writes `.sergeant-wake-condition`, sets
`.sergeant-status=waiting`, and may exit cleanly after its durable handoff.

```bash
sgt-wake <fleet-task-id> <repo>
```

`sgt-wake` evaluates the condition and resumes the exact waiting worker through
`sgt-respond` when the condition is met. Supported kinds are `not_before`,
`github_check`, `fleet_dependency`, `td_dependency`, `deployment`, and
`human_response`. Every condition requires `generation=<int>`. Optional fields
are `deadline=<unix_timestamp>`, `max_attempts=<int>`, and
`backoff_base=<seconds>`. `human_response` does not auto-resume; it converts the
worker to `needs_input` so a human can reply with `sgt-respond`. `deployment`
remains a declared condition kind, but today it also escalates to
`needs_input` until an installation-specific deployment adapter is wired.

## Respond to a worker

```bash
sgt-respond <fleet-task-id> <repo> < protected-response.txt
```

Before responding:

1. Read the exact finding/question and recommendation.
2. Ask only for missing product, risk, security, privacy, destructive, or
   irreversible decisions.
3. Record the decision in the owning td task.
4. Verify no unconsumed response generation already exists.
5. After sending, require the matching worker to acknowledge/consume it.

The supervisor nudge includes a scoped token in the form
`notification_id|target_nonce` and names files under
`.sergeant-notification-acks/`, `.sergeant-notification-accepts/`, and
`.sergeant-notification-complete/`. The agent writes the acknowledgement but
does not act yet. It proceeds only after the targeted supervisor sends
acceptance and the scoped acceptance file contains the same token, then records
completion in the named completion file.

The notified worker reads `.sergeant-response`, its ID, and gate generation,
applies the decision once, restores truthful status, and writes
`.sergeant-response-applied` with the matching ID, generation, and status. It then
runs `sgt-ack-response <task> <repo> <response-id>` from its exact recorded pane.
This validates post-application proof, stages replay evidence in a private
archive entry (`0700` directory, `0600` files), records acknowledgement, and
only then clears active plaintext transport. If a later archive-marker or
transport-cleanup step fails, rerun the same `sgt-ack-response` command with the
same response ID; it must converge the existing archive, acknowledgement
markers, and active transport without reapplying the decision.

## Recover one stalled worker

```bash
sgt-recover <fleet-task-id> <repo>
```

Use this only when `sgt-watch --sync <fleet-task-id>` or `sgt-watch --sync-all`
left the repo `in_progress` with a `live worker stalled` diagnostic and you
already reconciled the exact pane identity, worktree, td handoff, and active
response/notification state. Recovery is one-shot per repo attempt: Sergeant
records `stall_recovery_attempted`, relaunches only after replacement metadata
is validated, and escalates to `needs_input` instead of retrying when the prior
notification delivery still holds an unfinished action lease, the recorded pane
identity no longer matches, or any later relaunch step fails.

## Reconcile results

For each repository require:

- intended fixed point and diff scope;
- focused repository-native tests/lint/typecheck/build and at most one repository-required full suite;
- one bounded independent Standards and Spec review pass;
- Accessibility review only for UI-facing work and extra risk review only when repository or task policy explicitly requires it;
- required CI and zero unresolved active review threads;
- dependency and deployment order;
- truthful td handoff/review state.

## Final no-mistakes boundary

After native validation and independent reviews report zero blockers, the worker
writes `.sergeant-validation-ready` with the recorded `intent_revision`, current
`head_sha`, and `passed` values for `standards_review`, `spec_review`, and
`readiness_review`, then notifies the coordinator. The worker must
not run no-mistakes. The coordinator starts the one final validation boundary:

```bash
sgt-validate <fleet-task-id> <repo> [--skip <steps>]
```

`sgt-validate` splits the worker's existing tmux window, renames that shared
window to `validation-<repo>-<task>`, and runs no-mistakes interactively in the
new coordinator-owned pane with the canonical intent. It never uses `--yes`.
The default medium profile skips `review` and `document`, which were already
covered by the required independent reviews and readiness evidence. Passing an
explicit `--skip <steps>` replaces the default skip list.
Before cloning the validation checkout or publishing launch state, the
coordinator acquires an identity-checked validation-launch reservation for that
task/repository pair. Concurrent launches fail closed until the recorded owner
exits or stale-ownership recovery proves the reservation is abandoned.

If launch fails before the validation child commits the release, Sergeant rolls
back only the checkout, pane, temp files, and fleet-state markers that the
current invocation both created and can still prove it owns. Preexisting state,
reused panes, dangling paths, and concurrent replacements are preserved. After
the recorded validation pane and process group have fully exited, rerunning
`sgt-validate` safely resets only identity-matched finished state and retries
the launch.

Treat the run as validation-only. Route each actionable finding into separate,
deduplicated owning-repository td work. Do not modify source inside the retained
validation run. Approve low/medium-risk gates and merge passing PRs under
recorded authorization; escalate high-risk findings.

## Clean completed fleet state

```bash
sgt-cleanup <fleet-task-id>
```

Cleanup requires terminal/reconciled state, configured cleanup-owner proof for
the repository/worktree or treehouse lease, preserved evidence, explicit
cleanup-phase proof when replaying an interrupted removal or reconciling an
already-absent worktree, fully acknowledged response transport, and no
uncommitted or in-use worktree state. Never use cleanup to resolve a waiting,
blocked, or orphaned worker.

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
