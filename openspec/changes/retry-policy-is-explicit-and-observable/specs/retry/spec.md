# Retry

## ADDED Requirements

### Requirement: Agent phase retry is configured, not hardcoded

A project SHALL be able to declare how many times an agent phase is retried, and
the engine SHALL use that value. Requirement R2.4 asks for a retry policy that is
explicit and observable; a parameter every caller passes as zero is neither.

#### Scenario: A configured retry count reaches the phase

- **WHEN** a project declares a retry count and an agent phase is executed
- **THEN** the phase is executed with that retry count

Fails today: `internal/dag/engine.go` passes the literal `0` at its only call
site, so no configured value can reach the phase.

#### Scenario: A repository overrides the project default

- **WHEN** a repository declares its own retry count
- **THEN** that value is used for phases in that repository, in preference to the
  project default

#### Scenario: An unset retry count means one attempt

- **WHEN** neither the repository nor the project declares a retry count
- **THEN** the agent phase is attempted once and not retried

Every existing project configuration omits the field, so the absent case must
preserve today's behaviour exactly.

#### Scenario: A failing agent phase is retried up to the configured count

- **WHEN** an agent phase fails and a retry count of two is configured
- **THEN** the phase is attempted no more than three times in total

#### Scenario: A phase that succeeds is not retried

- **WHEN** an agent phase succeeds on its first attempt
- **THEN** no further attempt is made

### Requirement: Deterministic gates are never retried

A failed deterministic gate SHALL NOT be retried. A gate's exit status is the
evidence a run is judged on, so re-running it to obtain a different answer would
contradict R2.5 and R2.6.

#### Scenario: A failing gate runs once regardless of the retry policy

- **WHEN** a deterministic gate fails and a non-zero retry count is configured
- **THEN** the gate is executed exactly once

### Requirement: Every attempt is recorded separately

Each attempt SHALL produce its own phase record carrying its attempt number, so
the sequence is readable from the run record rather than inferred.

#### Scenario: A phase that passes on retry keeps the failure alongside the pass

- **WHEN** an agent phase fails once and then succeeds
- **THEN** the run holds a failed record and a passed record for that phase, and
  their attempt numbers differ

Collapsing them would hide that a retry happened, which is precisely the
observability this requirement asks for. It would also breach the standing rule
against recording a value the stored state does not support.

#### Scenario: The attempt number starts at one and increases by one

- **WHEN** a phase is attempted repeatedly
- **THEN** the recorded attempt numbers are 1, 2, 3 in order with no gaps
