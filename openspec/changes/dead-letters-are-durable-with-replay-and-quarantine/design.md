# Design — Dead letters are durable, with replay and quarantine

## Ownership and merge order

One repository, `sergeant-v2`. Third of four bullets against R5. Depends on
`delivery-is-durable-with-retry-and-idempotency` (merged), which built
`internal/store/delivery.go`: the `deliveries` table, `insertDeliveryRow`
(insert-only, one row per state transition), `DeliverEnvelope`,
`ListDeliveryHistory`, and the state constants including `deliveryStateFailed`
and `deliveryStateDeadLetter` (declared but, until this bullet, unused).

## `dead_letter` replaces `failed` as the exhaustion outcome, it does not join it

Read literally, R5.4 lists `failed` and `dead_letter` as two states in one
enum; R5.5 says exhausted retries move to a dead-letter record. Bullet 2 used
`failed` for exhaustion because dead-lettering did not exist yet — this bullet
is what `failed`'s exhaustion case was a placeholder for. `DeliverEnvelope`'s
final branch (currently: insert `failed`, return the error) becomes: insert
`dead_letter` with a derived `recovery_instructions` string, then either
return the error (`critical=true`) or `nil` (`critical=false`). `failed` stays
in the vocabulary and the constant stays defined — a future caller with a
genuinely non-retryable, non-dead-letter-worthy failure (none exists yet) has
somewhere to put it — but `DeliverEnvelope` itself no longer produces it.

## Recovery instructions are derived, not authored per call site

`recoveryInstructions(consumer string, attempts int, class string) string`
builds a generic, useful-enough sentence from data already available at the
point of dead-lettering: which consumer, how many attempts, what class of
error. Neither current call site (a file write, a directory copy) has a
call-site-specific remediation beyond "look at the error and decide whether to
replay or quarantine" — inventing more specific advice than the two failure
modes actually support would be guessing.

## Replay reuses `DeliverEnvelope`'s machinery, not a parallel path

`Store.ReplayDelivery(envelopeID, consumer string, attempt func() error)
error`:

1. Reads the latest row for the idempotency key. If it is not `dead_letter`,
   refuse — replaying a delivery that is `pending`, `retrying`, `delivered`,
   or `quarantined` is a different action (or none) than "resolve this dead
   letter."
2. Otherwise, runs the exact same insert-and-retry loop `DeliverEnvelope` uses
   for a fresh delivery, appending to the same history rather than starting a
   new idempotency key. A replay that fails again produces another
   `dead_letter` row; the history shows two dead-letter episodes, not one
   overwritten by the other.

The idempotency check that already guards `DeliverEnvelope` (skip if the
latest row is a terminal success) guards replay identically, because both
functions read the same "latest row" state — a dead letter that a concurrent
process already replayed to `delivered` is not replayed a second time.

## Quarantine is a recorded decision, not a fourth retry state

`Store.QuarantineDelivery(envelopeID, consumer, reason string) error`:
refuses unless the latest row is `dead_letter`, then inserts a `quarantined`
row carrying the operator's `reason` in the existing `error` column (repurposed
as "the recorded reason for this row," which is what it already means for
every other state) and `error_class = "quarantined"`. `ReplayDelivery` checks
for exactly this: if the latest row is `quarantined`, it refuses with an error
naming the row, so undoing a quarantine requires a second explicit call (not
built by this bullet — there is no `Store.Unquarantine`; nothing in the PRD
asks for one, and inventing a reversal path nobody requested is scope the
proposal does not need).

`quarantined` is a new value in the same `state` column, not a new table or a
boolean flag column. It goes through the identical insert-only, idempotency-
keyed history mechanism as every other state, so `ListDeliveryHistory` shows a
quarantine the same way it shows a delivery or a dead letter — one more row in
one history, not a parallel record type to keep in sync.

## The `critical` parameter

`DeliverEnvelope`'s signature gains a `critical bool` parameter. Both existing
call sites (`runner.go`, `dag/engine.go`) pass `true`, preserving exactly the
behavior bullet 2 shipped: a dead-lettered delivery still returns an error
that fails the phase/run. `critical=false` is real and tested — the row is
still recorded as `dead_letter`, `ListDeliveryHistory` still shows it — but
`DeliverEnvelope` returns `nil`, so the caller's phase proceeds. Nothing calls
it with `false` yet; that is honest, not hidden, per `proposal.md`'s
out-of-scope list.

## Rejected alternatives

**A separate `dead_letters` table.** A dead letter is the terminal state of
one delivery chain, not a new entity — it already has an idempotency key, an
envelope reference, and a full attempt history in `deliveries`. A second table
would need its own foreign key back to the delivery it resolves and would make
"is this delivery dead-lettered" a join instead of a `state` check, the same
reasoning bullet 1 used against a separate `envelope_metadata` table.

**A background sweep that auto-replays dead letters.** R5.5 describes an
operator-driven, auditable action. An automatic sweep would retry a permanent
failure (a poison message, a genuinely broken destination) on a timer
indefinitely, which is the opposite of what dead-lettering exists to stop.

**Modeling `quarantined` as a boolean column on the latest row instead of a
new state.** Every other piece of delivery state in this design is a fact
about a row, read by looking at the latest row for a key — a boolean bolted on
beside `state` would be a second place that fact can live, and the two could
disagree (a `quarantined=true` row whose `state` still reads `dead_letter`).
