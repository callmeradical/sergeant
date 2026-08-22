# Sergeant v2

This branch is **v2**: the Go-native engine in `cmd/sergeant` and `internal/`.
Read `docs/prd-sergeant-v2.md` before changing behaviour. Its numbered
requirements (R2.x, R3.x, R4.x) and settled decisions (D1–D7, O1–O3) are binding.

## v1 is not a dependency

The `bin/sgt-*` shell toolbelt is **v1**. On this branch:

- Do **not** call `sgt-dispatch`, `sgt-watch`, `sgt-respond`, `sgt-validate`,
  `sgt-context`, or any other `bin/sgt-*` script.
- Do **not** use tmux to run or supervise work.
- Do **not** write into v1's fleet layout at `~/.local/share/sergeant/fleet`.
- Where v1 has a capability v2 lacks (td tasks, canonical intent files,
  independent review workers, the shipping gate), that is **unimplemented v2
  scope**. Do not close the gap by shelling out to v1.

`main` still contains v1's instructions and they are correct for v1. Do not edit
`main`.

## Domain model

```
Project            a named set of repositories
  └─ Intent        a durable statement of desired change; may span repos
       └─ Bullet   ONE repo, a vertical slice through that repo's stack,
                   implemented test-first, yielding one commit and one PR
```

Intent is the primary durable object. Runs, phases and worktrees exist to serve an
intent. A bullet is scoped to exactly one repository; work in a second repository
is a second bullet. The intent holds the merge order across its bullets.

## Two ways in, one set of records

1. **Agent-driven.** The operator launches their own agent CLI (opencode, codex,
   goose, pi, claude) in a terminal inside the project. That agent talks to
   sergeant over MCP (`bin/sergeant-mcp`, declared in `mcp.json`):
   `sergeant_get_brief`, `sergeant_run_gates`, `sergeant_emit_envelope`,
   `sergeant_seal_pr`, `sergeant_status`. Sergeant does not spawn or host the
   session.
2. **Coordinator-driven.** The operator dispatches from the UI
   (`POST /api/dispatch`) and sergeant runs bounded headless agent phases itself.

Both create the same records. Adding a third, divergent execution model is a bug.

## Rules that are enforced in code

Do not weaken these. Each has a test.

| Rule | Where |
|---|---|
| Agents run in an isolated git worktree on a per-run branch; a non-git dir is refused | `internal/dag/engine.go` |
| The operator's checkout is never mutated | `TestRunStageIsolatesWorkInAWorktree` |
| Agent output is committed so it survives worktree cleanup | `TestCommitRunOutputMakesWorkRecoverable` |
| Code gates run in sorted name order | `TestGatesRunInDeterministicOrder` |
| A failed or timed-out agent phase records `failed`, never `passed` | `TestAgentPhaseFailureIsNotRecordedAsPassed` |
| Each retry attempt gets its own phase record | `TestAgentPhaseRetriesAreObservable` |
| Saving project config preserves comments, `dag:`, and unmodelled keys | `TestRefineProjectPreservesUnmanagedConfig` |
| Delivery reports never claim a PR that git cannot prove | `internal/ui/server.go` `describeDelivery` |

## Truthfulness

The dashboard is what an operator checks instead of reading logs, so it must not
display anything it cannot derive from stored state.

- Never render a status, count, duration, or progress value that is not read from
  the store.
- When data is absent, render an em dash and say what is missing.
- Never claim delivery, a pull request, or a passing gate without evidence on disk.
- `_ = json.NewEncoder(w).Encode(...)` is banned. Use `writeJSON`, which marshals
  before writing a header so a failure becomes a 500 instead of an empty 200.

## Build and test

```bash
go build ./...
go vet ./internal/...
go test ./internal/... -count=1
```

The UI is embedded with `//go:embed static/*`, so changing
`internal/ui/static/index.html` requires a rebuild before it is served.

Environment:

- `SERGEANT_AGENT_TIMEOUT` — per-attempt agent budget (default 10m)
- `SERGEANT_GATE_TIMEOUT` — per-gate budget (default 5m)
- `SERGEANT_FLEET_DIR` — worktree root; set in tests so they never touch the real path
- `SERGEANT_CONFIG` — project YAML directory

## Planning: OpenSpec

OpenSpec is a first-class planning method (O1–O3). Planning lives per repository in
`openspec/`. A change's directory travels in the pull request that implements it —
that is what produces the audit trail. Do not adopt OpenSpec Stores.

Branches are named `<type>/<change-id>` where the suffix is the OpenSpec change id.
The audit link is the `openspec/changes/<id>/` directory in the PR diff, with a
`Change-Id: <id>` trailer as the secondary link. A branch name is never the audit
link on its own.

## Task tracking

Work is tracked in `td` under epic `td-6ca1f4`. Run `td list` and
`td critical-path` in this worktree. Do not use `sgt-td-*`.
