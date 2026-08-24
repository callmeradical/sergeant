# Tasks — A proposed plan awaits explicit approval

One repository, `sergeant-v2`, so one task.

## Task 1 — propose, list, approve, reject

Repository: `sergeant-v2`. Depends on: nothing. Read `internal/ui/server.go`'s
`handleDispatch`, `internal/store/store.go`'s `IntentRecord`/`BulletRecord`/
`ListBulletsForIntent`/`CreateIntent`/`CreateBullet`/`UpdateIntentStatus`
first — read them before writing new code so naming and error-handling
conventions match.

- Add `"proposed"` to `store.BulletStatuses()`, ordered before `"pending"`.
- Add `Store.ListIntentsByStatus(status string) ([]IntentRecord, error)`.
- In `handleDispatch`, add the no-explicit-`repos` branch exactly as
  design.md specifies: create a `proposed` intent and `proposed` bullets,
  respond 202, and return before any run/worktree/dispatch code runs.
- Extract `handleDispatch`'s existing run-creation-and-dispatch sequence
  (everything after target repos are resolved, for the explicit-repos case)
  into a shared internal function taking the values already available at
  that point. Both the explicit-repos path and the new approval endpoint
  must call this same function — no duplicated dispatch logic.
- Add `GET /api/plans`: lists intents with status `proposed`, each with its
  bullets.
- Extend `GET /api/bullets` to accept `intent_id` as an alternative to
  `run_id` (direct lookup, no run to resolve through).
- Add `POST /api/plans/{intent_id}/approve` and
  `POST /api/plans/{intent_id}/reject` exactly as design.md specifies,
  including their idempotency and refusal rules.
- Do not build decomposition inference, plan editing, push notifications,
  or a bullet-level rejected status. Do not change `pending -> red -> green
  -> sealed -> merged` or `failed` semantics.

Verification: `go build ./... && go vet ./... && go test ./internal/... -count=1`.
Tests must cover every scenario in `specs/plan-approval/spec.md`: a
no-repos dispatch creates a proposed plan and starts nothing (assert zero
run rows, zero worktree/branch creation — a recording wrapper or equivalent
seam, not just checking the HTTP response); an explicit-repos dispatch is
provably unaffected (same behavior as before this change, exercised as a
regression test); proposed plans are listable via `GET /api/plans` with
their bullets; approving starts the real dispatch sequence for a proposed
plan's repos; rejecting starts nothing and leaves the intent `abandoned`;
approving an already-approved intent and rejecting an already-rejected one
are each idempotent (no second run, no error); approving or rejecting an
intent in any other state is refused. Exit status decides the outcome.
