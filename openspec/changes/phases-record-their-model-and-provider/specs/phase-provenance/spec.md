# Phase provenance

## ADDED Requirements

### Requirement: A phase record identifies the model and provider that actually executed it

Where an agent's own output names the model and provider it used, that fact
SHALL be recorded on the phase's payload as `model` and `provider`. Requirement
R4.6 requires attribution to what actually executed a phase, not only to what
was requested.

#### Scenario: A goose phase's model and provider are recorded

- **WHEN** a phase runs with the `goose` agent and goose's output names its
  provider and model
- **THEN** the phase's payload reports that provider and that model

#### Scenario: An unrecognised agent's provenance is absent, not invented

- **WHEN** a phase runs with an agent this project has no output parser for
- **THEN** the phase's payload has empty `model` and `provider` fields rather
  than a guessed or default value

#### Scenario: Provenance is recorded whether or not the agent wrote its own envelope

- **WHEN** a successful phase's envelope was written by the agent itself,
  not synthesized by sergeant
- **THEN** the phase's payload still reports `model` and `provider` when the
  agent's output made them knowable

An envelope's origin (agent-authored or sergeant-synthesized) must not decide
whether provenance is recorded — both are the same phase, and evidence from
its execution exists regardless of which side wrote the summary.

#### Scenario: A malformed or unrecognised agent output does not fail the phase

- **WHEN** an agent's output does not match the shape a provenance parser
  expects
- **THEN** the phase completes exactly as it would have without provenance
  parsing, with empty `model`/`provider` fields

Provenance is additive metadata; a parsing gap must never become a phase
failure.
