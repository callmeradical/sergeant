# Tasks — Dispatch briefs render from the stored intent

One repository, `sergeant-v2`, so one task.

## Task 1 — one rendering function, two call sites switched over

Repository: `sergeant-v2`. Depends on: nothing. Read first: `internal/store/store.go`'s
`GetIntent`, `ListBulletsForIntent`, `IntentRecord`, `BulletRecord` (existing,
reused, do not change their shape); `internal/dag/engine.go`'s `RunStage`
around lines 330-360 (`stage.Brief` usage and `SortedGateNames` call
immediately above it); `internal/mcp/server.go`'s `sergeant_get_brief` case
and its `InputSchema` registration, and `sergeant_run_gates`'s existing
pattern for loading a project and a repo's config (same file, the case
immediately below).

- Add `Store.RenderIntentBrief(intentID, repo string, gates []string)
  (string, error)` in a new file `internal/store/brief.go`, exactly as
  specified in design.md: load the intent, find the one bullet matching
  `repo`, render statement/repo/position/status/blocked-reason/change-id/
  gates. Return an error (no partial output) if the intent or the matching
  bullet cannot be found.
- In `internal/dag/engine.go`'s `RunStage`, replace the `prompt :=
  stage.Brief` block exactly as specified in design.md: load the run,
  and when it has a non-empty `IntentID`, render the brief with that
  repo's `SortedGateNames(repoCfg)` and use it as the prompt; fall back to
  today's `stage.Brief`/generic-string behavior on any error or when
  `IntentID` is empty.
- In `internal/mcp/server.go`, change `sergeant_get_brief`'s `InputSchema`
  to `intent_id` and `repo` (both required, `project` removed), and its
  implementation to resolve the intent, load that intent's project config,
  compute the repo's gate names the same way `sergeant_run_gates` already
  does, and call `Store.RenderIntentBrief`.
- Do not add an intent-wide (all-bullets) brief. Do not add a new stored
  column, table, or file for the rendered output. Do not change
  `IntentRecord`/`BulletRecord`'s shape.

Verification: `go build ./... && go vet ./internal/... && go test ./internal/... -count=1`.
Tests must cover every scenario in `specs/intent-brief/spec.md`:

- "The UI-dispatched path's agent prompt includes the intent statement and
  bullet state" and "A run with no intent id still receives stage.Brief"
  need a test that calls `RunStage` (or the smallest slice of it that
  reaches the prompt-construction block) directly with a fake/stub agent
  runner, asserting on the actual `prompt` string `RunAgentPhase` receives
  — not only on the run's final terminal status, which would not
  distinguish a rendered brief from the old raw `stage.Brief`.
- "A blocked bullet's brief includes its recorded reason" and "A bullet
  with no blocked reason omits the blocked-reason line" are direct unit
  tests of `Store.RenderIntentBrief` against a store fixture with bullets
  in each status — no HTTP or MCP layer needed.
- "sergeant_get_brief and the dispatch-time prompt agree" calls
  `Store.RenderIntentBrief` directly with the same arguments twice (once
  simulating each call site's inputs) and asserts string equality — this
  is the direct mechanism test; it must not rely on going through the
  HTTP dispatch handler and the MCP handler and comparing their side
  effects, which would leave the actual equality unverified if either
  handler's surrounding code silently diverged from calling the shared
  function.
- "sergeant_get_brief refuses a repo with no matching bullet" is a direct
  test of `Store.RenderIntentBrief` returning a non-nil error.
- "Rendering twice... produces identical output" and "no new row or file
  was written" needs a test that snapshots the store's bullet/intent rows
  (or a table count) before and after two consecutive render calls and
  asserts no change, not only that the two returned strings are equal.
