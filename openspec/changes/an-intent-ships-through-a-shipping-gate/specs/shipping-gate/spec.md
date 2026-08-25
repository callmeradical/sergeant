# Shipping gate

## ADDED Requirements

### Requirement: A shipping gate evaluates an intent only once all its bullets are sealed or merged

The shipping gate SHALL NOT run, and an intent's shipping-gate status SHALL
remain unset, while any bullet of that intent has not yet reached sealed or
merged. Requirement D5(c) names "a bullet ready for an irreversible step";
this requirement is what makes that evidence trustworthy at the intent
level rather than per bullet.

#### Scenario: An intent with some bullets not yet sealed has no shipping-gate status

- **WHEN** an intent has bullets in a mix of pending, red, green, and sealed
  status
- **THEN** the intent's shipping-gate status is empty

#### Scenario: An intent with all bullets sealed evaluates its shipping gate

- **WHEN** the last bullet of an intent transitions to sealed and every
  other bullet of that intent is already sealed or merged
- **THEN** the intent's configured shipping gates run

### Requirement: A project with no configured shipping gates passes trivially

An intent whose project declares no shipping gates SHALL have its
shipping-gate status recorded as passed as soon as every bullet is sealed
or merged, with no command executed. This matches how a bullet's own
factory gates already default to none configured.

#### Scenario: No shipping gates configured records a pass with no command run

- **WHEN** every bullet of an intent reaches sealed or merged and the
  project declares no shipping gates
- **THEN** the intent's shipping-gate status is recorded as passed and no
  shell command is executed

### Requirement: A shipping-gate failure does not change any bullet's status

A shipping-gate failure SHALL be recorded only on the intent, never by
changing any bullet's status away from its own already-recorded sealed (or
merged) status. A bullet's sealed status is a fact about that bullet's own
passed gates and human approval; a shipping-gate failure is a separate fact
about the intent as a whole.

#### Scenario: A shipping-gate failure leaves every bullet sealed

- **WHEN** an intent's configured shipping gate fails after all of its
  bullets reached sealed
- **THEN** every one of those bullets remains sealed, unchanged

### Requirement: A shipping-gate failure is recorded with a human-readable reason

A shipping-gate failure SHALL be recorded with a reason identifying which
configured check failed, inspectable the same way a blocked bullet's
reason already is.

#### Scenario: A failed shipping gate records which check failed

- **WHEN** one of an intent's configured shipping-gate commands exits
  non-zero
- **THEN** the intent's shipping-gate status is recorded as failed with a
  reason naming that check

### Requirement: A shipping-gate pass is recorded distinctly from a failure and carries no reason

A shipping-gate pass SHALL be recorded as a distinct status from a failure,
and SHALL carry no reason, mirroring how `BulletRecord.BlockedReason` is
empty for any non-blocked status.

#### Scenario: A passing shipping gate records no reason

- **WHEN** every one of an intent's configured shipping-gate commands
  exits zero
- **THEN** the intent's shipping-gate status is recorded as passed and its
  shipping-gate reason is empty

### Requirement: Sergeant never merges as a result of a shipping gate

A shipping gate, passing or failing, SHALL NOT cause Sergeant to merge,
create, or otherwise act on any pull request. Decision D6 requires human
merge only, observing real PR state.

#### Scenario: A passing shipping gate triggers no merge action

- **WHEN** an intent's shipping gate passes
- **THEN** Sergeant takes no merge or PR-creation action as a result beyond
  recording the passed status
