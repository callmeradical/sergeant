# Envelope schema

## ADDED Requirements

### Requirement: An envelope declares its type and schema version

Every published envelope SHALL carry a type and a schema version. Requirement
R5.1 requires envelopes to be typed and versioned; today a consumer must read the
payload to learn what it received.

#### Scenario: Publication without a type is refused

- **WHEN** an envelope is published with no type
- **THEN** publication fails with an error and no record is written

A transport that stores malformed input has moved the failure somewhere harder to
find.

#### Scenario: Publication without a schema version is refused

- **WHEN** an envelope is published with no schema version
- **THEN** publication fails with an error and no record is written

#### Scenario: A published envelope reports its type and version

- **WHEN** an envelope is published with a type and schema version
- **THEN** reading it back returns both unchanged

### Requirement: An envelope records when it happened and when it was published

Occurrence and publication SHALL be recorded separately.

#### Scenario: Both timestamps are retained

- **WHEN** an envelope occurring at one time is published at a later time
- **THEN** reading it back returns both times distinctly

Collapsing them hides delay, which is the property a transport is judged on.

### Requirement: Envelopes carry a stable correlation chain

Every envelope SHALL carry a correlation id stable across the run it belongs to,
and a causation id where it follows another envelope. R5.2 requires consumers to
reconstruct causation and ordering without parsing prose, filenames or worker
output.

#### Scenario: Every envelope of a run shares one correlation id

- **WHEN** several envelopes are published during one run
- **THEN** all of them carry the same correlation id

#### Scenario: A following envelope names its cause

- **WHEN** an envelope is published as a consequence of an earlier one
- **THEN** its causation id is the earlier envelope's id

#### Scenario: The first envelope of a run has no causation id

- **WHEN** the first envelope of a run is published
- **THEN** its causation id is absent

Absent must be distinguishable from empty: nothing caused it, as opposed to
something caused it and was not recorded.

#### Scenario: Publication without a correlation id is refused

- **WHEN** an envelope is published with no correlation id
- **THEN** publication fails with an error and no record is written

#### Scenario: An envelope names its producer

- **WHEN** an envelope is published
- **THEN** it records what produced it

### Requirement: A published envelope is immutable

Publication SHALL be final.

#### Scenario: Republishing an existing id is refused

- **WHEN** an envelope is published with an id that already exists
- **THEN** publication fails and the stored record is unchanged

R5.1 requires immutability after publication, and nothing currently enforces it.

### Requirement: Envelopes written before this change remain readable

The migration SHALL be additive and SHALL NOT invalidate existing records.

#### Scenario: An older envelope reads back without a type

- **WHEN** an envelope written before this change is read
- **THEN** it is returned with an empty type and does not error

Backfilling a type would invent one. An envelope that never declared a type has
none, and that is the truth about it.
