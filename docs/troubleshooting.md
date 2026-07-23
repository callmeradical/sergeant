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
2. Exact recorded tmux pane and supervisor PID.
3. Active child command/tool process.
4. td handoff and current Git branch/worktree state.

A live parent process is insufficient. Do not kill or relaunch until the worktree,
branch, task, response generation, and handoff are preserved.

## Worker became orphaned after blocking

Read `.sergeant-message`, td handoff, response generation, and worker exit reason.
An expected dependency-blocked exit must remain blocked; it is not an orphan merely
because the process ended. Use supported response/recovery after reconciling the
record, and do not clean its worktree.

## Response already pending

Do not overwrite it. Inspect fleet response generation and worker acknowledgement.
Resume/recover the exact worker so it consumes the pending response, or wait for
the current generation to reach a terminal outcome.

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
  /bin/bash tests/runtime-bash-test.sh
```

This mounts the repository read-only and runs the repository-owned runtime
regression. Parsing proof does not replace runtime proof unless the task
acceptance explicitly permits parsing only.

## Graphify output is wrong or recursive

Run `sgt-context <project>` and inspect project-level `graphify.output`. Keep one
output per project outside source repositories. Do not regenerate or move an
existing graph without confirming the desired global-per-project path.

## Cleanup refuses or state is partial

Do not force or delete fleet files manually. Cleanup safety depends on terminal
proof, staged evidence, explicit cleanup phases, exact configured repository
identity, and original worktree/lease identity. Preserve the worktree and run the
owning remediation or supported retry path.

## Where to inspect state

| State | Path or command |
|---|---|
| Project registry | `~/.config/sergeant/` |
| Fleet record | `~/.local/share/sergeant/fleet/<task>/<repo>/` |
| Worker status/message/result | Worktree `.sergeant-*` files and mirrored fleet state |
| Task state | `td context <id> --work-dir <repo-path>` |
| Git state | `git status`, worktree list, branch and PR heads |
| no-mistakes run | `no-mistakes axi status --run <id>` |
| OpenCode message queue | See [oc-inject.md](oc-inject.md) |

If documentation does not cover the observed failure, use the `sergeant-help`
skill to search the docs, then create a td task containing the exact reproduction,
expected behavior, preserved state, and acceptance criteria.
