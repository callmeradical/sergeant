# Tasks — Export runner starts when a backend is registered

One repository, `sergeant`, so one task.

## Task 1 — registry, wiring, and a test-only backend proving the path works

Repository: `sergeant`. Depends on: nothing (task-tracking-is-a-readonly-export
is already merged). Read `internal/export/{export.go,runner.go}` and
`cmd/sergeant/main.go`'s current `startExportRunners`
(lines 171-189) first, so the new code matches existing conventions and
changes only what design.md specifies.

- Add `internal/export/registry.go`: the `Constructor` type and the
  `Backends` package-level map, exactly as specified in design.md. Starts
  empty — do not register anything in production code.
- Change `startExportRunners` in `cmd/sergeant/main.go` to accept
  `backends map[string]export.Constructor` as a second parameter. For each
  configured project with a non-nil `Export`, look up `proj.Export.Backend`
  in `backends`; on a hit, call the constructor, build an `export.Runner`,
  and start `runner.Run(context.Background())` in a goroutine; on a miss,
  keep exactly today's warning text and behavior.
- Change the one call site (`startUI`) to `startExportRunners(st,
  export.Backends)`.
- Do not implement any real `Target` backend. Do not register anything
  into `export.Backends` from production code. Do not add shutdown/restart
  handling beyond what already exists (process exit).

Verification: `go build ./... && go vet ./internal/... && go test
./internal/... -count=1 -skip
'^(TestBuildProjectGraphAppliesExcludePatterns|TestBuildProjectGraphMergesEveryParticipatingRepo|TestIncludeGroupsExcludesNonMatchingRepos|TestBuildNeverLeavesOutputInAPartialState|TestPublishFailureRestoresPriorGraph|TestBuildNeverSpawnsSgtGraphify|TestQueryAgainstABuiltGraphReturnsAnAnswer|TestExplainAndAffectedAreDistinctFromQuery|TestMCPGraphQueryAgainstABuiltGraphReturnsAnswer|TestBuildGraphEndpointBuildsAndPublishes)$'`
(that `-skip` excludes tests requiring a live LLM API key this workstation
has no key configured for — confirmed pre-existing/environmental, unrelated
to this change).

Tests must cover every scenario in `specs/export-wiring/spec.md`, and must
exercise `startExportRunners` directly (package `main`, so the new test
file lives in `cmd/sergeant/`) — not only through `main()` itself, since
`main()` is not otherwise under test:

- **Registered backend starts exporting**: call `startExportRunners` with a
  `backends` map containing one test-registered `Constructor` returning a
  recording fake `Target`, against a `SERGEANT_CONFIG` temp directory
  holding one project YAML with `export.backend: test-backend`. Poll
  (bounded wait, not a fixed `time.Sleep`) for the fake `Target`'s call
  count to become nonzero — `export.Runner.Run` calls `Tick` immediately on
  start, before its first ticker interval, so this does not need to wait
  out `defaultInterval`.
- **Unregistered backend name**: same setup, but the project's
  `export.backend` name has no entry in the `backends` map passed in.
  Assert no `Target` is constructed (the test's `Constructor`, if any is
  registered under a different name, is never called) and stderr contains
  the existing warning text.
- **No export block configured**: a project YAML with no `export:` key at
  all. Assert nothing is constructed and nothing is reported (capture
  stderr and assert it's empty, or contains no mention of that project).

Exit status of the verification command decides the outcome.
