# Tasks — Dead letters are durable, with replay and quarantine

One repository, `sergeant-v2`, so one task. This is bullet 3 of 4 against R5;
bullet 4 merges after it.

## Task 1 — dead-letter on exhaustion, replay, and quarantine

Repository: `sergeant-v2`. Depends on: `delivery-is-durable-with-retry-and-idempotency`
(merged — this task edits `internal/store/delivery.go` directly, building on
`DeliverEnvelope`, `insertDeliveryRow`, `ListDeliveryHistory`, and the
`deliveryState*` constants already there, including `deliveryStateDeadLetter`,
which exists but nothing produces yet).

- Add `critical bool` as `DeliverEnvelope`'s fourth parameter:
  `DeliverEnvelope(envelopeID, consumer string, critical bool, attempt func() error) error`.
  Update every existing call site to pass `true`, preserving current
  behavior exactly:
  - Production: `internal/runner/runner.go`'s `RunAgentPhase` call, and
    `internal/dag/engine.go`'s `RunStage` call.
  - Tests: every `st.DeliverEnvelope(...)` call in
    `internal/store/delivery_test.go` (there are around a dozen).
- In `DeliverEnvelope`'s final branch (currently: on reaching
  `deliveryMaxAttempts`, insert a `deliveryStateFailed` row and return
  `lastErr`), replace the `failed` row with a `deliveryStateDeadLetter` row.
  Add a `recoveryInstructions(consumer string, attempts int, class string)
  string` helper that builds a generic sentence (consumer, attempt count,
  error class) and pass its result as the row's recovery instructions —
  extend `DeliveryRecord` and `insertDeliveryRow` with a
  `recovery_instructions` column/field the same way `error_class` was added
  (additive migration in `internal/store/store.go`'s `migrateAddColumns`,
  since the live store already has the `deliveries` table without it).
  Then: if `critical` is true, return `lastErr` as before; if `critical` is
  false, return `nil` — the row is still written either way.
- Add `Store.ReplayDelivery(envelopeID, consumer string, attempt func() error)
  error`: look up the latest row for `deliveryIdempotencyKey(envelopeID,
  consumer)`; if its state is not `dead_letter`, return an error naming the
  actual state and write nothing. Otherwise run the same insert-and-retry loop
  `DeliverEnvelope` uses (extract the shared loop into a private helper both
  functions call, rather than duplicating it) appending to the same history.
  A replay is always `critical=true` from the caller's point of view — it
  either resolves the dead letter or produces a fresh dead-letter row; there
  is no "replay but don't care if it fails again" case to support.
- Add `Store.QuarantineDelivery(envelopeID, consumer, reason string) error`:
  look up the latest row for the key; if its state is not `dead_letter`,
  return an error and write nothing. Otherwise insert a row with state
  `"quarantined"` (a new state value; add a `deliveryStateQuarantined`
  constant), `error` set to `reason`, `error_class` set to `"quarantined"`.
- `ReplayDelivery` must refuse when the latest state is `quarantined`,
  returning an error that names the quarantine, and must write nothing.
- Do not add a `Store.UnquarantineDelivery` or any reversal path. Do not add
  any CLI/UI/MCP surface. Do not add a background sweep. Do not change the
  retry ceiling, idempotency key derivation, or what the two wrapped
  functions (`SaveEnvelope`, `InjectHandoffToWorktree`) write.

Verification: `go build ./... && go vet ./... && go test ./internal/... -count=1`.
Tests must cover every scenario in
`openspec/changes/dead-letters-are-durable-with-replay-and-quarantine/specs/dead-lettering/spec.md`:
exhausted retries produce `dead_letter` not `failed`; a dead-letter row reports
its envelope, reason, and non-empty recovery instructions; prior attempt rows
survive dead-lettering; a critical dead letter returns an error to its caller;
a non-critical one returns nil but still writes the record; a dead letter can
be replayed to `delivered`; replaying a delivery whose latest state is not
`dead_letter` is refused with no write; replaying an already-resolved dead
letter is a no-op that does not call the wrapped function again; a dead letter
can be quarantined with a reason that reads back; quarantining a delivery
whose latest state is not `dead_letter` is refused with no write; a
quarantined delivery refuses replay. Exit status decides the outcome.
