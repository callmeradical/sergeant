# Design — Server dispatch/execution decomposition

## Ownership

One repository, `sergeant-v2`. Standalone within itself; independent of
`server-remaining-groups-decomposition` (disjoint functions, no shared new
type).

## What moves, verbatim, to `internal/ui/dispatch.go`

`targetRepositories` (line 971), `handleDispatch` (983-1137),
`createRunAndDispatch` (1137-1243), `dispatchResponse` (1243-1264),
`respondWithExistingRun` (1264-1302), `firstLine` (1302-1313),
`marshalRaw` (1313-1321), `executeRun` (1479-1658), `recordTerminalRun`
(1658-1691), `blockedReasonForRun` (1691-1759), `reposForRun` (1831-1849),
`passedPhaseNames` (1849-1877), `appendRunProgress` (1877-1930).

(Line numbers are against the current `server.go`, post the four prior
extractions, pre this change — they will shift once
`server-remaining-groups-decomposition` also lands; whichever change
merges second should re-locate its own functions by name, not assume the
other change's numbers still hold.)

## The one interface: `stageRunner`

```go
// stageRunner is the one method executeRun needs from a stage-execution
// engine. *dag.Engine already satisfies it unmodified. The seam exists so a
// test can drive executeRun's goroutine — which today requires a real git
// worktree and a real or stubbed agent CLI via *dag.Engine — with a fake
// that records which stages ran and returns a canned result instead.
type stageRunner interface {
	RunStage(ctx context.Context, runID string, stage *config.DAGStage) error
}
```

`executeRun`'s signature changes from `engine *dag.Engine` to
`engine stageRunner`; every existing call site (inside `handleDispatch`/
`createRunAndDispatch`, which already construct a `*dag.Engine` via
`dag.NewEngine`) passes the same concrete value, which now satisfies the
narrower parameter type with no call-site change beyond the variable's
static type.

## Rejected alternatives

**One change covering all four groups the PRD names, one task each.**
Rejected: reading the current file, the dispatch/execution group alone is
~500 of `server.go`'s 1,930 lines and reaches into 11 distinct
`*store.Store` methods, `*dag.Engine`, and `runner.ValidateAgent` — an order
of magnitude more surface than any single group the prior pass extracted
(the largest, `fleet.go`, was one 2-method interface over one store
capability). The other three groups the PRD names (plans/bullets-approval,
workflow/DAG-discovery, run-cancel/resume/delete) are each smaller and each
already have SOME direct test coverage today (`handleApprovePlan`,
`handleRunCancel`, etc. are exercised by existing HTTP-handler tests). Bundling
all four into one change risks the smaller three waiting on however long
characterizing the largest one actually takes, which is itself uncertain
until someone is inside doing it. Splitting lets the three lower-risk groups
merge independently of whatever the riskiest one turns up.

**A broad `runStore` interface covering every `*store.Store` method this
group calls (`CreateRun`, `CreateIntent`, `CreateBullet`, `UpdateRunStatus`,
`DeleteRun`, `GetRunByRequestID`, `RecordEnvelope`, `CausationFromLatest`,
`ListDeliveriesForRun`, `QuarantineDelivery`, `GetRun`,
`ListBulletsForIntent`).** Rejected: this session's own Go-interfaces
review already established the rule this would violate — keep interfaces
minimal (1-3 methods), avoid a "fat interface mixing unrelated concerns."
An 11-method interface whose only implementation is `*store.Store` is
exactly the "interface pollution" anti-pattern that review found this
codebase correctly avoiding everywhere else. It would also buy nothing
real: `*store.Store` already has its own direct, real-SQLite-backed test
suite (`internal/store/*_test.go`), and every existing test for dispatch-
adjacent code in this codebase already sets up a real, lightweight,
temp-file store (`internal/dag/engine_test.go`'s pattern) rather than
faking one — there is no existing convention of faking the store for this
kind of test to mirror, unlike `fleet.go`/`delivery.go`'s narrow, real
testability gain from `fleetRunSource`/`runGetter`. This change therefore
introduces no store-facing interface at all; `*store.Store` stays a direct,
concrete dependency in the moved file, exactly as it already is in every
other handler in `server.go` that was not extracted behind a seam this
session (e.g. `handlePlans`, `handleRunDetails`).

**No interface at all, matching `refine.go`/`bulletstate.go`'s precedent.**
Considered, because those two extractions correctly added none. Rejected
for this group specifically: unlike those two (which had zero
`*store.Store`/external-package dependency), this group's `executeRun`
genuinely cannot be exercised today without either a real git worktree and
agent CLI, or an interface seam — there IS a concrete, real testability gap
here that `refine.go`/`bulletstate.go` did not have. `stageRunner` closes
exactly that gap and nothing more.
