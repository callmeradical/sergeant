# Data retention

## ADDED Requirements

### Requirement: A project opts into data rotation with an explicit horizon

A project SHALL rotate no data unless it declares a `retention:` block
naming positive horizons; an absent block SHALL leave that project's data
untouched indefinitely, and a declared block with a zero or negative
horizon SHALL be rejected at load time rather than silently rotating
everything immediately.

#### Scenario: A project with no retention block never rotates

- **WHEN** a project's configuration declares no `retention:` block
- **THEN** no run, phase, envelope, delivery, or artifact belonging to
  that project is ever rotated, regardless of age

#### Scenario: A zero horizon is rejected, not silently accepted

- **WHEN** a project's configuration declares a `retention:` block with a
  horizon of zero or less
- **THEN** loading that project fails with an explicit error

### Requirement: Rotation preserves evidence for anything not yet settled

Rotation SHALL leave untouched any run that has not reached a terminal
status, and any run whose intent has a bullet that has not reached
`merged`, regardless of age.

#### Scenario: A non-terminal run is never rotated

- **WHEN** a run has not reached a terminal status
- **THEN** it is not rotated, even if it is older than its project's
  configured horizon

#### Scenario: A run with an unmerged bullet is never rotated

- **WHEN** a run's intent has at least one bullet that has not reached
  `merged`
- **THEN** that run is not rotated, even if it is older than its project's
  configured horizon

### Requirement: Rotated history is aggregated before it is deleted, not simply lost

Before a run's raw rows are deleted, its contribution to the project's
aggregate counts SHALL be folded into a durable rollup, so historical
totals remain accurate after the detailed rows are gone.

#### Scenario: Aggregate totals are unchanged by rotation

- **WHEN** a run eligible for rotation is rotated
- **THEN** the project's aggregate run/outcome/work-type/provenance totals
  after rotation equal what they were immediately before rotation

### Requirement: Artifacts rotate on their own horizon, independent of their parent run

Captured artifacts SHALL be deleted once they pass their project's
artifact horizon, regardless of whether the run that produced them has
itself been rotated.

#### Scenario: An artifact past its own horizon is deleted before its parent run rotates

- **WHEN** an artifact is older than its project's artifact horizon but
  its parent run has not yet reached the run horizon
- **THEN** the artifact and its durable file are deleted while the parent
  run's rows remain

### Requirement: Rotation is observable

An operator SHALL be able to see, per project, when rotation last ran and
how many runs and artifacts it rotated, without inferring rotation
occurred only by noticing data is missing.

#### Scenario: A completed rotation pass is visible to an operator

- **WHEN** a rotation pass completes for a project with retention
  configured
- **THEN** the project's analytics response reports the pass's timestamp
  and how many runs and artifacts were rotated
