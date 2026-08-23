# Startup reconciliation

## ADDED Requirements

### Requirement: A restarted coordinator reconciles runs it is not driving

On startup, before serving requests, the coordinator SHALL move every run marked
`running` to `interrupted`. A freshly started process drives no runs, so any run
the store reports as running is unowned.

#### Scenario: A run left running by a crash is reconciled

- **WHEN** the store holds a run marked `running` and the coordinator starts
- **THEN** that run's status becomes `interrupted`

Fails today: the run stays `running` indefinitely, and resume refuses it because
it cannot tell an orphan from a live run.

#### Scenario: Terminal runs are untouched

- **WHEN** the store holds runs marked `passed`, `failed` and `cancelled` and the
  coordinator starts
- **THEN** each keeps the status it had

#### Scenario: Reconciliation happens before requests are served

- **WHEN** the coordinator starts
- **THEN** no request observes a run still marked `running` from a previous
  process

Otherwise a client can act on a status the coordinator already knows is stale,
including a resume refused for a reason that stops being true a moment later.

#### Scenario: A run started by this process is never reconciled

- **WHEN** a run is dispatched and is executing
- **THEN** its status remains `running`

Reconciliation is sound only at startup. Applied mid-life it would reconcile a
live run out from under itself.

### Requirement: An interrupted run is resumable and is not a failure

`interrupted` SHALL be a resumable status and SHALL NOT be reported as a failure.

#### Scenario: An interrupted run can be resumed

- **WHEN** a resume is requested for an interrupted run
- **THEN** it is accepted

#### Scenario: An interrupted run is not counted as failed

- **WHEN** a run is interrupted
- **THEN** it is not reported as a failed run

Nothing judged the work. A gate did not fail, the coordinator stopped. Recording a
failure would assert a verdict no gate produced.

#### Scenario: Interrupted is not a step toward delivery

- **WHEN** the bullet progression is listed
- **THEN** it does not contain `interrupted`

An interruption is the absence of progress, not a stage of it.

### Requirement: Phases are reconciled with their run

A phase left `running` by the same interruption SHALL be reconciled alongside its
run.

#### Scenario: A phase left running is reconciled

- **WHEN** a run is reconciled and one of its phases is marked `running`
- **THEN** that phase is no longer marked `running`

A run reported interrupted while a phase still claims to be running contradicts
itself.

#### Scenario: A reconciled phase is not skipped by resume

- **WHEN** an interrupted run with a reconciled phase is resumed
- **THEN** that phase is executed again

Resume skips only phases holding a passed record. A phase stuck at `running` is
neither passed nor re-run, so leaving it would silently drop work.

### Requirement: Recovery is reported, not silent

Reconciliation SHALL be recorded where an operator can see it.

#### Scenario: Reconciling a run is observable

- **WHEN** runs are reconciled at startup
- **THEN** the count is logged and the transition appears in the change sequence

A coordinator that quietly rewrites statuses at boot is indistinguishable from one
losing data.

#### Scenario: Reconciling nothing says nothing

- **WHEN** no run needs reconciliation
- **THEN** no recovery is reported

A permanent "0 runs recovered" line at every start is noise that trains an
operator to stop reading.
