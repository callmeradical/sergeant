# Tasks — Automated fleet cleanup

One repository, `sergeant-v2`, so one task.

## Task 1 — eligibility query, shared reclaim logic, background loop

Repository: `sergeant-v2`. Depends on: nothing. Read
`internal/ui/server.go`'s `handleCleanWorktrees` and `dirtyWorktreesUnder`,
`internal/store/store.go`'s `RunRecord`/`ListRecentRuns`/`runColumns`, and
`cmd/sergeant/main.go`'s startup sequence (where `ui.NewServer` and any
existing startup reconciliation already run) first — design.md names the
exact functions and their intended shapes.

- Add `Store.RunsEligibleForCleanup(cutoff time.Time) ([]RunRecord, error)`:
  runs with status in `passed`/`failed`/`cancelled`/`interrupted` and
  `updated_at <= cutoff`, using the existing `runColumns` constant rather
  than a new hand-copied column list.
- Extract `handleCleanWorktrees`'s per-directory reclaim decision (running
  check, dirty-worktree check, the actual removal) into a plain function
  both the existing HTTP handler and the new automatic pass call — do not
  duplicate this logic. The manual handler keeps its existing
  `task_id`/`dry_run`/`force` behavior unchanged; the automatic pass always
  calls the shared function with force disabled.
- Add a background loop, started once when the server starts (alongside
  wherever the server already runs its startup reconciliation), that ticks
  hourly and calls `Store.RunsEligibleForCleanup(time.Now().Add(-7*24*time.Hour))`,
  reclaiming each eligible run's fleet worktree via the shared function. A
  run whose fleet directory does not exist is skipped, not an error.
- Do not delete or modify any database row. Do not make the retention
  period or tick interval configurable. Do not change
  `handleCleanWorktrees`'s existing on-demand behavior beyond the internal
  refactor to share logic.

Verification: `go build ./... && go vet ./... && go test ./internal/... -count=1`.
Tests must cover every scenario in `specs/fleet-cleanup/spec.md`: an old
terminal run's fleet directory is removed by the automatic pass without any
API call (call the automatic-reclaim function directly in a test, not the
HTTP handler, to prove the automatic path itself works, not just the
manual one it shares code with); a recently-terminal run's worktree
survives; a running run's worktree is never touched by the automatic pass
regardless of its age (construct a fixture with an old `updated_at` but
`status: "running"`); a dirty worktree survives the automatic pass even
when old and terminal; a reclaimed run's database row (and its phases/
envelopes) are unchanged after its worktree is reclaimed. Exit status
decides the outcome.
