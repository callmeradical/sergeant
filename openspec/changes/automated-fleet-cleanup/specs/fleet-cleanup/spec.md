# Fleet cleanup

## ADDED Requirements

### Requirement: A terminal run's fleet worktree is automatically reclaimed after a fixed retention window

A run whose status has been terminal (`passed`, `failed`, `cancelled`, or
`interrupted`) for longer than seven days SHALL have its fleet worktree
reclaimed without any human action, on the same schedule the server
already runs on.

#### Scenario: An old terminal run's worktree is reclaimed automatically

- **WHEN** a run's status is terminal and its last update is older than
  the retention window
- **THEN** its fleet worktree is removed without any API call or human
  action

#### Scenario: A recently-terminal run is left alone

- **WHEN** a run's status is terminal but its last update is within the
  retention window
- **THEN** its fleet worktree is not reclaimed yet

### Requirement: Automatic reclaim never removes a running or dirty worktree

Automatic cleanup SHALL apply the same safety rules the existing manual
cleanup action already enforces, not a relaxed version of them.

#### Scenario: A running run is never reclaimed regardless of age

- **WHEN** a run's status is `running`
- **THEN** its fleet worktree is never removed by the automatic pass, no
  matter how old the run is

#### Scenario: A worktree with uncommitted changes is never reclaimed automatically

- **WHEN** an otherwise-eligible run's fleet worktree contains uncommitted
  changes
- **THEN** the automatic pass does not remove it, the same way the manual
  action refuses without an explicit force

### Requirement: Automatic reclaim does not touch durable records

Reclaiming a fleet worktree SHALL NOT delete or modify the run's database
row or any other durable record.

#### Scenario: A reclaimed run's database row survives

- **WHEN** a run's fleet worktree is automatically reclaimed
- **THEN** the run, its phases, and its envelopes remain exactly as
  durably recorded as before
