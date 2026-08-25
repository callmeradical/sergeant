# Tasks — Server remaining-groups decomposition

One repository, `sergeant-v2`, three tasks. All three are independent of
each other and of `server-dispatch-execution-decomposition` — no shared
type, no ordering dependency. Any may merge in any order.

Read first, for all three tasks: the four prior decomposition commits
(`git show e83e283 fd9dc1e 2528bf1 e6d7794`) for style — verbatim move, a
doc comment on the new file explaining what moved and why (or why no
interface), matching conventions exactly.

## Task 1 — plans/bullets-approval → `internal/ui/plans.go`

Read first: `internal/ui/server.go` lines 577-865 (current layout).

- Write characterization tests against the CURRENT code covering the
  "plan proposal, approval, and rejection" scenarios in
  `specs/plans-workflow-run-lifecycle-decomposition/spec.md`. Confirm
  they pass before moving anything.
- Move `handlePlans`, `handleApprovePlan`, `handleRejectPlan`,
  `writePlanState`, `handleValidateIntent` verbatim into
  `internal/ui/plans.go`. No interface introduced (design.md).
- Re-run the characterization tests unmodified; they must still pass.

## Task 2 — workflow/DAG-discovery → `internal/ui/workflow.go`

Read first: `internal/ui/server.go` lines 865-971 (current layout).

- Write a characterization test against the CURRENT code covering the
  "workflow discovery" scenario in
  `specs/plans-workflow-run-lifecycle-decomposition/spec.md`.
- Move `handleDiscoverWorkflow`, `handleSaveDAG` verbatim into
  `internal/ui/workflow.go`. No interface introduced.
- Re-run the characterization test unmodified; it must still pass.

## Task 3 — run-cancel/resume/delete → `internal/ui/run_lifecycle.go`

Read first: `internal/ui/server.go` lines 1321-1356, 1448-1479, 1759-1831
(current layout).

- Write characterization tests against the CURRENT code covering the
  "run cancel, resume, and delete" scenarios in
  `specs/plans-workflow-run-lifecycle-decomposition/spec.md`.
- Move `handleRunCancel`, `handleRunDelete`, `handleRunResume` verbatim
  into `internal/ui/run_lifecycle.go`. No interface introduced.
- Re-run the characterization tests unmodified; they must still pass.

## Verification (every task)

`go build ./... && go vet ./internal/... && go test ./internal/...
-count=1 -skip
'^(TestBuildProjectGraphAppliesExcludePatterns|TestBuildProjectGraphMergesEveryParticipatingRepo|TestIncludeGroupsExcludesNonMatchingRepos|TestBuildNeverLeavesOutputInAPartialState|TestPublishFailureRestoresPriorGraph|TestBuildNeverSpawnsSgtGraphify|TestQueryAgainstABuiltGraphReturnsAnAnswer|TestExplainAndAffectedAreDistinctFromQuery|TestMCPGraphQueryAgainstABuiltGraphReturnsAnswer|TestBuildGraphEndpointBuildsAndPublishes)$'`
(excludes tests needing a live LLM key, confirmed pre-existing/
environmental this session). Do not report a task complete when this
command fails.
