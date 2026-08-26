# Pipeline artifacts

## ADDED Requirements

### Requirement: A gate or phase command can capture files as durable evidence

A gate or agent phase command SHALL be given a scoped, empty directory via
`SERGEANT_ARTIFACT_DIR`; any file it writes there before exiting SHALL be
copied to a durable location outside the run's worktree and recorded
against that run and phase, surviving that worktree's later reclaim by
`automated-fleet-cleanup`.

#### Scenario: A file written to the artifact directory is captured durably

- **WHEN** a gate command writes a file to `$SERGEANT_ARTIFACT_DIR` and
  exits
- **THEN** a durable copy of that file exists outside the run's worktree,
  and a record naming its run, phase, filename, content type, and size is
  readable back

#### Scenario: A command that writes nothing produces no artifacts

- **WHEN** a gate command exits without writing to
  `$SERGEANT_ARTIFACT_DIR`
- **THEN** no artifact record is created for that phase

#### Scenario: A captured artifact outlives its worktree

- **WHEN** a run's worktree is reclaimed by `automated-fleet-cleanup` after
  the run reaches a terminal state
- **THEN** every artifact captured during that run remains readable at its
  durable path, unaffected by the worktree's removal

### Requirement: Capture is bounded and never fails the phase that produced it

Capture SHALL be limited to a fixed maximum file count and total byte size
per phase, with anything beyond the bound explicitly recorded as dropped
rather than silently omitted. A capture failure of any kind SHALL NOT
change the outcome of the gate or phase that produced the artifacts.

#### Scenario: Exceeding the artifact cap is recorded, not silently dropped

- **WHEN** a gate command writes more files (or more total bytes) than the
  configured maximum
- **THEN** the allowed artifacts are captured normally, and one additional
  record reports how many were dropped and why

#### Scenario: A failing gate's artifacts are still captured

- **WHEN** a gate command writes a file to `$SERGEANT_ARTIFACT_DIR` and
  then exits with a failing status
- **THEN** the file is still captured as a durable artifact

#### Scenario: A capture failure does not change the gate's own result

- **WHEN** the durable artifact destination is unwritable and a gate
  command that would otherwise pass writes a file to
  `$SERGEANT_ARTIFACT_DIR`
- **THEN** the gate's own recorded status is unaffected by the capture
  failure

### Requirement: A run's captured artifacts are visible in the dashboard

The dashboard's run detail view SHALL show a run's captured artifacts,
grouped by the phase that produced them, directly beneath the existing
pipeline/gates/delivery workflow graph — present only when the run has at
least one.

#### Scenario: A run with captured artifacts shows them beneath its workflow graph

- **WHEN** a run has at least one captured artifact
- **THEN** the run's detail view renders an artifacts section beneath its
  workflow graph, grouped by the phase that produced each artifact

#### Scenario: A run with no artifacts shows no artifacts section

- **WHEN** a run has no captured artifacts
- **THEN** the run's detail view renders no artifacts section at all
