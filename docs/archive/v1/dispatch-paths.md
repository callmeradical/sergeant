# The two dispatch paths

Sergeant has **two independent dispatch implementations**. They are not variants of
one engine; they share no code. Knowing which one you are using determines what
guarantees you get.

| | `sgt-dispatch` (shell) | Web UI / `POST /api/dispatch` (Go) |
|---|---|---|
| Entry point | `bin/sgt-dispatch` (~1060 lines) | `internal/ui/server.go` → `internal/dag`, `internal/runner` (~440 lines) |
| Agent execution | persistent **interactive** session in a tmux pane | **headless** one-shot, 45s timeout per phase |
| Worktree isolation | yes | yes |
| Per-run branch | yes | yes (`sergeant/<run-id>`) |
| Commits agent output | yes | yes |
| Deterministic gate order | yes | yes (sorted by gate name) |
| Handoff envelopes | yes | yes (`handoff.Router`) |
| td task creation | yes (`sgt-td-create`) | **no** |
| `.sergeant-intent.md` canonical intent | yes | **no** |
| Independent review worker | yes | **no** |
| `no-mistakes` shipping gate (`sgt-validate`) | yes | **no** |
| Worker supervision (`sgt-watch`, `sgt-respond`, `sgt-wake`) | yes | **no** |
| Drain / cooperative shutdown | yes | **no** |
| Opens a pull request | yes | **no** — reports branch state; PR is an explicit action via `/api/create-pr` |
| Accepted agents | `opencode`, `oc`, `goose`, `claude` (rejects others) | `opencode`, `oc`, `claude`, `goose`, `codex`, `pi` |

## Which to use

- **Real multi-repo delivery work → `sgt-dispatch`.** It is the path `AGENTS.md`
  describes, and the only one with task tracking, independent review and a shipping
  gate.
- **The Web UI is an observability surface with a lightweight dispatch attached.**
  Use it to watch runs, inspect phases and handoff envelopes, and fire quick
  headless jobs. Do not expect it to produce a reviewed, tracked, shippable change.

## Known divergences that are bugs, not design

These are places the two paths disagree where they arguably should not:

1. **Accepted agent sets differ.** `AGENTS.md` states dispatch "rejects every other
   agent and all non-interactive launch modes"; that constraint is enforced only in
   the shell path. The Go path accepts `codex` and `pi` and runs them headlessly.
   Either the constraint is real and the Go path should enforce it, or the
   documentation overstates it.
2. **The 45-second per-phase timeout is Go-path-only** and is not configurable.
   Non-trivial agent work will be truncated. `internal/runner/runner.go` bounds each
   attempt with `context.WithTimeout(ctx, 45*time.Second)`.
3. **No task record.** A UI dispatch leaves no td task, so work done through the UI
   is invisible to `sgt-td-list` and to the workflow in `AGENTS.md` step 2
   ("check the queue").

## If you unify them

The shell path's execution model (persistent interactive agent in a tmux pane,
resumable via `sgt-respond`/`sgt-wake`) is fundamentally different from the Go
path's (headless, bounded, one-shot). Unification is an architecture decision, not
a refactor: either the Go engine gains session persistence and supervision, or the
UI's dispatch becomes a thin trigger that shells out to `sgt-dispatch` and the Go
engine is retired. Picking one is a prerequisite to closing the gaps above.
