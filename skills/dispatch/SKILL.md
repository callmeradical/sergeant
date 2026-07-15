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
Backend: local tmux (or --remote for cleanthes)
```

Ask for confirmation before dispatching.

### Step 2 — Dispatch

```bash
bin/sgt-dispatch <project> "<brief>" \
  --repos <repo1>,<repo2>,<repo3> \
  --branch <branch-name> \
  --deps "<prereq>><dependent>,..." \
  [--remote]
```

The script:
1. Generates a task ID
2. Creates a git worktree per repo at `<repo-path>/../<repo-name>-sgt-<task-id>/`
3. Writes a `.sergeant-brief.md` into each worktree with: the mission, merged agent instructions, dependency notes, and delivery requirements
4. Spawns an agent in each tmux window (local) or via babydriver (remote)
5. Creates fleet state at `~/.local/share/sergeant/fleet/<task-id>/`

### Step 3 — Monitor

```bash
bin/sgt-watch <task-id>
```

This polls every 5 seconds, syncs `.sergeant-status` and `.sergeant-result` from worktrees into fleet state, and prints a live status table. It exits when all repos are `done`.

You can also attach to the tmux session directly to observe or assist a worker:

```bash
tmux attach -t sgt-<task-id>
# Switch windows with: Ctrl-b <window-number>
```

### Step 4 — Reconcile results

When all workers are done, review the PRs:
- Check dependency order: merge infra before API before app if there are runtime dependencies
- If any repo failed, read the failure reason from fleet state and decide: retry, fix manually, or reassign
- Note any cross-repo implications in each PR description (e.g., "merge after smith-infra #42")

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
2. Do the work in the worktree (already on the correct branch)
3. Follow the `agent_instructions` from the brief
4. Run tests and lint before committing
5. Open a PR via `gh pr create`
6. Write `echo "https://..." > .sergeant-result`
7. Write `echo "done" > .sergeant-status` (or `"failed: <reason>"`)

`sgt-watch` polls for those files and surfaces them.

---

## Flags reference

| Flag | Description |
|---|---|
| `--repos repo1,repo2` | Which repos to dispatch (required) |
| `--branch <name>` | Branch name used in all worktrees (default: derived from brief) |
| `--deps "a>b,a>c"` | `a` must complete before `b` and `c` can merge |
| `--remote` | Dispatch via babydriver to cleanthes instead of local tmux |
| `--dry-run` | Print what would happen, don't create worktrees or spawn agents |

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Worker stuck, no status update | `tmux attach -t sgt-<task-id>` and check the window |
| Worktree creation fails | Check if branch already exists; use `--branch` with a unique name |
| babydriver dispatch fails | Run `babydriver usage` to check env health; ensure `BABYDRIVER_SERVER` is set |
| Fleet state is stale | Run `bin/sgt-watch --sync <task-id>` to force a one-shot sync |
| Need to retry a failed repo | Fix the worktree manually, then re-write `.sergeant-status: done` |
