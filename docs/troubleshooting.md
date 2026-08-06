# Troubleshooting

Use supported Sergeant commands before manual process, tmux, Git, or fleet-file
operations. Preserve exact errors and state before recovery.

## Command not found

Check installation and PATH:

```bash
command -v sgt-list
printf '%s\n' "$PATH"
mise run install
```

Use `bin/<command>` from the Sergeant checkout when the command is not installed.

## Project is missing or wrong

```bash
sgt-list
sgt-context <project>
```

Project name is the YAML filename without `.yaml`. Validate fields against
[schema.md](schema.md). Do not infer a project from the current repository.

## Repository is missing or behind

```bash
sgt-status <project>
sgt-sync <project>
```

Do not pull across unrelated dirty changes. Preserve or reconcile the owning
worktree first.

## Wrong `td` executable

Sergeant requires [Marcus td](https://github.com/marcus/td), including JSON,
creation, and `--work-dir` support.

```bash
td version
td create --help
```

If another executable named `td` is first on PATH, correct PATH rather than
wrapping unsupported output indefinitely. `td create --help` must show
`--description`, `--json`, and `--work-dir`.

## Worker says `in_progress` but is not moving

Collect four signals:

1. Fleet status and worker log modification time.
2. Exact recorded tmux pane identity and its tmux `pane_activity` timestamp.
3. Fleet `progress_ts` or the current stall diagnostic after `sgt-watch --sync <task-id>`.
4. td handoff and current Git branch/worktree state.

A live parent process is insufficient. `in_progress` plus a `live worker stalled`
diagnostic is still nonterminal; reconcile it through the progress rules in
[`docs/using-sergeant.md`](using-sergeant.md#monitor-work) before killing or
relaunching anything. Preserve the worktree, branch, task, response generation,
and handoff first, then use `sgt-recover <task-id> <repo>` only for that exact
stall classification. If Sergeant refuses because pane identity or unfinished
notification delivery evidence no longer matches, keep the preserved state and
follow the resulting `needs_input` handoff instead of forcing another retry.

## Worker became orphaned after blocking

Read `.sergeant-message`, td handoff, response generation, and worker exit reason.
An expected dependency-blocked exit must remain blocked; it is not an orphan merely
because the process ended. Use supported response/recovery after reconciling the
record, and do not clean its worktree.

## Response already pending

Do not overwrite it. Inspect fleet response generation and worker acknowledgement.
Resume the exact waiting worker with `sgt-respond`, or wait for the current
generation to reach a terminal outcome. Do not use `sgt-recover` for an active
response generation; it is only for an `in_progress` worker that still carries
the exact `live worker stalled` diagnostic. If the worker already applied the
response and the archive entry exists, rerun the same
`sgt-ack-response <task> <repo> <response-id>` command from the recorded worker
pane to finish acknowledgement and plaintext cleanup.

## Pane is missing

Use `sgt-watch --sync <task-id>` for one-shot classification and
`tmux list-panes -a` for pane evidence.
Missing pane plus durable blocked/handoff state is waiting work; missing pane from
`in_progress` without a handoff is orphan evidence.

## Repeated notifications

Compare task, repo, state generation, message digest, and timestamp. Repeated
notifications can be stale fleet records, unconsumed responses, or expected blocked
workers incorrectly reclassified orphaned. Do not create duplicate tasks or send
duplicate responses.

## no-mistakes is parked

```bash
no-mistakes axi status --run <run-id>
```

- `ask-user`: obtain the explicit decision.
- actionable code finding: route separate td remediation.
- auto-fix: Do not authorize an in-run fix in Sergeant's validation-only
  workflow; route the finding to separate owning-repository td remediation.
- retained gate: do not edit, abort, or restart it to bypass the finding.

If shared daemon credentials cannot access one repository, do not switch the global
GitHub account while unrelated runs are active. Use an approved repo-scoped method,
wait, or obtain an explicit manual-shipping override.

## GitHub account cannot access a repo

Inspect accounts without printing tokens:

```bash
gh auth status
```

Prefer one-shot `GH_TOKEN` for `gh` and a one-shot credential helper for Git. Do
not switch the global account while other workers may invoke GitHub operations.

## Bash 3.2 validation

The host may run a newer Bash. Use this repository-owned Bash 3.2 runtime test
when compatibility proof is required:

```bash
docker run --rm \
  -e SGT_MINIMUM_BASH=/usr/local/bin/bash \
  -v "$PWD":/workspace:ro \
  -w /workspace \
  docker.io/library/bash:3.2@sha256:3a13e5da38baa575985778cd09ce8ac736d4b4dafc91a430e71271f6e5311b89 \
  /usr/local/bin/bash tests/runtime-bash-test.sh
```

This mounts the repository read-only and runs the repository-owned runtime
regression, including the `sgt-dispatch` Bash 3.2 parse and branch-name
regression for shipped scripts. Parsing proof does not replace runtime proof
unless the task acceptance explicitly permits parsing only.

## Graphify output is wrong or recursive

Run `sgt-context <project>` and inspect project-level `graphify.output`. Keep one
output per project outside source repositories. Do not regenerate or move an
existing graph without confirming the desired global-per-project path.

## Cleanup refuses or state is partial

Do not force or delete fleet files manually. Cleanup safety depends on terminal
proof, staged evidence, exact configured repository identity, original
worktree/lease identity, explicit cleanup phases for replayed removals or
already-absent worktrees, proof that a recorded removal actually completed, and a
response handshake that is either fully converged or explicitly retired.
Preserve the worktree and run the owning remediation or supported retry path;
cleanup intentionally refuses while response archive, acknowledgement markers, or
active plaintext transport are only partially published and the handshake could
still be completed.

### Cleanup refuses an unfinished response handshake

`<repo> has pending or incomplete response acknowledgement` means a response was
delivered but never acknowledged. Resume the worker and acknowledge it with
`sgt-ack-response` from that worker's own pane; that is the only path that
completes a handshake.

When the worker is gone for good, cleanup can retire the handshake instead, but
only when both of these hold, re-checked on every attempt:

- the owning `td` task is **closed**, resolved in that repo's own repository; and
- the recorded worker is **provably dead** — its pane is gone or dead with a
  matching identity, its recorded PID is not running, no process remains in its
  recorded process group, and `worker_pid`, `worker_process_start` and
  `worker_process_group` are all recorded.

The refusal names which condition failed, for example `recorded worker process
<pid> is still alive`, `recorded worker PID <pid> was reused`, `recorded worker
pane identity does not match`, or `owning td task is in_progress, not closed`. A
live, PID-reused, or identity-mismatched owner is always refused: it is never
correct to retire a handshake underneath a worker that might still finish it.

Retirement records the exact partial state under
`~/.local/share/sergeant/fleet/<task>/<repo>/response-retirement/` before it
mutates anything — verbatim copies of both sides under `partial/`, the owner death
evidence in `owner`, and the response-archive fields it can prove. It never writes
an acknowledgement, and the `retired` marker in that directory means the archive
can never be read as one. The archive has the same lifetime as the fleet task's
`response-archive`: it exists so a retried cleanup converges, and it is removed
with the rest of the fleet state, so capture it before a successful run if you
need it. A retirement prints `retiring unfinishable response handshake: <repo>
response=<id> generation=<n> owner_pid=<pid>` in the cleanup output.

Cleanup refuses a retirement archive that no longer describes the state it
preserved — including a changed response, a tampered or symlinked copy, and a
recorded owner that has drifted — rather than trusting stale evidence.

## sgt-cleanup reports "fleet state and worktree must be on the same filesystem"

This is a deliberate constraint, not a bug. `sgt-cleanup` uses atomic rename operations
to safely move and restore evidence during terminal worker removal. Atomic rename only
works within a single filesystem (`EXDEV` on rename across devices). Sergeant therefore
refuses cross-filesystem layouts rather than falling back to a non-atomic copy+delete
that could leave evidence in an inconsistent state.

**Resolution:** Ensure `SERGEANT_FLEET` and all project worktrees reside on the same
filesystem. If you set `SERGEANT_FLEET` to a path on a different device (e.g., a network
drive or separate partition), move it to a local path on the same device as your
repositories:

```bash
# Check your current fleet location
echo "${SERGEANT_FLEET:-$HOME/.local/share/sergeant/fleet}"

# Confirm the worktree device
stat -c '%d' /path/to/your/worktree

# Confirm the fleet device (they must match)
stat -c '%d' "$SERGEANT_FLEET"
```

See `bin/sgt-cleanup:_same_filesystem_pair` for the implementation and
`tests/sgt-cleanup-cross-filesystem-test.sh` for the test coverage.

## Where to inspect state

| State | Path or command |
|---|---|
| Project registry | `~/.config/sergeant/` |
| Fleet record | `~/.local/share/sergeant/fleet/<task>/<repo>/` |
| Worker status/message/result | Worktree `.sergeant-*` files and mirrored fleet state |
| Task state | `td context <id> --work-dir <repo-path>` |
| Git state | `git status`, worktree list, branch and PR heads |
| no-mistakes run | `no-mistakes axi status --run <id>` |


If documentation does not cover the observed failure, use the `sergeant-help`
skill to search the docs, then create a td task containing the exact reproduction,
expected behavior, preserved state, and acceptance criteria.
