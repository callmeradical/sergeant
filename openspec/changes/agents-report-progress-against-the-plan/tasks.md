# Tasks — A dispatched agent reports progress against its plan

One repository, `sergeant-v2`, so one task and no cross-repo merge order.

## Task 1 — seed, read and publish a reported checklist

Repository: `sergeant-v2`. Depends on: nothing.

- Parse `#### Scenario:` headings from the resolved change's delta specs.
- Write `.sergeant/plan.json` into the worktree at dispatch, one `pending` item
  per scenario with a stable id, before the agent phase starts.
- Extend the agent prompt to instruct the agent to mark items complete in that
  file as it finishes them.
- Read the file when the run is sampled and append progress to the `changes`
  sequence so it reaches the dashboard over the existing stream.
- Render `N/M reported` on the run, alongside the phase status and never in place
  of it.
- Treat an absent or malformed file as "no progress reported", never as zero, and
  never fail a run because of it.

Verification: `go build ./... && go vet ./... && go test ./internal/... -count=1`.
Tests must cover the seeded item count matching the declared scenarios, a
zero-scenario change yielding an empty plan rather than no plan, an unparseable
plan leaving the run unaffected, and a fully reported plan not turning a failed
gate into a passed run. Exit status decides the outcome.
