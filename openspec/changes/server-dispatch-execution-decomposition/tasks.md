# Tasks — Server dispatch/execution decomposition

One repository, `sergeant-v2`, one task. Independent of
`server-remaining-groups-decomposition` — no shared type, no ordering
dependency; either may merge first.

## Task 1 — characterize, extract, seam

Repository: `sergeant-v2`. Depends on: nothing.

Read first: the current `internal/ui/server.go` in full (specifically
lines 971-1877, the functions design.md names), and the four prior
decomposition commits for style (`git show e83e283 fd9dc1e 2528bf1
e6d7794`) — match their conventions exactly (verbatim move, doc comments
explaining what moved and why, `Server` struct field wiring pattern for
any interface introduced).

Steps, in order:

1. Write characterization tests against the CURRENT (pre-extraction) code
   covering every scenario in `specs/dispatch-execution-decomposition/spec.md`.
   Confirm they pass against today's code before moving anything.
2. Move `targetRepositories`, `handleDispatch`, `createRunAndDispatch`,
   `dispatchResponse`, `respondWithExistingRun`, `firstLine`, `marshalRaw`,
   `executeRun`, `recordTerminalRun`, `blockedReasonForRun`, `reposForRun`,
   `passedPhaseNames`, `appendRunProgress` verbatim into
   `internal/ui/dispatch.go`.
3. Define the `stageRunner` interface exactly as design.md specifies.
   Change `executeRun`'s `engine *dag.Engine` parameter to
   `engine stageRunner`. Update call sites' static type only — no
   behavior change.
4. Re-run the characterization tests from step 1 unmodified; they must
   still pass.
5. Add the fake-stage-runner test from
   `specs/dispatch-execution-decomposition/spec.md`'s "testable with a fake
   stage runner" scenario.

Do not touch any function this task's own scope doesn't name. Do not
introduce any interface for `*store.Store` (design.md's "Rejected
alternatives").

Verification: `go build ./... && go vet ./internal/... && go test
./internal/... -count=1 -skip
'^(TestBuildProjectGraphAppliesExcludePatterns|TestBuildProjectGraphMergesEveryParticipatingRepo|TestIncludeGroupsExcludesNonMatchingRepos|TestBuildNeverLeavesOutputInAPartialState|TestPublishFailureRestoresPriorGraph|TestBuildNeverSpawnsSgtGraphify|TestQueryAgainstABuiltGraphReturnsAnAnswer|TestExplainAndAffectedAreDistinctFromQuery|TestMCPGraphQueryAgainstABuiltGraphReturnsAnswer|TestBuildGraphEndpointBuildsAndPublishes)$'`
(that `-skip` excludes tests requiring a live LLM key this workstation
doesn't have configured, confirmed pre-existing/environmental this
session — unrelated to this change). Every scenario in
`specs/dispatch-execution-decomposition/spec.md` needs direct test
coverage, not just "the suite still passes": the fake-stage-runner
scenario specifically needs a test that calls `executeRun` directly with
the fake, not only through `handleDispatch`'s HTTP path, to prove the seam
actually removes the real-worktree/real-agent dependency rather than just
type-checking.
