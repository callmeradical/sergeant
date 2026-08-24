# Blocked bullets

## ADDED Requirements

### Requirement: A bullet whose run could not reach a passing result becomes blocked, with a reason, not failed

Decision D5(b) requires a human to be notified when a bullet is blocked on
a human decision. A bullet whose dispatched run concluded without passing
its gates SHALL become `blocked`, carrying a human-readable reason, rather
than `failed`.

#### Scenario: An agent-reported reason is recorded verbatim

- **WHEN** a run concludes without passing its gates and the agent's own
  envelope named why it could not proceed
- **THEN** the bullet becomes `blocked` and carries that reason

#### Scenario: No agent-reported reason still produces a blocked bullet with a synthesized reason

- **WHEN** a run concludes without passing its gates and no envelope named
  a reason
- **THEN** the bullet becomes `blocked` and carries a non-empty synthesized
  reason — a human is never left with `blocked` and no explanation at all

#### Scenario: A passing run is unaffected

- **WHEN** a run concludes having passed its gates
- **THEN** the bullet becomes `green`, exactly as before this change

#### Scenario: A cancelled run moves nothing

- **WHEN** a run is cancelled
- **THEN** no bullet status changes, exactly as before this change

### Requirement: A blocked bullet's reason is redacted like any other retained free text

Decision R4.4 requires that retained text not carry credentials, tokens, or
other secrets forward into a durable record.

#### Scenario: A secret-shaped reason is redacted before it is retained

- **WHEN** an agent-reported blocked reason contains a secret-shaped
  substring
- **THEN** the retained reason has that substring replaced with the
  project's standard redaction placeholder, not the original value
