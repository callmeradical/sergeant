# Product Requirements: Dispatch Admission Control and Hard Stop

Status: Draft, awaiting explicit human PRD approval

Extends: `docs/prd-sergeant-v2.md` §7 (Quality and acceptance gates) and R7
(Operator surfaces and delivery). Adapts the same problem and design intent
already implemented for Sergeant v1 (`bin/sgt-dispatch`, see the v1/`main`
branch's `openspec/changes/dispatch-admission-control/`) to v2's Go/SQLite
architecture — this is a re-implementation of the same product requirement,
not a code port; v1's bash/tmux mechanism does not apply here.

## Summary

`POST /api/dispatch` spawns a new agent-phase process for every dispatched
repo unconditionally, with no cap on how many runs are concurrently active
and no awareness of machine load. This PRD requires v2 to check a
durable, server-wide budget before starting a new run, queue an
over-budget dispatch instead of spawning it or failing the call, and
provide a way to stop everything running right now.

## Problem

`internal/ui/dispatch.go:323` fires a dispatch as a bare
`go srv.executeRun(ctx, cancel, engine, proj, taskID, brief, targetRepos, change.Dir)`
— a goroutine with no admission check before it. The same pattern exists
for resumed runs (`internal/ui/run_lifecycle.go:140`). Each agent phase
within a run execs a real OS process (`internal/runner/runner.go:559`,
`exec.CommandContext`). A grep across the engine, server, and runner for
any concurrency cap, semaphore, or load check (`Concurren|MaxWorkers|
Semaphore|runtime.NumCPU|loadavg`) returns zero matches: nothing bounds
how many of these processes can be running at once.

This is the identical failure mode v1 hit and fixed (support #41): two
independent dispatch calls (or one call across many repos) can spawn
unbounded concurrent agent processes, oversaturating the machine and
starving already-running work. v2 is structurally less exposed than v1
was — one server process per machine rather than N independent
coordinators — but a single server instance still has no cap of its own,
and nothing prevents two browser tabs, two MCP callers, or a script
loop from firing enough concurrent `/api/dispatch` calls to reproduce the
same problem against one v2 instance.

## Proposal

1. **A durable, queryable count of non-terminal runs**, not a tmux-pane
   liveness proof the way v1 needed — every run is already tracked in
   `store.Store`, so "how many runs are currently active" is a plain
   query against existing schema, not new state.
2. **A configurable budget**, checked in `handleDispatch` before
   `srv.executeRun` is ever invoked (and before the resumed-run path in
   `run_lifecycle.go`), derived from machine specs (CPU count) by
   default and reducible under load, matching v1's settled decision that
   the ceiling scale with the machine rather than be a fixed constant.
3. **A durable queue** for a dispatch call that would exceed the budget:
   the run is still created and returned to the caller (same response
   shape, same run ID, no behavior change for a caller that never hits
   the budget) but its actual execution is deferred until capacity frees.
   FIFO by default, with a way for an operator to reorder it — the same
   settled decision v1 made.
4. **A background promotion loop**, following the exact pattern already
   established for `fleetCleanupLoop` and `retentionLoop`
   (`internal/ui/server.go:210,214`): a persistent, server-owned loop
   that checks the budget and promotes the next queued run when capacity
   exists.
5. **A hard-stop endpoint**, independent of any per-run cancel, that
   signals every active run to stop immediately — the same two-tier
   shape v1 settled on (a default tier that gives a run's phase process
   a bounded grace period, and a `--force`-equivalent immediate
   termination), so an operator is never stuck if the queue/budget
   mechanism itself misbehaves.

## Non-Goals

- Porting v1's bash implementation. The mechanism (SQLite query, Go
  goroutine, HTTP endpoint) is necessarily new code, built to the same
  product requirement.
- Fine-grained per-phase resource estimation. A run's unit of cost is
  treated as "one active agent-phase process," matching v1's settled
  decision.
- Cross-machine or multi-instance coordination. The budget and queue are
  scoped to one running `sergeant ui` server process.
- Changing `Retries`, `Type`, `RequestID`, or any other existing
  `/api/dispatch` field's behavior.

## Acceptance Criteria

- `/api/dispatch` (and the resumed-run path) checks the current
  non-terminal-run count against a configurable budget before starting
  any process.
- An over-budget dispatch call still returns a valid run ID and is
  recorded durably as queued, not rejected and not silently spawned
  anyway.
- A background loop (co-located with the existing cleanup/retention
  loops) promotes queued runs automatically as capacity frees, with
  manual reorder available to an operator.
- The dashboard/API surfaces a distinct "queued" state for a run
  awaiting admission, not indistinguishable from a run that has started
  but produced no output yet.
- A hard-stop endpoint exists that terminates every active run's phase
  process immediately, independent of the per-run cancel path, with a
  default grace-period tier and an immediate-force tier.
- Regression coverage for the originating scenario: two dispatch calls
  where neither alone exceeds the budget but the combined total does —
  the second one queues.

## Open Questions

1. What is the default budget, and should it be configurable per
   installation (a server-level setting, likely surfaced on the settings
   page proposed in `docs/prd-settings-page.md`) rather than a compiled
   constant?
2. Should the budget also factor in host load/memory (matching v1's
   settled decision), or is a run-count cap alone sufficient given v2's
   already-lighter per-run footprint (one goroutine + one subprocess,
   not a full tmux pane)?
3. Does hard-stop need per-project scope, or is "every active run on
   this server" sufficient for v1 parity?
4. How does hard-stop interact with a run's own durable state — does a
   force-stopped run land in a distinct terminal status (e.g.
   `force-stopped`, mirroring v1's fleet vocabulary) so it's
   distinguishable from an ordinary failure in delivery history?
