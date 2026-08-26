# Dispatch admission control and hard stop

## ADDED Requirements

### Requirement: Dispatch checks a machine-wide live-worker census before spawning a pane

A dispatch call SHALL count every verified-live worker pane across every
task and repo under `$FLEET_DIR` — every coordinator instance sharing that
fleet directory, not just workers this invocation's own coordinator
dispatched — before creating any new worker pane.

#### Scenario: A second, independent coordinator's live workers count toward the same budget

- **WHEN** coordinator A has already dispatched workers that, combined
  with coordinator B's new dispatch, would exceed the effective budget
- **THEN** coordinator B's dispatch is queued rather than spawning a pane,
  even though coordinator B's own dispatch history alone would not exceed
  the budget

#### Scenario: A stale status record with a dead pane does not count as live

- **WHEN** a fleet record's `status` file reads `in_progress` but the
  recorded pane no longer verifies live via the existing pane-identity
  check
- **THEN** that record is not counted toward the live-worker census

### Requirement: The effective worker budget scales with machine specs and current load/memory

The nominal worker-count ceiling SHALL be derived from detected CPU count
rather than a fixed constant across every machine, and SHALL be reduced
further when load average or available memory indicate the machine is
already under pressure.

#### Scenario: A busier machine admits fewer workers than an idle one at the same nominal ceiling

- **WHEN** two machines share the same detected CPU count but one has a
  significantly higher load average at the moment of dispatch
- **THEN** the busier machine's effective budget is lower than the idle
  machine's

### Requirement: A dispatch exceeding the effective budget queues durably instead of failing or spawning

A dispatch call that would exceed the effective budget SHALL be recorded as
a durable, tracked task rather than spawning a pane or returning a failure
to the caller, with no change to the caller-facing invocation shape.

#### Scenario: A queued dispatch is a real tracked task immediately

- **WHEN** a dispatch call is queued because the effective budget is
  exceeded
- **THEN** the call still returns a task ID, and that task ID is
  immediately visible to `sgt-watch`/`sgt-td-list`

#### Scenario: A queued task waits indefinitely, not until a timeout

- **WHEN** a queued task has not yet been promoted
- **THEN** it remains queued with no automatic expiry or failure purely
  from elapsed time

#### Scenario: Capacity freeing up promotes the queue automatically

- **WHEN** a live worker finishes, is cleaned up, or is force-stopped,
  freeing capacity under the effective budget
- **THEN** the next queued task is promoted to a real worker pane without
  any new caller action

#### Scenario: An operator can reorder the queue directly

- **WHEN** an operator wants a specific queued task promoted ahead of
  others
- **THEN** a command exists to change that task's position in the queue,
  and the next promotion honors the new order

### Requirement: Queued state is distinguishable from every other non-terminal state

Status and list output SHALL report a queued task as `queued`, distinct
from every other non-terminal state (`in_progress`, `needs_input`,
`blocked`, `waiting`, `orphaned`).

#### Scenario: A queued task is never reported as a hung preflight

- **WHEN** an operator inspects a queued task's status
- **THEN** the reported state is `queued`, not indistinguishable from an
  in-progress dispatch that has not yet produced a pane

### Requirement: A single command stops every live worker without requiring an active drain

A command SHALL exist that signals every live worker pane to terminate,
usable with no precondition of an already-active drain.

#### Scenario: Hard-stop works with no drain active

- **WHEN** no drain is active, globally or for any project
- **THEN** the hard-stop command still signals every live worker

#### Scenario: The default tier gives a worker a last chance before escalating

- **WHEN** hard-stop is invoked without `--force`
- **THEN** each live worker is given an opportunity to have its
  last-known state captured via the existing durable-handoff mechanism
  before receiving a termination signal, and is only escalated to an
  unconditional kill after a short bounded grace period

#### Scenario: `--force` skips the grace period and handoff attempt entirely

- **WHEN** hard-stop is invoked with `--force`
- **THEN** every live worker receives an immediate, unconditional stop with
  no handoff-capture attempt and no grace-period wait
