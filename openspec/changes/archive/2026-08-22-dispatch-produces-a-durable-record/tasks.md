# Tasks — A dispatch produces a durable, idempotent, observable record

One repository throughout: `sergeant-v2`. Each task is one bullet. Merge order is
task order; sergeant releases a bullet's PR only once its upstream bullets are
merged, so task 2 waits for task 1 and task 3 waits for task 1.

## Task 1 — a dispatch persists its intent and bullets

Repository: `sergeant-v2`. Depends on: nothing. Merge first.

- Add `intent_id` to `runs` via the existing additive migration pattern.
- Hoist the target-repository resolution above the record writes so the DAG path
  and the bullet writes share one list.
- In `handleDispatch`, after `resolveChange` and before `CreateRun`, write one
  `IntentRecord` (`<run-id>-intent`, status `in_progress`) and one `BulletRecord`
  per target repository (`<run-id>-b<position>`, position from list index).
- Assert a rejected `resolveChange` leaves no intent and no bullet behind.

Verification: `go test ./internal/ui/... ./internal/store/... -count=1` — a new
test dispatches against a temporary store and asserts one intent and N bullets
with distinct positions, and a second test asserts nothing is written when change
resolution fails. Exit status decides.

## Task 2 — a dispatch is idempotent under `request_id`

Repository: `sergeant-v2`. Depends on: task 1. Merge second.

- Add `request_id TEXT` to `runs` with a unique index, storing the absent case as
  `NULL` so absent keys never collide.
- Add `request_id` to the `handleDispatch` request struct.
- Insert first and handle the constraint violation; do not query then insert. On
  violation, load the existing run by key and return the ordinary dispatch
  response.
- Ensure the repeat path returns before any worktree, branch or agent is created.

Verification: `go test ./internal/ui/... -count=1` — a test issues two dispatches
with one `request_id`, asserts a single run row, asserts both responses carry the
same run id, and asserts the fleet directory holds exactly one worktree. A further
test issues two dispatches with no `request_id` and asserts two runs. Exit status
decides.

## Task 3 — clients follow a sequenced stream instead of polling

Repository: `sergeant-v2`. Depends on: task 1. Merge third.

- Add an append-only `changes` table with `seq INTEGER PRIMARY KEY AUTOINCREMENT`.
- Append a change row on every run, intent and bullet transition.
- Serve `GET /api/stream?from=<seq>` as SSE: replay above `from`, or answer with a
  snapshot plus current sequence when `from` is unknown or ahead.
- Replace the `setInterval(..., 2000)` in `internal/ui/static/index.html` with an
  `EventSource`, keeping the existing key-diff render path.
- Add MCP tools `sergeant_run_status` and `sergeant_run_wait`, both taking a run
  id and reading the same sequence the dashboard consumes. Neither may shell out
  to `bin/sgt-*` (D7). `sergeant_run_wait` takes a caller-supplied bound and, on
  exceeding it, reports the run as still executing rather than inventing a
  terminal status.

Verification: `go test ./internal/store/... ./internal/ui/... -count=1` — tests
assert sequence numbers strictly increase, that a subscription from N excludes N
and everything before it, and that an unknown `from` yields a snapshot rather than
an error. Then `go build ./... && go vet ./internal/... && go test ./internal/...
-count=1`, and a browser check asserting zero `/api/runs` requests in a sixty
second idle window. A test must assert that waiting on an already-terminal run
returns without delay, and that an exceeded bound reports the run as still
executing. Exit status decides.
