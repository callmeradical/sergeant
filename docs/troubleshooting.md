# Troubleshooting

Use the Sergeant API and stored state before manual process or Git operations.
Preserve exact errors and state before recovery.

## API unreachable

Check that the UI/API server is running and answering:

```bash
curl http://127.0.0.1:8484/api/runs
```

If it does not answer, start it with `sergeant ui` from the Sergeant checkout,
or confirm `mise run install` completed successfully.

## Project is missing or wrong

```bash
curl http://127.0.0.1:8484/api/projects
ls ~/.config/sergeant/
```

Project name is the YAML filename without `.yaml`. Validate fields against
[schema.md](schema.md). Do not infer a project from the current repository.

## Repository is missing or behind

```bash
git -C <repo-path> status
git -C <repo-path> fetch
```

Read `<repo-path>` from the project YAML (`repos[].path`). v2 does not clone or
sync repositories on an operator's behalf — a missing or non-git path is
refused, not fetched. Do not pull across unrelated dirty changes. Preserve or
reconcile the owning worktree first.

## Worker says `in_progress` but is not moving

```bash
curl "http://127.0.0.1:8484/api/run-details?id=<run-id>"
```

Check the stalled phase's `duration_ms` and whether the worktree under
`~/.local/share/sergeant-v2/fleet/<run-id>/<repo>/` has recent file-modification
activity — v2 has no tmux pane to check `pane_activity` against. `in_progress`
well past the phase's expected budget (`SERGEANT_AGENT_TIMEOUT`,
`SERGEANT_GATE_TIMEOUT`) with no recent worktree activity is a stall. Preserve
the worktree and branch, resolve the cause, then `POST /api/run-resume` with
`{"id": "<run-id>"}` (see `skills/dispatch/SKILL.md`).

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

## Graphify output is wrong or recursive

Run `GET /api/project-details?name=<project>` (or read the project YAML) and
inspect the project's `graphify.output` block. Keep one output per project
outside source repositories. Rebuild with `POST /api/build-graph`
(`{"project": "<project>"}`, decision D9) rather than moving or regenerating an
existing graph without confirming the desired global-per-project path.

## Where to inspect state

| State | Path or command |
|---|---|
| Project registry | `~/.config/sergeant/` |
| Run/bullet/intent state | `~/.local/share/sergeant/sergeant.db` — via the API or `sqlite3` directly |
| Worktree | `~/.local/share/sergeant-v2/fleet/<run-id>/<repo>/` |
| Git state | `git status`, worktree list, branch and PR heads |
| no-mistakes run | `no-mistakes axi status --run <id>` |


If documentation does not cover the observed failure, use the `sergeant-help`
skill to search the docs, then create a td task containing the exact reproduction,
expected behavior, preserved state, and acceptance criteria.
