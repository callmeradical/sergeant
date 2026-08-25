# Proposal — Server dispatch/execution decomposition

## Repository

One repository: `sergeant-v2`.

## Requirements served

`docs/prd-server-execution-path-decomposition.md`, which extends the
`internal/ui/server.go` decomposition already landed this session
(`refine.go`, `bulletstate.go`, `fleet.go`, `gitutil.go`, `delivery.go`).

This change covers only the group that PRD names as qualitatively larger
and riskier than the rest: `handleDispatch`/`createRunAndDispatch`/
`executeRun`. The other three named groups (plans/bullets-approval,
workflow/DAG-discovery, run-cancel/resume/delete) are
`server-remaining-groups-decomposition`, a separate change — see
`design.md`'s "Rejected alternatives" for why.

## Problem

`internal/ui/server.go` (currently 1,930 lines) still holds the run-
execution state machine as one undivided block:
`targetRepositories` (971), `handleDispatch` (983-1137),
`createRunAndDispatch` (1137-1243), `dispatchResponse` (1243-1264),
`respondWithExistingRun` (1264-1302), `firstLine`/`marshalRaw`
(1302-1321), `executeRun` (1479-1658), `recordTerminalRun` (1658-1691),
`blockedReasonForRun` (1691-1759), `reposForRun`/`passedPhaseNames`/
`appendRunProgress` (1831-1930) — roughly 500 of the file's 1,930 lines.

This is the code every one of today's four-change implementation batch's
dispatches actually ran through — the highest-traffic path in the file —
and it reaches directly into `*store.Store` (11 distinct methods),
`*dag.Engine`, and `runner.ValidateAgent` with no seam a test can substitute
a fake through, the same "awkward, untestable-in-isolation dependency"
shape the four already-extracted groups had before their own moves.

## Proposal

1. Write characterization tests pinning `handleDispatch`'s and
   `executeRun`'s current externally-observable behavior (HTTP status
   codes/response shapes for the dispatch endpoint's request-validation
   branches; that a run record, intent record, and bullet records are
   created with the fields they have today; that `executeRun`'s background
   goroutine calls `RunStage` per configured DAG stage in order and records
   a terminal run status) — before any code moves, against the CURRENT
   file layout.
2. Move the named functions verbatim into `internal/ui/dispatch.go`.
3. Introduce exactly one interface seam: `stageRunner`, a 1-method
   interface (`RunStage(ctx context.Context, runID string, stage
   *config.DAGStage) error`) that `*dag.Engine` already satisfies without
   modification. `executeRun`'s `engine *dag.Engine` parameter becomes
   `engine stageRunner`. This is the one dependency in this group with a
   real, immediate testability payoff: a test can now drive `executeRun`
   with a fake stage runner that never shells to git or spawns a real
   agent process, instead of requiring a real `*dag.Engine` (which itself
   requires a real git worktree and a real or stubbed agent CLI) for every
   `executeRun` test.
4. Deliberately do NOT introduce an interface for `*store.Store` in this
   group — see `design.md`'s "Rejected alternatives".

## Out of scope

- The other three groups this PRD also names (separate change).
- Any change to `handleDispatch`'s validation order, response shapes, or
  `executeRun`'s stage-execution behavior. Pure move plus one seam.
- Any change to `*dag.Engine`, `*store.Store`, or `runner.ValidateAgent`
  themselves.
