# Tasks — Data retention and rotation

One repository, `sergeant-v2`, one task list. Task 3 depends on
`pipeline-artifacts` having landed (its `artifacts` table); Tasks 1-2 do
not.

## Task 1 — Config, schema, and rollup storage

Repository: `sergeant-v2`. Depends on: nothing.

Read first: this change's `design.md` in full; `internal/config/config.go`'s
`Export`/`Graphify` fields for the pointer convention; `internal/store/delivery.go`
for the metadata-row pattern.

Build:
- Add `Retention` to `internal/config/config.go`, following design.md's
  exact shape, plus the "positive horizons or reject" validation.
- Add `retention_rollups` to `migrateAddTables`.
- Add `internal/store/retention.go`: `RetentionRollup`,
  `GetRetentionRollup`.

Verification: `go build ./... && go vet ./internal/... && go test
./internal/... -count=1 -skip
'^(TestBuildProjectGraphAppliesExcludePatterns|TestBuildProjectGraphMergesEveryParticipatingRepo|TestIncludeGroupsExcludesNonMatchingRepos|TestBuildNeverLeavesOutputInAPartialState|TestPublishFailureRestoresPriorGraph|TestBuildNeverSpawnsSgtGraphify|TestQueryAgainstABuiltGraphReturnsAnAnswer|TestExplainAndAffectedAreDistinctFromQuery|TestMCPGraphQueryAgainstABuiltGraphReturnsAnswer|TestBuildGraphEndpointBuildsAndPublishes)$'`.

Scenarios:
- A project YAML with no `retention:` block loads with `Retention == nil`.
- A project YAML with `retention: {runs_after_days: 0}` fails to load with
  a clear error, not a silently-accepted zero horizon.
- `GetRetentionRollup` for a project with no rollup row yet returns "not
  found," not a zero-valued row indistinguishable from real zero counts.

## Task 2 — Rotation and analytics integration

Repository: `sergeant-v2`. Depends on: Task 1.

Read first: `internal/ui/fleet.go`'s `fleetCleaner`/`runFleetCleanupLoop`
(the pattern `retentionRotator` follows); `internal/store/store.go`'s
`RunsEligibleForCleanup` and `DeriveIntentStatus`; `internal/store/analytics.go`'s
`ComputeWorkAnalytics`.

Build:
- Add `RotateProject` to `internal/store/retention.go`, exactly per
  design.md's eligibility rule (terminal status, every bullet of the
  run's intent — if any — at `merged`, older than cutoff): fold into the
  project's rollup row, then delete phases/envelopes/deliveries/the run
  row.
- Add `internal/ui/retention.go`'s `retentionRotator`/`runRetentionLoop`,
  started from `Server.Start()` alongside the existing fleet-cleanup loop
  startup, for every project with a non-nil `Retention`.
- Extend `ComputeWorkAnalytics` to fold in each project's
  `RetentionRollup` before returning, per design.md.
- Extend the `GET /api/analytics` response and its dashboard drawer with
  the `retention` summary object.

Verification: same command as Task 1.

Scenarios needing real, test-first coverage:
- A terminal run older than its project's cutoff, with no intent, rotates:
  its rollup counts increase and its run/phase rows are gone afterward.
- A terminal run whose intent has an unmerged bullet does NOT rotate, even
  past cutoff — evidence for an in-flight intent is never removed.
- A non-terminal run does NOT rotate, even past cutoff.
- After rotation, `ComputeWorkAnalytics`' totals for the rotated run's
  outcome/work-type/provenance are unchanged from what they were
  immediately before rotation (rollup + remaining raw rows == the same
  totals raw rows alone gave before).
- A project with no `Retention` configured never rotates anything,
  regardless of how old its runs are.

## Task 3 — Artifact rotation

Repository: `sergeant-v2`. Depends on: Task 2, and on `pipeline-artifacts`
having landed its `artifacts` table (guard with `hasTable("artifacts")`
before querying it if that change has not landed yet, per design.md).

Build:
- Add `RotateArtifacts` to `internal/store/retention.go`: deletes artifact
  rows and their durable files older than `ArtifactsAfterDays`,
  independent of their parent run's own rotation state.
- Wire it into `runRetentionLoop` alongside `RotateProject`.

Verification: same command as Task 1.

Scenarios:
- An artifact older than `ArtifactsAfterDays` is deleted (row and durable
  file both gone) even when its parent run has not yet reached its own,
  longer, `RunsAfterDays` cutoff.
- An artifact newer than `ArtifactsAfterDays` survives a rotation pass
  untouched.
