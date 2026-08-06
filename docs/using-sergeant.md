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
  --model anthropic/claude-opus-5 \
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
same override and OpenCode is the default. `--model` pins what that harness runs
as `provider/model[:variant]`; `SERGEANT_MODEL` provides the same override, and
precedence is `--model` > `SERGEANT_MODEL` > the harness's own default. The two
are orthogonal: `--agent` chooses the executable, `--model` chooses what it runs.
An unhonorable tuple fails before any state is created. `--stage` is a lowercase
slug used in the `<stage>-<repo>-<task>` tmux window name and defaults to
`implementation`.

A coordinator that is not inside tmux can bind a pane with
`--managed-coordinator-pane` (create or select Sergeant's managed pane) or
`--coordinator-pane <pane-id>` (bind a pane it prepared). The two cannot be
combined, neither starts a tmux server, and every path verifies the pane against
the live server first.

Workers always run as persistent
interactive TTY sessions. Sergeant never starts one-shot run, prompt, print, or
automatic modes. The base invocation is OpenCode with
`--dangerously-skip-permissions`, Goose with `goose session`, and Claude with no
prompt arguments; when a tuple is pinned, that base is extended with the
harness's own measured model transport — argv for OpenCode, plus `--agent`
against a generated definition when a variant is pinned, and
`GOOSE_PROVIDER`/`GOOSE_MODEL` in the environment for Goose. Initial briefs
and later responses remain in durable files. A worker-owned loop retries only a
fixed ID-bearing terminal nudge until the agent acknowledges that ID before
acting, so delayed TUI startup and coordinator crashes do not lose or duplicate
the mission, and no body appears in process arguments.

### Security posture: `--dangerously-skip-permissions`

OpenCode is launched with `--dangerously-skip-permissions` in every Sergeant
worker. This is intentional and the rationale is:

- Workers run in an **automated dispatch context**, not an interactive session.
  The operator is not at the keyboard and cannot respond to individual
  permission prompts.
- **Operator trust is scoped at dispatch time**: the intent file and worker
  brief reviewed and approved before dispatch define the boundaries of the work.
  The agent cannot escalate beyond that scope.
- Interactive permission gates exist for human-supervised sessions where the
  operator can make real-time decisions. In a Sergeant worker, those gates would
  cause the worker to hang indefinitely waiting for input that will never come.

The flag is not a capability grant — it is a bypass of the interactive
confirmation UI. The actual trust boundary is the intent file content approved
at dispatch time, the worker brief injected into the session, and the repository
permissions of the worktree the worker checks out into.

For security-sensitive work (auth, credentials, payments, databases, production
state), use `--intent-file` and ensure the intent file enumerates the exact
actions the worker may take. See the intent file requirements above.

`--intent-file` is required when the objective names auth/OAuth, security,
secrets or credentials, payments, databases or migrations, stateful/production
work, destructive work, persistent state, or state transitions. The file must
contain the eight sections shown by `sgt-dispatch`; malformed, missing,
traversing, symlinked, or oversized input fails before dispatch mutation. Other
objectives use the named `standard-isolated` lighter path.

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
`sgt-respond` when the condition is met. Every condition requires
`generation=<int>`. Optional fields are `deadline=<unix_timestamp>`,
`max_attempts=<int>`, and `backoff_base=<seconds>`.

| Kind | Required fields | Resumes when |
|---|---|---|
| `not_before` | `not_before=<unix_timestamp>` | that timestamp has passed |
| `github_check` | `run_id=<id>` and `check_name=<name>` | the check named `check_name` in that run concludes `success` |
| `fleet_dependency` | `task_id=<id>` and `repo=<repo>` | that worker reaches `done` |
| `td_dependency` | `td_task_id=<id>` | that td task is closed |
| `deployment` | `app=<name>` and `env=<name>` | never auto-evaluated today |
| `human_response` | — | never auto-evaluated |

`github_check` requires **both** `run_id` and `check_name`, and resumes only
when that exact check concludes successfully. `failure`, `cancelled`, `skipped`,
`timed_out`, and every other non-success conclusion never resume the worker.
`check_name` may contain spaces and the other characters real check names use,
for example `check_name=build (ubuntu-latest, 3.11)`.

A condition that can no longer be met converts the worker to `needs_input` with
the remedy in `.sergeant-message` instead of retrying until its deadline. That
covers a named check that concluded unsuccessfully, a check absent from a run
that has already completed, an ambiguous duplicate check name, and a condition
missing a required field. Conditions written before `check_name` became required
therefore surface as `needs_input` asking for `check_name`, rather than waiting
forever; add the field and resume with `sgt-respond`.

`human_response` does not auto-resume; it converts the worker to `needs_input`
so a human can reply with `sgt-respond`. `deployment` remains a declared
condition kind, but today it also escalates to `needs_input` until an
installation-specific deployment adapter is wired.

## Pause admission with a drain

```bash
sgt-drain <project>|--global [--reason <text>] [--wait [--timeout <s>]]
sgt-drain --status [<project>|--global]
sgt-drain --undrain <project>|--global
```

A drain refuses new pane starts for the matching scope; responses are still
stored generation-safely for later delivery. `--wait` activates the drain first
and then waits for live workers in scope to finish their current turn and exit.
On timeout it leaves the drain active, exits nonzero, and names the unresolved
workers without terminating any of them. A worker is only treated as finished
when its exit can be proven, so a worker whose identity was never recorded
blocks the wait rather than being silently counted as drained.

Tuning: `SERGEANT_DRAIN_WAIT_TIMEOUT_SECS` (default 300),
`SERGEANT_DRAIN_WAIT_INTERVAL_SECS` (default 2), and
`SERGEANT_DRAIN_LOCK_TIMEOUT_SECS` (default 10) for the admission lock.

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
- repository-native tests/lint/typecheck/build;
- independent Standards, Spec, and Readiness reviews;
- Accessibility review for UI-facing work;
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
sgt-validate <fleet-task-id> <repo> [--skip <steps>] [--allow-argv-intent]
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

### Intent transport and the argv consent gate

Canonical intent must not appear in process arguments, where any local process
can read it from `ps` or `/proc/<pid>/cmdline`. Before it creates a validation
run, `sgt-validate` probes `no-mistakes axi run --help` and requires
`--intent-file`, which delivers the intent through a path instead of argv.

When the installed no-mistakes does not offer `--intent-file`, the launch fails
closed and names the required capability, the observed version, the observed flag
surface, and the operator's options. No run, marker, or state change is created.
Passing `--allow-argv-intent` consents, for that invocation only, to delivering
the intent through `--intent`, accepting the exposure. Consent is a flag rather
than an environment variable so it cannot be exported once and silently reapplied
to later runs.

The transport actually launched is recorded twice: `validation_intent_transport`
holds it for the current run and is cleared when a finished run is reset for a
retry, and `validation_transport.log` appends the timestamp, transport, HEAD, and
intent revision of every committed launch so the privacy decision stays auditable
across retries. Both are owner-only. The validation worker re-checks the recorded
transport against the build that will actually run, so a no-mistakes replaced
between launch and run can neither downgrade the private transport into argv nor
invoke a flag that build rejects.

### Coordinator ownership and handover

Validation is owned by the tmux pane that dispatched the task. A coordinator in
any other pane - a new session, a restarted client, a replacement coordinator -
must take ownership explicitly:

```bash
sgt-validate <fleet-task-id> <repo> --claim-ownership
sgt-validate <fleet-task-id> <repo> --release-ownership
```

A claim is accepted only when the claiming pane proves it really runs inside the
pane it names, by walking its own process ancestry to that pane's process. A
caller that merely exports `TMUX_PANE` cannot satisfy this. The prior owner must
also be takeover-eligible: its pane is dead or absent, its recorded identity no
longer matches the live pane, or it released ownership with
`--release-ownership` from its own pane. A live, unreleased owner is never
displaced.

Every transfer appends the timestamp, reason, repository, prior and new pane, and
both identity tuples to an owner-only `coordinator_handover.log` in the task's
fleet directory. A release is consumed by the claim that uses it, so it cannot be
replayed later by a third pane. Each precondition failure - unset `TMUX_PANE`, a
pane that is not live, an unrecorded or malformed pane ID, an unrecorded or
unsafely owned identity, a recycled pane, and a live or gone dispatcher - reports
its own cause and remedy.

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
