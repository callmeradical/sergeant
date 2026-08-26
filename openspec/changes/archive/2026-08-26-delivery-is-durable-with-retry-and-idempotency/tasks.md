# Tasks — Delivery is durable, with retry and idempotency

One repository, `sergeant-v2`, so one task. This is bullet 2 of 4 against R5;
bullets 3 and 4 merge after it.

## Task 1 — a delivery is a durable, retried, idempotent row

Repository: `sergeant-v2`. Depends on: `envelopes-are-typed-versioned-and-correlated`
(merged — gives envelopes the `ID` this bullet's `deliveries.envelope_id`
references).

- Add a `deliveries` table via the same `const create<X>Table` +
  `migrateAddTables` PRAGMA-guarded pattern already used for `intents`,
  `bullets`, and `changes` (see `internal/store/store.go`). Columns: `id`,
  `envelope_id`, `consumer`, `state`, `attempt`, `next_attempt_at`, `error`,
  `idempotency_key` (unique), `created_at`, `updated_at`.
- Add `Store.DeliverEnvelope(envelopeID, consumer string, attempt func() error)
  error`: computes `idempotency_key = envelopeID + ":" + consumer`; if a row
  for that key already reports `delivered` or `acknowledged`, returns nil
  without calling `attempt`; otherwise records a `pending` row, calls
  `attempt()`, and on error records `retrying` (incrementing the attempt
  count) and calls `attempt()` again up to 3 total attempts, then records
  `failed` and returns the final error; on success records `delivered` and
  returns nil. Every state transition is an INSERT, never an UPDATE to an
  existing row — the delivery's rows are its history.
- Add `Store.ListDeliveryHistory(envelopeID, consumer string)
  ([]DeliveryRecord, error)` returning all rows for one idempotency key,
  ordered by `created_at`, for tests and for bullet 4's future operator
  surface.
- Wire both current call sites through `DeliverEnvelope` instead of discarding
  their error:
  - `internal/runner/runner.go`: the envelope id currently generated two lines
    after `SaveEnvelope` (`fmt.Sprintf("%s-%s-%d", pr.RepoName, phaseName,
    now.UnixNano())`, passed to `Store.RecordEnvelope`) moves earlier so both
    calls use the same id. `_ = pr.Router.SaveEnvelope(&env)` becomes
    `if err := pr.Store.DeliverEnvelope(envelopeID, pr.RepoName, func() error
    { return pr.Router.SaveEnvelope(&env) }); err != nil { ... }` — surface the
    error the same way this function already surfaces other phase failures
    (it must not turn a working phase into a broken one; match the existing
    error-return convention in `RunAgentPhase`).
  - `internal/dag/engine.go`, inside `RunStage` (which has `runID` in scope):
    resolve the envelope id first with `e.Store.GetLatestEnvelope(runID,
    upstream)`. If that lookup errors (no envelope recorded yet for that
    upstream repo — the ordinary case for the first phase of a stage), call
    `e.Router.InjectHandoffToWorktree(upstream, worktreePath)` directly,
    exactly as today, with no delivery record — there is nothing yet to key
    one on. If an envelope id is found, wrap the call through
    `DeliverEnvelope` with `consumer` set to `worktreePath`, surfaced the same
    way this function already surfaces other DAG step failures.
- Do not change what `SaveEnvelope` or `InjectHandoffToWorktree` write, or the
  handoff file format. Do not implement dead-lettering, replay, quarantine, or
  any CLI/UI/MCP surface — those are bullets 3 and 4.

Verification: `go build ./... && go vet ./... && go test ./internal/... -count=1`.
Tests must cover: a pending row exists before an attempt resolves; a
successful delivery's history retains its `pending` row afterward; a delivery
that fails twice then succeeds shows attempt 1 (failed/retrying), attempt 2
(failed/retrying), attempt 3 (delivered) as three distinct history rows; a
delivery that fails on every attempt up to the bound ends `failed` and returns
an error to the caller; a second delivery attempt for an envelope/consumer
pair already at `delivered` performs no write (assert the wrapped function is
not called again) and returns the existing record. Exit status decides the
outcome.
