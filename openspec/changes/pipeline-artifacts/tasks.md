# Tasks — Pipeline artifacts

One repository, `sergeant-v2`, one task list.

## Task 1 — Durable storage and capture

Repository: `sergeant-v2`. Depends on: nothing.

Read first: this change's `design.md` in full; `internal/store/delivery.go`
for the metadata-row pattern this change's `artifact.go` follows;
`internal/runner/runner.go`'s `RunCodeGate` (line 264) and `RunAgentPhase`
(line 461); `internal/ui/lock.go` for the env-override pattern
(`SERGEANT_ARTIFACTS_ROOT` mirrors `SERGEANT_UI_LOCK`).

Build:
- Add the `artifacts` table to `migrateAddTables`'s `wanted` list in
  `internal/store/store.go`.
- Add `internal/store/artifact.go`: `ArtifactRecord`,
  `RecordArtifact`/`ListArtifactsForRun`/`GetArtifact`.
- Add `captureArtifacts` to `internal/runner` (design.md's exact contract:
  bounded, best-effort, never returns an error to its caller).
- Wire `SERGEANT_ARTIFACT_DIR` and the post-command `captureArtifacts` call
  into both `RunCodeGate` and `RunAgentPhase`, exactly as design.md
  specifies.

Verification: `go build ./... && go vet ./internal/... && go test
./internal/... -count=1 -skip
'^(TestBuildProjectGraphAppliesExcludePatterns|TestBuildProjectGraphMergesEveryParticipatingRepo|TestIncludeGroupsExcludesNonMatchingRepos|TestBuildNeverLeavesOutputInAPartialState|TestPublishFailureRestoresPriorGraph|TestBuildNeverSpawnsSgtGraphify|TestQueryAgainstABuiltGraphReturnsAnAnswer|TestExplainAndAffectedAreDistinctFromQuery|TestMCPGraphQueryAgainstABuiltGraphReturnsAnswer|TestBuildGraphEndpointBuildsAndPublishes)$'`.

Scenarios needing real, test-first coverage (write each as a failing test
before the code that satisfies it, per decision D3):
- A gate command that writes a file to `$SERGEANT_ARTIFACT_DIR` produces
  one durable `ArtifactRecord`, readable via `ListArtifactsForRun`, whose
  file content on disk matches what the command wrote.
- A gate command that writes nothing to `$SERGEANT_ARTIFACT_DIR` produces
  no artifact rows, and the gate's own pass/fail result is unaffected.
- A gate that writes more than the configured max file count (or total
  bytes) produces exactly the allowed artifacts plus one row whose
  `DroppedCount`/`DroppedReason` report what was skipped — never a row
  silently missing with no trace.
- A failing gate still captures whatever it wrote before failing — capture
  is not conditioned on the gate passing.
- A capture-path failure (e.g. the durable root is unwritable) does not
  turn a passing gate's result into a failure — assert the gate's own
  `Passed`/status is unaffected by a forced capture error.
- The artifact file recorded on disk survives an explicit call to whatever
  `automated-fleet-cleanup` uses to reclaim that run's worktree (i.e. the
  file lives outside the worktree path entirely) — a direct regression
  test against the ordering guarantee design.md states.

## Task 2 — API and dashboard rendering

Repository: `sergeant-v2`. Depends on: Task 1 (the store methods and table
it reads must exist).

Read first: `internal/ui/delivery.go`'s `handleDeliveryHistory` for the
route-handler pattern this task's handlers follow; `internal/ui/static/index.html`'s
`renderWorkflowGraph` (currently renders lanes into `#workflow-graph`).

Build:
- Add `internal/ui/artifacts.go`: `handleListArtifacts`,
  `handleArtifactContent`, registered in `server.go`'s existing route
  block.
- Extend `renderWorkflowGraph` to fetch and append the "Artifacts" section
  beneath the rendered lanes, exactly as design.md's Frontend section
  specifies — present only when the run has at least one artifact.

Verification: same command as Task 1, plus a manual check (no scripted
frontend test suite exists in this repo today, per the embedded-terminal
change's own precedent): dispatch a gate that writes a PNG to
`$SERGEANT_ARTIFACT_DIR`, confirm it renders as a thumbnail beneath the
workflow graph for that run, and note the manual check in the PR
description.
