# Tasks — A run's outcome advances its intent and bullets

One repository, `sergeant-v2`, so one task and no cross-repo merge order.

## Task 1 — advance bullets on a terminal run and derive intent status

Repository: `sergeant-v2`. Depends on: nothing.

- Add a store method that advances every bullet of a run to a given status, and
  one that recomputes an intent's status from its bullets.
- Call the advance from `Server.setTerminal` inside `Server.executeRun`, so a
  dispatch and a resume share one path.
- Map `passed` to `green` and `failed` to `failed`. Leave bullets untouched on
  `cancelled`.
- Derive intent status: `satisfied` only when every bullet is `merged`, otherwise
  `in_progress`. An intent with no bullets is `in_progress`.
- Make the advance idempotent, since a resumed run reaches the terminal path again.
- Do not backfill existing rows.

Verification: `go build ./... && go vet ./... && go test ./internal/... -count=1`.
Tests must cover each terminal status including cancellation, the empty-bullet
intent, and the D6 case that a passing run leaves its intent `in_progress`. State
in the summary which test asserts the D6 case. Exit status decides the outcome.
