# Server dispatch/execution decomposition

## ADDED Requirements

### Requirement: The dispatch endpoint's externally-observable behavior is unchanged after extraction

`POST /api/dispatch`'s validation order, response shapes, and the records
it creates SHALL be identical before and after `handleDispatch` moves to
`internal/ui/dispatch.go`. A characterization test proving this SHALL exist
and pass against the code as it stands today, before any function moves.

#### Scenario: An invalid dispatch request is rejected the same way before and after

- **WHEN** `POST /api/dispatch` is sent a request missing a required field
  (matching an existing validation branch in `handleDispatch`)
- **THEN** the response status and body are identical whether tested
  against the pre-extraction or post-extraction code

#### Scenario: A valid dispatch creates the same records before and after

- **WHEN** `POST /api/dispatch` is sent a valid request
- **THEN** the created run, intent, and bullet records have the same
  fields populated, whether tested against the pre-extraction or
  post-extraction code

### Requirement: `executeRun`'s stage-execution behavior is unchanged after extraction, and is testable without a real git worktree or agent CLI

`executeRun` SHALL run each configured DAG stage in order and record a
terminal run status identically before and after extraction. After the
`stageRunner` seam is introduced, this SHALL be verifiable with a fake
stage runner, not only a real `*dag.Engine`.

#### Scenario: executeRun runs configured stages in order

- **WHEN** `executeRun` is given an engine and a project with more than one
  configured DAG stage
- **THEN** each stage is passed to `RunStage` in the project's configured
  order

#### Scenario: executeRun is testable with a fake stage runner

- **WHEN** a test constructs a fake implementing `stageRunner` that records
  which stages it was asked to run and returns without touching git or an
  agent CLI
- **THEN** `executeRun` runs to completion against that fake and the test
  can assert on which stages it recorded, with no real worktree or agent
  process created

### Requirement: A stage failure still produces the same terminal run status and blocked-reason behavior after extraction

`recordTerminalRun` and `blockedReasonForRun`'s mapping from a stage
failure to a run's terminal status and its recorded reason SHALL be
unchanged by the move.

#### Scenario: A failing stage's run reaches the same terminal status as before

- **WHEN** a configured stage's `RunStage` call returns an error
- **THEN** the run's terminal status and `blockedReasonForRun`'s returned
  reason are identical to what they were before this change
