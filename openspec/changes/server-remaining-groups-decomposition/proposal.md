# Proposal — Server remaining-groups decomposition

## Repository

One repository: `sergeant-v2`.

## Requirements served

`docs/prd-server-execution-path-decomposition.md`. This change covers the
three groups the PRD names other than dispatch/execution
(`server-dispatch-execution-decomposition`, a separate change — see that
change's `design.md` for why the two are split).

## Problem

After the prior four-group pass and after `server-dispatch-execution-
decomposition`, `internal/ui/server.go` still holds three further cohesive
groups as part of the same undivided file:

- **Plans/bullets-approval**: `handlePlans` (577), `handleApprovePlan`
  (610), `handleRejectPlan` (690), `writePlanState` (722),
  `handleValidateIntent` (750) — D2's inferred-plan proposal/approval/
  rejection flow. Reaches `srv.Store.GetIntent`, `.ListBulletsForIntent`,
  `.ListIntentsByStatus`, `.UpdateBulletStatus`, `.UpdateIntentStatus`.
- **Workflow/DAG-discovery**: `handleDiscoverWorkflow` (865),
  `handleSaveDAG` (909). No `*store.Store` dependency at all.
- **Run-cancel/resume/delete**: `handleRunCancel` (1321), `handleRunDelete`
  (1448), `handleRunResume` (1759). Reaches `srv.Store.DeleteRun`, `.GetRun`,
  `.UpdateRunStatus`.

None of these three is independently testable today without exercising the
whole `server.go` file, and each — like the four already-extracted groups —
has no test pinning its current external behavior before any code moves.

## Proposal

For each of the three groups: write characterization tests against the
CURRENT code, move the group verbatim into its own file
(`plans.go`, `workflow.go`, `run_lifecycle.go`), re-run the characterization
tests unmodified to confirm no behavior changed. See `design.md` for why
none of the three gets a new interface seam.

## Out of scope

- The dispatch/execution group (separate change).
- Any change to any route's validation order or response shape.
- Any change to `*store.Store`, `internal/dag`, or `internal/config`.
