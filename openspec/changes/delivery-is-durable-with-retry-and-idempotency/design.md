# Design — Delivery is durable, with retry and idempotency

## Ownership and merge order

One repository, `sergeant-v2`. Second of four bullets against R5. Depends on
`envelopes-are-typed-versioned-and-correlated` (merged), which gave envelopes
`ID` and `CorrelationID` — this bullet's `deliveries.envelope_id` foreign key
would have nothing stable to reference otherwise.

## A delivery is a row, not a function call

A new table, `deliveries`:

- `id` — primary key, generated the same way other record IDs in this store
  are (`<scope>-<unix-nano>`).
- `envelope_id` — the envelope this delivery carries. References
  `envelopes.id`.
- `consumer` — who this delivery is for. For `SaveEnvelope`, the repo whose
  handoff directory receives the file. For `InjectHandoffToWorktree`, the
  downstream worktree path. A string, not an enum — new consumer kinds must
  not require a schema change.
- `state` — one of `pending`, `leased`, `delivered`, `acknowledged`,
  `retrying`, `failed`, `dead_letter`. Exactly R5.4's list.
- `attempt` — 1-based count of delivery attempts made so far.
- `next_attempt_at` — when a `retrying` delivery may be attempted again. Unset
  for terminal states.
- `error` — the classified failure reason of the most recent failed attempt.
  Empty when the delivery has not failed.
- `idempotency_key` — `envelope_id + ":" + consumer`. Unique. This is what
  makes a second delivery attempt for the same envelope/consumer pair
  idempotent rather than a duplicate fact.
- `created_at`, `updated_at`.

## Append-only history, not an updated row

R5.3 requires an append-only delivery history. A single row updated in place
loses the fact that a delivery was ever `retrying` once it becomes `delivered`
— exactly the information an operator needs to answer "did this take three
tries?" `RecordDeliveryAttempt` therefore inserts a new row per state
transition rather than updating one row's `state` column; all rows sharing an
`idempotency_key` are that delivery's history, ordered by `created_at`. The
current state is the latest row for a given `idempotency_key`.

## Idempotency: the key, not the caller, decides

`idempotency_key = envelope_id + ":" + consumer` is derived, not supplied by
the caller, for the same reason bullet 1 derived `correlation_id` from the run
id rather than inventing a second identifier: a fresh key kept in step with
(envelope, consumer) by convention would eventually disagree with it. Before
attempting a delivery, the store checks whether any row for this key has
already reached `delivered` (or later, `acknowledged`); if so, the attempt is
skipped and the existing terminal row is returned. A delivery that already
succeeded is not retried into a duplicate.

## Bounded retry

A fixed retry ceiling (3 attempts, an independent constant — not a call into
`config.Defaults`/`config.Repo`'s per-project R2.4 retry resolution, which is
YAML-configurable and could diverge from this number for a given project)
governs both call sites. On failure below the ceiling, the delivery
transitions to `retrying` with `next_attempt_at` set and the wrapping call
retries immediately in-process (both current call sites are synchronous,
in-memory file operations with no external backoff clock to wait on; "bounded
retry with observable backoff" here means the attempt count and timestamps are
recorded and inspectable, not that the engine sleeps between them — sleeping
would block the phase pipeline for a locally-fast file write that is
overwhelmingly likely to succeed on the next attempt or not at all). On
failure at the ceiling, the delivery transitions to `failed`.

## The wrapping call sites

`runner.RunAgentPhase`'s `_ = pr.Router.SaveEnvelope(&env)` becomes a call to a
new `Store.DeliverEnvelope(envelopeID, consumer, attemptFn func() error)`
helper: it resolves the idempotency key, skips if already delivered, otherwise
runs `attemptFn` (which calls `Router.SaveEnvelope`) up to the retry ceiling,
recording each attempt's outcome. `RunAgentPhase` already generates an
envelope id for the very same event two lines later
(`fmt.Sprintf("%s-%s-%d", pr.RepoName, phaseName, now.UnixNano())`, passed to
`Store.RecordEnvelope`); that id generation moves earlier so the same id is
used for both the delivery record and the envelope record, rather than
inventing a second id for one event.

`dag.Engine`'s `InjectHandoffToWorktree` call site is a different shape: the
`handoff.Envelope` (file-based, no `ID` field) that `SaveEnvelope` writes is
not the same object as the `store.EnvelopeRecord` this bullet's
`deliveries.envelope_id` references. `RunStage` has `runID` in scope, so it
resolves the envelope id with `e.Store.GetLatestEnvelope(runID, upstream)` —
the lookup bullet 1 added and left unused. When no envelope exists yet for
that upstream repo (the first phase of a stage, before anything has been
recorded), `InjectHandoffToWorktree` is called directly, undelivery-tracked,
exactly as today — there is nothing yet to key a delivery record on, and
`InjectHandoffToWorktree` already no-ops when the upstream has produced
nothing (a missing `srcDir` returns nil). `consumer` is the downstream
worktree path.

Both call sites already run inside a function that returns an error the phase
pipeline observes (`RunAgentPhase` returns `error`; the DAG engine's phase
execution does too), so a `failed` delivery after the retry ceiling is
returned as an error rather than discarded — closing the exact silent-failure
gap the proposal describes, not just adding a table beside the same discarded
error.

## Rejected alternatives

**A generic outbox/queue with a background dispatcher.** Both current delivery
call sites are synchronous, local, and already inside a retryable call path; a
background dispatcher polling for `pending` rows adds a second execution model
for work that already runs at the right time, and reintroduces the "did the
dispatcher actually run" question this bullet exists to close.

**Storing delivery state as columns on `envelopes` instead of a new table.**
Bullet 1 added envelope metadata as columns on the existing table because an
envelope has exactly one of each field. A delivery is not 1:1 with an
envelope — the same envelope can have multiple consumers (a fan-out DAG node
delivers to more than one downstream repo) — so delivery is a separate table
keyed by (envelope, consumer), the same reasoning bullet 1 used to reject a
separate `envelope_metadata` table in the other direction.

**Updating one delivery row's state in place.** Loses the attempt history
R5.3 requires; see "Append-only history" above.

## Migration

A new table, created alongside the existing `PRAGMA`-guarded `migrateAddColumns`
pattern's table-creation path (the same one `createChangesTable` and friends
use). No existing table changes shape, so no additive-column migration is
needed for this bullet.
