# Observed change-request merge state

## ADDED Requirements

### Requirement: A run records the branch its worktree actually branched from

A run's worktree creation SHALL capture and durably record the branch the
source repository was actually checked out on at that moment, once, and
SHALL NOT overwrite that recorded value on a later resume of the same run.

#### Scenario: A run's first worktree creation records its real base branch

- **WHEN** a run's worktree is created for the first time
- **THEN** the branch the source repository was checked out on at that
  moment is durably recorded against the run

#### Scenario: Resuming a run does not overwrite its recorded base branch

- **WHEN** a run whose worktree was removed but whose branch survived is
  resumed, and the source repository's checked-out branch has since
  changed
- **THEN** the run's recorded base branch is unchanged from what its first
  attempt recorded

### Requirement: The provider that opens and observes a change request is detected from the repository's remote, not configured

Sealing a bullet SHALL determine which host implementation to use by
parsing the repository's own git remote URL. A remote resolving to a
recognized, implemented provider SHALL use it automatically. A remote
resolving to an unrecognized or unimplemented provider SHALL be refused
clearly, naming the detected host, rather than silently attempted or
silently skipped.

#### Scenario: A GitHub remote uses the GitHub provider automatically

- **WHEN** a repository's remote resolves to `github.com` (either SSH or
  HTTPS form)
- **THEN** sealing that repository's bullet opens a change request through
  the GitHub provider, with no per-project configuration required

#### Scenario: An unrecognized remote is refused clearly

- **WHEN** a repository's remote resolves to a host with no registered
  provider
- **THEN** sealing is refused with an error naming the detected host, and
  no change request is fabricated

### Requirement: A sealed bullet's change request identity is durably recorded

Opening a change request for a sealed bullet SHALL persist that change
request's identity onto the bullet itself, not only into an envelope.

#### Scenario: A successfully opened change request is readable from the bullet afterward

- **WHEN** sealing a bullet successfully opens a change request
- **THEN** reading that bullet back reports the change request's URL

### Requirement: A change request opens against the run's recorded base branch

Opening a change request for a bullet SHALL target the run's recorded base
branch, not a guessed or host-default branch.

#### Scenario: The change request names the run's recorded base branch

- **WHEN** a bullet is sealed for a run with a recorded base branch
- **THEN** the change request opened for it targets that recorded branch

### Requirement: Merge state is checked when a run's pipeline view is activated, not on a schedule

Observing whether a sealed bullet's change request has merged SHALL happen
when an operator activates that run's pipeline view, and SHALL NOT happen
on any standing background schedule.

#### Scenario: Activating a run's pipeline view checks its sealed bullets' merge state

- **WHEN** an operator activates the pipeline view for a run with at least
  one sealed bullet carrying a recorded change request
- **THEN** that bullet's real merge state is checked as part of activating
  the view

#### Scenario: A run with no sealed bullets triggers no provider call

- **WHEN** a run with no sealed bullets (or no bullets at all) has its
  pipeline view activated
- **THEN** no change-request status check is attempted

### Requirement: An observed merge into the recorded base branch advances the bullet to merged

A sealed bullet whose change request is observed merged into the run's
recorded base branch SHALL advance to `merged`.

#### Scenario: A merge into the expected base advances the bullet to merged

- **WHEN** a sealed bullet's change request is observed merged into the
  run's recorded base branch
- **THEN** the bullet's status becomes `merged`

#### Scenario: A change request still open leaves the bullet untouched

- **WHEN** a sealed bullet's change request is observed not yet merged
- **THEN** the bullet's status remains `sealed`

### Requirement: An observed merge into a different base is flagged as a failure, not a successful delivery

A sealed bullet whose change request is observed merged into a branch
other than the run's recorded base branch SHALL move to `blocked`, with a
reason naming both the expected and the actual branch — never advanced to
`merged` and never left at `sealed` as if nothing happened.

#### Scenario: A merge into an unexpected base blocks the bullet

- **WHEN** a sealed bullet's change request is observed merged into a
  branch other than the run's recorded base branch
- **THEN** the bullet's status becomes `blocked`, with a recorded reason
  naming both the expected and the actual branch
