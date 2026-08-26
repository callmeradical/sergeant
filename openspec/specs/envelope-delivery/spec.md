# envelope-delivery Specification

## Purpose
Make envelope delivery durable and safe to retry: every attempt is recorded
before it happens and every state transition is appended rather than
overwritten, retry is bounded with an explicit failure past the bound, and
redelivery to the same consumer resolves to a derived idempotency key so it
can never duplicate an authoritative result.
## Requirements
### Requirement: A delivery attempt is durably recorded before the attempt is made

Every delivery of an envelope to a consumer SHALL be recorded as a `pending`
row before the attempt is made, and every state transition SHALL be appended
as a new row rather than overwriting the prior one. Requirement R5.3 requires
publication to be durably persisted with an append-only delivery history, and
requires that process exit, restart, or a disconnected consumer not lose an
accepted envelope.

#### Scenario: A delivery exists before its outcome is known

- **WHEN** a delivery to a consumer begins
- **THEN** a `pending` row is recorded for it before the underlying write is
  attempted

#### Scenario: A delivery's history is retained, not overwritten

- **WHEN** a delivery transitions from `pending` to `retrying` to `delivered`
- **THEN** all three states are readable afterwards as separate history
  entries for that delivery, in order

An updated-in-place row would answer "did this take three tries?" with only the
last try.

### Requirement: A delivery has explicit state, attempt count, and consumer identity

Every delivery SHALL carry one of `pending`, `leased`, `delivered`,
`acknowledged`, `retrying`, `failed`, or `dead_letter`, an attempt count, and
the identity of the consumer it is for. Requirement R5.4 names this state set
and this metadata.

#### Scenario: A delivered envelope's consumer is recorded

- **WHEN** an envelope is delivered to a consumer
- **THEN** reading the delivery back reports that consumer's identity

#### Scenario: Attempt count increases with each retry

- **WHEN** a delivery fails once and is retried
- **THEN** the retried attempt's record reports attempt number 2

### Requirement: Retry is bounded and a failure past the bound is explicit

A delivery SHALL retry on failure up to a fixed bound, transitioning to
`retrying` with each failed attempt below the bound and to `failed` once the
bound is reached. Requirement R5.4 requires bounded retry.

#### Scenario: A failing delivery retries up to the bound

- **WHEN** every attempt to deliver an envelope fails
- **THEN** the delivery is attempted up to the bound and no further

#### Scenario: Retry exhaustion is a failure, not a silent stop

- **WHEN** a delivery has failed on every attempt up to the bound
- **THEN** its final state is `failed`, not `pending` or `retrying`, and the
  call site that requested delivery receives an error

The two current call sites — `SaveEnvelope` and `InjectHandoffToWorktree` —
discard their error today. A failure that stops retrying and returns nothing
is the same silent gap with an extra table beside it.

### Requirement: Redelivery to the same consumer cannot duplicate an authoritative result

Each delivery SHALL carry an idempotency key derived from its envelope and
consumer, and a delivery attempt for a key that has already reached a terminal
success state SHALL be a no-op that returns the existing record rather than
attempting the write again. Requirement R5.4 requires that redelivery cannot
create duplicate authoritative phase results, approvals, or commits.

#### Scenario: A second delivery attempt after success is a no-op

- **WHEN** a delivery for an envelope/consumer pair has already reached
  `delivered`
- **THEN** a second delivery attempt for the same envelope and consumer
  performs no write and returns the existing `delivered` record

#### Scenario: The idempotency key is derived, not caller-supplied

- **WHEN** two delivery attempts are made for the same envelope and the same
  consumer
- **THEN** they resolve to the same idempotency key without either caller
  passing one explicitly

A caller-supplied key can drift from the (envelope, consumer) pair it was meant
to describe; a derived key cannot.

