# Tasks — Branch names carry their work type

One repository, `sergeant-v2`, so one task.

## Task 1 — validate, record, and single-source the branch name

Repository: `sergeant-v2`. Depends on: nothing. Read
`internal/store/store.go`'s `RunRecord`/`IntentRecord`/`CreateRun`/`GetRun`/
`CreateIntent`/`GetIntent`, `internal/dag/engine.go`'s `BranchName`/
`prepareWorktree`/`Engine`, `internal/ui/server.go`'s `handleDispatch`/
`handleApprovePlan`/`createRunAndDispatch`/`handleCreatePR`/
`describeDelivery`, `internal/mcp/server.go`'s `sergeant_seal_pr` case, and
`internal/runner/runner.go`'s `DeliverPullRequest` first — design.md names
every one of these precisely; read it before writing anything.

- Add a fixed `feat`/`fix`/`refactor`/`docs`/`chore`/`test` validation set
  and reject an empty or unrecognized `req.Type` in `handleDispatch`,
  before change resolution and before either the no-repos or
  explicit-repos branch runs.
- Add `Type string` to `RunRecord` and `IntentRecord`, with real DB
  migrations (`ALTER TABLE runs/intents ADD COLUMN type ...`). Update every
  query naming other columns on these two tables to read/write `type` too
  — grep for `FROM runs`, `INTO runs`, `FROM intents`, `INTO intents` to
  find every one; do not miss any.
- Move `BranchName` from `internal/dag` to `internal/naming`, changing its
  signature to `BranchName(workType, changeID string) string` returning
  `workType + "/" + changeID`. Delete `dag.BranchName`.
- Convert `prepareWorktree` (`internal/dag/engine.go`) into a method on
  `*Engine` so it can look up the run via `e.Store.GetRun(runID)` and call
  `naming.BranchName(run.Type, run.ChangeID)` — do not thread new
  parameters through `RunStage`/`recordGateStage`/`executeRun` instead.
- Replace `internal/ui/server.go`'s `handleCreatePR`'s hand-built
  `fmt.Sprintf("sergeant/%s", req.RunID)` and `describeDelivery`'s
  `dag.BranchName(runID)` call with a run lookup plus
  `naming.BranchName(run.Type, run.ChangeID)`.
- Replace `internal/mcp/server.go`'s `sergeant_seal_pr` case's hand-built
  `fmt.Sprintf("sergeant/%s", runID)` the same way.
- Replace `internal/runner/runner.go`'s `DeliverPullRequest`'s fallback
  branch construction the same way, using `pr.Store.GetRun(pr.RunID)`.
- In `handleDispatch`'s no-repos branch, store `Type: req.Type` on the
  proposed `IntentRecord`. In `handleApprovePlan`, read `intent.Type` back
  and pass it through to `createRunAndDispatch` (a new `workType string`
  parameter, alongside the existing `existingIntentID`), which sets
  `Type` on the `RunRecord` it creates. The explicit-repos path passes
  `req.Type` directly to the same new parameter.
- Do not build any reporting/analytics view. Do not reclassify or migrate
  historical rows or branches. Do not add types beyond the fixed six.

Verification: `go build ./... && go vet ./... && go test ./internal/... -count=1`.
Tests must cover every scenario in `specs/work-type/spec.md`: a recognized
type is accepted; a missing type is refused with no run/intent/worktree
created (a real seam — an empty fleet dir and a zero-row check, not just
the HTTP status); an unrecognized type is refused the same way, naming the
valid set in the error; an executed dispatch's run records its type; a
proposed plan's intent records its type; approving a proposed plan's run
records the plan's original type, not a re-derived one; a dispatched
branch is actually named `<type>/<change-id>` (assert the real git branch
name in the worktree, not just a computed string); a `create-pr` request
targets that exact same branch name (a seam recording what branch `gh` was
invoked against, matching this project's established pattern for
verifying `gh` call arguments). Exit status decides the outcome.
