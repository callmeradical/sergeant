# resume Specification

## Purpose
TBD - created by archiving change resume-is-reachable-from-the-dashboard. Update Purpose after archive.

## Requirements

### Requirement: A resumable run offers resume in the dashboard

The dashboard SHALL offer a resume control for a run the server will accept for
resume, and SHALL NOT offer it otherwise. `POST /api/run-resume` already exists and
already refuses the wrong statuses; the interface must not invite an action the
server rejects.

#### Scenario: A failed run offers resume

- **WHEN** a run whose status is `failed` is opened in the run detail drawer
- **THEN** a resume control is present and enabled

Fails today: no part of the dashboard references `/api/run-resume`.

#### Scenario: A passed run does not offer resume

- **WHEN** a run whose status is `passed` is opened in the run detail drawer
- **THEN** no resume control is present

Re-running earned work can only lose it, and the server refuses this case.

#### Scenario: A running run does not offer resume

- **WHEN** a run whose status is `running` is opened in the run detail drawer
- **THEN** no resume control is present

Resuming a live run would put two agents in one worktree.

#### Scenario: The condition comes from the server, not a second list in the client

- **WHEN** the run payload served to the dashboard is inspected
- **THEN** it carries a field stating whether that run may be resumed

A list of resumable statuses maintained in JavaScript would be a second authority
for a rule the server enforces, and the two would drift.

### Requirement: Resuming from the dashboard reports what it will skip

The control SHALL show which phases a resume will skip before the operator commits.

#### Scenario: Phases already passed are named before resuming

- **WHEN** an operator opens the resume control on a run holding passed phases
- **THEN** those phase names are shown

A resume that silently skipped four gates would leave the operator unable to tell
whether those gates ever ran.

#### Scenario: Resuming moves the run back to running without a new request

- **WHEN** a resume is confirmed from the dashboard
- **THEN** the run's status becomes `running` in the interface without the page
  issuing a further poll for it

The change stream published in the previous change already carries run
transitions, so this consumer needs no request of its own. A resume that worked
only because the page re-read everything would reintroduce the polling that change
removed.

#### Scenario: A refused resume reports the server's reason

- **WHEN** a resume is refused by the server
- **THEN** the interface shows the reason the server gave

Never display a value not derived from stored state: the interface must not invent
an explanation for a refusal it did not decide.
