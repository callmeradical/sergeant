# dead-lettering Specification

## Purpose
Give exhausted-retry deliveries a durable, auditable landing instead of
disappearing as a bare `failed` row: a dead-letter record that blocks its
caller unless explicitly marked non-critical, can be replayed with the same
idempotency guarantee delivery itself has, and can be quarantined as a
recorded operator decision that refuses further replay.
## Requirements
### Requirement: Exhausted retries produce a durable dead-letter record

A delivery whose retries are exhausted SHALL move to a durable `dead_letter`
state containing the original envelope reference, its attempt history, the
failure reason, and recovery instructions — not a bare `failed` row.
Requirement R5.5 requires exhausted retries to move to a durable dead-letter
record with these contents.

#### Scenario: Exhausting retries produces a dead-letter row, not just failed

- **WHEN** every attempt to deliver an envelope fails up to the retry bound
- **THEN** the delivery's final state is `dead_letter`

#### Scenario: A dead-letter record names its envelope, reason, and recovery instructions

- **WHEN** a delivery is dead-lettered
- **THEN** reading it back reports the envelope it was for, the classified
  failure reason, and a non-empty recovery instruction

#### Scenario: A dead letter's attempt history is retained

- **WHEN** a delivery is dead-lettered after multiple attempts
- **THEN** every prior attempt's row is still readable in the delivery's
  history, not replaced by the dead-letter row

### Requirement: Dead-lettering blocks its dependent phase unless marked non-critical

A dead-lettered delivery SHALL cause its caller to receive an error, unless the
caller has explicitly marked the delivery non-critical, in which case the
caller receives no error but the dead-letter record still exists. Requirement
R5.5 requires dead-lettering to fail or block the dependent phase/run unless
policy marks the notification non-critical, and to never silently drop or
report success.

#### Scenario: A critical dead letter fails its caller

- **WHEN** a critical delivery is dead-lettered
- **THEN** the function that requested the delivery returns an error

#### Scenario: A non-critical dead letter does not fail its caller, but is still recorded

- **WHEN** a non-critical delivery is dead-lettered
- **THEN** the function that requested the delivery returns no error, and the
  dead-letter record still exists and is readable

A silently dropped notification and a non-critical dead letter must not look
the same from the store's point of view: the second one leaves a record: the
first would leave nothing.

### Requirement: A dead letter can be replayed with the same idempotency guarantee delivery has

An operator-driven replay of a dead-lettered delivery SHALL be permitted only
for a delivery currently in the `dead_letter` state, SHALL append to the same
delivery history, and SHALL be refused if the delivery has since reached a
terminal success state. Requirement R5.5 requires replay through an auditable
action with the same idempotency guarantees as delivery itself.

#### Scenario: A dead letter can be replayed

- **WHEN** a dead-lettered delivery is replayed and the replay succeeds
- **THEN** the delivery's latest state is `delivered`

#### Scenario: Replaying a delivery that is not dead-lettered is refused

- **WHEN** a replay is requested for a delivery whose latest state is not
  `dead_letter`
- **THEN** the replay is refused with an error and no new row is written

#### Scenario: A dead letter already resolved is not replayed twice

- **WHEN** a dead-lettered delivery has already been delivered by a prior
  replay
- **THEN** a second replay attempt performs no write and does not call the
  wrapped delivery function again

### Requirement: A dead letter can be quarantined as a recorded, auditable decision

An operator-driven quarantine of a dead-lettered delivery SHALL be permitted
only for a delivery currently in the `dead_letter` state, SHALL record the
operator's reason, and SHALL cause subsequent replay attempts to be refused.
Requirement R5.5 requires quarantine through an auditable action.

#### Scenario: A dead letter can be quarantined with a reason

- **WHEN** a dead-lettered delivery is quarantined with a reason
- **THEN** the delivery's latest state is `quarantined` and the reason is
  readable back

#### Scenario: Quarantining a delivery that is not dead-lettered is refused

- **WHEN** a quarantine is requested for a delivery whose latest state is not
  `dead_letter`
- **THEN** the quarantine is refused with an error and no new row is written

#### Scenario: A quarantined delivery refuses replay

- **WHEN** a replay is requested for a delivery whose latest state is
  `quarantined`
- **THEN** the replay is refused with an error naming the quarantine and no
  new row is written

