# Proposal — Dead letters are durable, with replay and quarantine

## Repository

One repository: `sergeant-v2`.

## Requirements served

Bullet 3 of 4 against **R5 — notification/envelope transport**. Depends on bullet
2 (`delivery-is-durable-with-retry-and-idempotency`, merged), which gave every
delivery its state machine, attempt history, and idempotency key — this bullet
is what happens at the end of that chain when every attempt has failed. Covers:

- **R5.5** — permanent errors, exhausted retries, poison messages, and
  unavailable destinations move to a durable dead-letter record containing the
  original envelope, attempts, reason, and recovery instructions.
  Dead-lettering fails or blocks the dependent phase/run unless policy marks
  that notification non-critical; it never silently drops or reports success.
  Operators can inspect, replay, or quarantine a dead letter through an
  auditable action with the same idempotency guarantees.

Bullet 4 (CLI/UI/MCP operator surfaces, R5.6) depends on this one: it puts a
human-facing command in front of the replay/quarantine mechanism this bullet
builds, rather than building its own.

## Problem

`DeliverEnvelope` (bullet 2) already retries up to a bound and, when every
attempt fails, inserts a `failed` row and returns the error. That is where it
stops. `failed` is in the R5.4 state vocabulary alongside `dead_letter`, but
nothing in the merged code ever produces a `dead_letter` row, and there is no
way to inspect, replay, or quarantine a delivery that has exhausted its
retries — an operator's only recourse today is reading `error`/`error_class`
off the last row by hand and re-running whatever produced the envelope in the
first place, which is not idempotent and not audited.

Concretely, what is missing and what it costs:

- **No dead-letter record.** Exhausting retries produces the same shape of row
  (`failed`) as any other failure; nothing distinguishes "this needs a human"
  from "this attempt failed."
- **No recovery instructions.** `error`/`error_class` say what went wrong, not
  what to do about it.
- **No replay.** Re-running the original code path is not the same as
  replaying a specific dead-lettered delivery — it has no relationship to the
  original idempotency key, so it cannot honor bullet 2's guarantee that a
  redelivery for the same (envelope, consumer) pair cannot duplicate an
  authoritative result.
- **No quarantine.** There is no way to record "an operator looked at this and
  decided not to retry it," so a dead letter and an operator's considered
  decision about it look identical.

## Proposal

When `DeliverEnvelope`'s retry ceiling is reached, insert a `dead_letter` row
instead of (not in addition to) `failed` — `failed` was bullet 2's
placeholder for "retries exhausted," and R5.5 is what that state was always
supposed to mean, so this bullet corrects the terminal state, not adds a
second one beside it. The row carries the same `error`/`error_class` already
recorded, plus a derived, generic `recovery_instructions` string.

Add `Store.ReplayDelivery(envelopeID, consumer string, attempt func() error)
error`: permitted only when the latest row for that key is `dead_letter`,
records the replay as new history rows through the same insert-only mechanism
`DeliverEnvelope` uses (so a replay's own attempts are indistinguishable in
shape from an original delivery's, just later in the same history), and is
itself bound by the idempotency check — a dead letter that a concurrent replay
already resolved to `delivered` is not replayed twice.

Add `Store.QuarantineDelivery(envelopeID, consumer, reason string) error`:
permitted only when the latest row for that key is `dead_letter`, inserts a
`quarantined` marker row recording the operator-supplied reason. A quarantined
delivery is not `dead_letter` waiting for attention; it is a recorded decision
not to act on it. `ReplayDelivery` refuses a quarantined delivery — reversing
a quarantine is a second explicit decision, not an accidental retry.

`DeliverEnvelope`'s caller-visible contract for the "blocks the dependent
phase/run unless policy marks it non-critical" half of R5.5: a `critical`
parameter, defaulting to the behavior both current call sites already rely on
(an error from `DeliverEnvelope` propagates and fails the phase/run). When
`critical` is false, a dead-lettered delivery is recorded exactly the same way
but `DeliverEnvelope` returns `nil` instead of the error, so the caller's phase
proceeds — "never silently drops or reports success" is satisfied because the
dead-letter row exists and is inspectable; only the blocking behavior changes.
Neither current call site (`runner.RunAgentPhase`'s `SaveEnvelope`,
`dag.Engine.RunStage`'s `InjectHandoffToWorktree`) has ever been asked to be
non-critical, so both keep passing `critical=true` — the mechanism is real and
tested, not exercised by production traffic yet, the same honest-partial shape
bullet 2 used for `acknowledged`.

## Out of scope

- CLI/UI/MCP surfaces that let an operator actually invoke `ReplayDelivery` or
  `QuarantineDelivery` — bullet 4 (R5.6). This bullet makes the mechanism
  correct and callable; bullet 4 puts a command in front of it.
- Automatic dead-letter replay (a background sweep that retries dead letters
  on a schedule). R5.5 describes an operator-driven, auditable action, not an
  automatic one.
- A configurable per-envelope-type or per-project criticality policy. The
  `critical` parameter exists and is honored; nothing yet decides it
  dynamically from project configuration.
- Changing bullet 2's retry ceiling, idempotency key derivation, or the two
  wrapped call sites' write behavior.
