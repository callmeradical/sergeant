# Design — Server remaining-groups decomposition

## Ownership

One repository, `sergeant-v2`. Three independent tasks — no shared type
between them, and none depends on `server-dispatch-execution-
decomposition` (disjoint functions; either change may merge first).

## Plans/bullets-approval → `internal/ui/plans.go`

Move `handlePlans`, `handleApprovePlan`, `handleRejectPlan`,
`writePlanState`, `handleValidateIntent` verbatim (lines 577-865 of the
current `server.go`).

## Workflow/DAG-discovery → `internal/ui/workflow.go`

Move `handleDiscoverWorkflow`, `handleSaveDAG` verbatim (lines 865-971).

## Run-cancel/resume/delete → `internal/ui/run_lifecycle.go`

Move `handleRunCancel`, `handleRunDelete`, `handleRunResume` verbatim
(lines 1321-1356, 1448-1479, 1759-1831).

## No new interface for any of the three groups

Workflow/DAG-discovery has zero `*store.Store` dependency — the same "no
real seam to justify one" case `refine.go` and `bulletstate.go` already
established in the prior pass.

Plans/bullets-approval (5 distinct `*store.Store` methods) and run-cancel/
resume/delete (3 methods) are closer to `server-dispatch-execution-
decomposition`'s rejected "broad `runStore` interface" case than to
`fleet.go`/`delivery.go`'s justified one: this codebase has no existing
convention of testing plan-approval or run-cancel/resume/delete logic
against a faked store rather than a real one, and neither group's current
tests are blocked on the lack of one — they already exercise these
handlers against a real store today. Introducing an interface here would
be adding an abstraction because the method count happens to fit a
checklist, not because a concrete testability gap exists — the "premature
abstraction" anti-pattern this session's own Go-interfaces review flagged
as the thing to avoid. All three groups move as a pure file
reorganization, verified by characterization tests, with no interface
introduced.

## Rejected alternatives

**Bundling these three groups into `server-dispatch-execution-
decomposition`.** Rejected there — see that change's `design.md`. These
three are collectively smaller and lower-risk than dispatch/execution
alone and should not wait on however long characterizing that group takes.

**Introducing a `planStore`/`runLifecycleStore` interface for symmetry
with `fleetRunSource`/`runGetter`.** Rejected above: no demonstrated
testability gap, would be abstraction for its own sake.
