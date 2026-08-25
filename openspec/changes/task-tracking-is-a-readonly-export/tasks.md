# Tasks — Task tracking is a read-only export

One repository, `sergeant-v2`, so one task.

## Task 1 — a second, independent reader of the existing change log

Repository: `sergeant-v2`. Depends on: nothing. Read first:
`internal/store/changes.go` in full (the `changes` table, `ListChangesSince`,
`SubscribeChanges`'s doc comment on why a fallback tick is required),
`internal/store/store.go`'s `migrateAddTables` (table-registration
convention) and `CreateIntent`/`UpdateBulletStatus` (existing error-handling
style to match), `internal/config/config.go`'s `Graphify` field (the
pattern `Export` must follow), and `internal/redact/redact.go`'s `Text`
function.

- Add `internal/export/export.go`: the `Target` interface and `Record`
  struct exactly as specified in design.md.
- Add `internal/export/runner.go`: `Runner` and `Run`, implementing the
  poll-and-deliver loop from design.md — load cursor, `ListChangesSince`,
  filter to `store.ChannelIntent`/`store.ChannelBullet`, re-fetch the
  current row (never trust `ChangeRecord.Payload` as complete), build a
  `Record` with `Statement` passed through `redact.Text`, call
  `Target.Export`, advance the cursor only past a fully-exported batch.
- Add `createExportCursorTable` and `LoadExportCursor`/`SaveExportCursor` to
  `internal/store/store.go`; register the table in `migrateAddTables`'s
  `wanted` slice.
- Add `Export *Export` to `config.Project` in `internal/config/config.go`,
  modeled exactly like `Graphify` (pointer, `omitempty`, preserved by the
  existing YAML round-trip — do not add special-case save logic).
- Wire `Runner` into `cmd/sergeant/main.go`'s `startUI`: construct a
  `Runner` per project with an `Export` block configured and start `Run` in
  a goroutine alongside the HTTP server.
- Do not implement any `Target`. Do not add a `Sync`/read-back method to
  the interface. Do not touch `recordTransition` or any of its callers.

Verification: `go build ./... && go vet ./internal/... && go test
./internal/... -count=1`. Tests must cover every scenario in
`specs/task-export/spec.md`:

- "A bullet status change is exported" / "An intent creation is exported":
  call `Runner.Run` (or its per-tick step directly, not only through
  `startUI`) against a store with a fake `Target` that records what it
  received; assert the record's fields.
- "Transitions are exported in the order they occurred": drive two
  transitions, assert the fake `Target`'s call order.
- "A transition is not exported twice across a restart": run one tick,
  persist/reload the cursor via a fresh `Runner` backed by the same store,
  run a second tick, assert the fake `Target` was not called again for the
  same transition. This must exercise `LoadExportCursor`/
  `SaveExportCursor` directly, not only by running the loop twice in the
  same process.
- "A bullet status update succeeds even though its export target is
  unreachable": call `Store.UpdateBulletStatus` directly (not through the
  export loop) and assert success — this scenario is about the write path
  being unaffected, so it must not go through `Runner` at all.
- "An export failure is retried on a later attempt without re-running the
  original write": a fake `Target` that fails once then succeeds; assert
  the cursor did not advance past the failed record and that no second
  store write occurred (spy on the store, or assert `UpdatedAt` is
  unchanged between ticks).
- "An intent's statement is redacted before export" / "An exported record
  contains no worktree path, branch name, or PR URL": assert directly on
  the `Record` a fake `Target` receives, not on the underlying `BulletRecord`.
- "No target is configured": a project with no `Export` block; assert the
  fake `Target` (if constructed for a different project in the same test
  run) receives zero calls for this project's transitions.

Exit status decides the outcome.
