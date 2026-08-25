# Server remaining-groups decomposition

## ADDED Requirements

### Requirement: Plan proposal, approval, and rejection behavior is unchanged after extraction

`handlePlans`/`handleApprovePlan`/`handleRejectPlan`/`handleValidateIntent`'s
response shapes and their effect on intent/bullet status SHALL be identical
before and after moving to `internal/ui/plans.go`.

#### Scenario: Approving a proposed plan has the same effect before and after

- **WHEN** a plan-approval request is sent for a proposed intent
- **THEN** the intent and its bullets reach the same status, and the
  response is the same, whether tested against the pre-extraction or
  post-extraction code

#### Scenario: Rejecting a proposed plan has the same effect before and after

- **WHEN** a plan-rejection request is sent for a proposed intent
- **THEN** the intent's status and the response are identical before and
  after extraction

### Requirement: Workflow discovery and DAG-save behavior is unchanged after extraction

`handleDiscoverWorkflow`/`handleSaveDAG`'s response shapes SHALL be
identical before and after moving to `internal/ui/workflow.go`.

#### Scenario: Discovering a workflow returns the same shape before and after

- **WHEN** a workflow-discovery request is sent for a configured project
- **THEN** the response is identical before and after extraction

### Requirement: Run cancel, resume, and delete behavior is unchanged after extraction

`handleRunCancel`/`handleRunDelete`/`handleRunResume`'s response shapes
and their effect on run status SHALL be identical before and after moving
to `internal/ui/run_lifecycle.go`.

#### Scenario: Cancelling a run has the same effect before and after

- **WHEN** a cancel request is sent for an active run
- **THEN** the run's status and the response are identical before and
  after extraction

#### Scenario: Resuming a resumable run has the same effect before and after

- **WHEN** a resume request is sent for a run in a resumable status
- **THEN** which phases are skipped and the response are identical before
  and after extraction

#### Scenario: Deleting a run has the same effect before and after

- **WHEN** a delete request is sent for a run
- **THEN** the run record's presence afterward and the response are
  identical before and after extraction
