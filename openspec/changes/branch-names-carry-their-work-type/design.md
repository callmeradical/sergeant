# Design — Branch names carry their work type

## Ownership

One repository, `sergeant-v2`. Touches `internal/store/store.go` (new
`Type` field on `RunRecord` and `IntentRecord`), `internal/naming` (the new
single-sourced branch-name function), `internal/dag/engine.go`,
`internal/ui/server.go`, `internal/mcp/server.go`, and
`internal/runner/runner.go` (removing duplicated branch-string construction
from the last three).

## The fixed vocabulary and validation

A package-level set, checked before any run/intent is created:

```go
var validWorkTypes = map[string]bool{
	"feat": true, "fix": true, "refactor": true,
	"docs": true, "chore": true, "test": true,
}
```

`handleDispatch` validates `req.Type` immediately after decoding the request
body — before change resolution, before the no-repos/explicit-repos branch,
before anything is written — refusing (400) an empty or unrecognized value
with an error naming the valid set. This mirrors `ValidateAgent`'s existing
placement: reject what the engine cannot honor before any record exists.

## Where the type is stored

`RunRecord` gains `Type string`, mirroring the existing `ChangeID string`
field exactly (same migration pattern, same "recorded once, at creation"
semantics):

```go
{"runs", "type", "ALTER TABLE runs ADD COLUMN type TEXT NOT NULL DEFAULT ''"},
```

`IntentRecord` gains `Type string` for the same reason `ChangeID`/
`ChangeRepo` were added to it (this project's own recent history, decision
D2/D5a): a proposed plan resolves its work type once, at proposal time, and
approval must reuse it verbatim rather than requiring the caller to state it
again or guessing a default:

```go
{"intents", "type", "ALTER TABLE intents ADD COLUMN type TEXT NOT NULL DEFAULT ''"},
```

Every `SELECT`/`INSERT` against `runs`/`intents` that already names other
columns (`CreateRun`, `GetRun`, `ListRunsForProject`, `CreateIntent`,
`GetIntent`, `ListIntentsForProject`, `ListIntentsByStatus`, and any other
query naming these columns explicitly) must add `type` alongside them —
grep for `FROM runs`/`INTO runs`/`FROM intents`/`INTO intents` to find every
one; missing even one silently drops the field on read or write.

## The branch-name function moves to `internal/naming`

`dag.BranchName` cannot simply change its output format in place: the same
`"sergeant/<run-id>"` string is independently hand-constructed in
`internal/ui/server.go` (`handleCreatePR`) and `internal/mcp/server.go`
(`sergeant_seal_pr`), and `internal/runner/runner.go`'s `DeliverPullRequest`
has a third, dead-in-practice fallback construction. All four must agree,
or `gh pr create --head <branch>` targets a branch that does not exist.

`internal/runner` cannot import `internal/dag` (`dag` already imports
`runner` — the reverse would cycle). `internal/naming` has no internal
dependencies at all and already owns `naming.RunID()`, the other identifier
this same branch is derived from — it is the correct shared home:

```go
// in internal/naming
func BranchName(workType, changeID string) string {
	return workType + "/" + changeID
}
```

`dag.BranchName` is deleted; its two call sites in `internal/dag/engine.go`
(`prepareWorktree`'s branch derivation and `RunStage`'s use of it) call
`naming.BranchName` directly, sourcing `workType`/`changeID` from the run
record already reachable via `e.Store.GetRun(runID)` — `prepareWorktree`
becomes a method on `*Engine` (it is only ever called from `Engine` methods
today) specifically so it can reach `e.Store` without a new parameter
threaded through every caller.

`internal/ui/server.go`'s `handleCreatePR` (currently
`branch := fmt.Sprintf("sergeant/%s", req.RunID)`) and
`describeDelivery` (currently `dag.BranchName(runID)`) both already have or
can cheaply obtain the run record via `srv.Store.GetRun(...)`; both call
`naming.BranchName(run.Type, run.ChangeID)` instead.

`internal/mcp/server.go`'s `sergeant_seal_pr` (currently
`fmt.Sprintf("sergeant/%s", runID)`) does the same: look up the run via
`s.Store.GetRun(runID)`, call `naming.BranchName(run.Type, run.ChangeID)`.

`internal/runner/runner.go`'s `DeliverPullRequest` fallback
(`fmt.Sprintf("sergeant/%s-%s", pr.RunID, pr.RepoName)`, reached only when
its caller passes an empty `branch`) is replaced with
`naming.BranchName(run.Type, run.ChangeID)` via `pr.Store.GetRun(pr.RunID)`
— `internal/runner` already imports `internal/store`, so this needs no new
dependency.

## Plan approval (D5a) carries the type forward, exactly like `ChangeID`

`handleDispatch`'s no-repos branch stores `Type: req.Type` on the proposed
`IntentRecord` alongside the already-recorded `ChangeID`/`ChangeRepo`.
`handleApprovePlan` reads `intent.Type` back and passes it to
`createRunAndDispatch`, which gains one more parameter (`workType string`,
alongside the existing `existingIntentID string`) and sets it on the
`RunRecord` it creates — for both the explicit-repos path (which passes
`req.Type` directly) and the approval path (which passes `intent.Type`).

## Rejected alternatives

**Inferring the type from the brief text.** Rejected by the proposal
itself: this project already refuses to guess what a human has not stated
explicitly (D2), and a wrong silent guess is worse than a visible refusal.

**Leaving `dag.BranchName` in place and updating only some of the four
duplicated construction sites.** Rejected: this is exactly the
"wired-only-some-call-sites" failure mode this project spent significant
effort closing for redaction earlier in its history — a shared, single
function is the actual fix, not a fourth hand-copied literal that happens
to currently agree with the other three.

**Threading `workType`/`changeID` as new parameters through
`prepareWorktree`, `RunStage`, and `executeRun`.** Rejected in favor of a
store lookup inside `prepareWorktree` (now a method): fewer signatures
change, and a run record is always already durably written with its type
by the time a worktree is prepared for it.
