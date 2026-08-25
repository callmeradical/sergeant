# Task export

## ADDED Requirements

### Requirement: Intent and bullet transitions are exported to a configured target

A project with an `Export` block configured SHALL have every intent and
bullet transition recorded in the store's change log delivered to that
target exactly once, in the order the transitions occurred. Requirement D4
requires Sergeant to remain the sole authority over this state; this
requirement is what makes an external copy possible without that authority
moving.

#### Scenario: A bullet status change is exported

- **WHEN** a bullet's status is updated and a `Target` is configured for
  its project
- **THEN** `Target.Export` is called with a record naming that bullet's id,
  repo, and new status

#### Scenario: An intent creation is exported

- **WHEN** a new intent is created and a `Target` is configured for its
  project
- **THEN** `Target.Export` is called with a record naming that intent's id
  and status

#### Scenario: Transitions are exported in the order they occurred

- **WHEN** two transitions for the same project occur in sequence
- **THEN** `Target.Export` is called for the earlier transition before the
  later one

#### Scenario: A transition is not exported twice across a restart

- **WHEN** the export runner is stopped after successfully exporting a
  transition and restarted
- **THEN** that transition is not delivered to `Target.Export` again

### Requirement: An unreachable or failing export target never affects the underlying Sergeant operation

Exporting SHALL run fully out of band from the write path that produced the
transition. A `Target` that errors or is unreachable SHALL NOT block,
delay, or fail the intent/bullet write it would have exported, and SHALL
NOT be retried by re-attempting the original write.

#### Scenario: A bullet status update succeeds even though its export target is unreachable

- **WHEN** `Store.UpdateBulletStatus` is called while the configured
  `Target` returns an error for every call
- **THEN** `UpdateBulletStatus` returns success and the bullet's stored
  status reflects the update

#### Scenario: An export failure is retried on a later attempt without re-running the original write

- **WHEN** `Target.Export` fails for a transition and the target later
  recovers
- **THEN** that transition is eventually delivered to `Target.Export`
  without the original store write happening again

### Requirement: Exported records exclude content Sergeant does not already treat as safe to expose

An exported record SHALL NOT include raw secrets, credentials, or
unredacted free-text content beyond what this project's existing
redaction rules already consider safe. Requirement: consistency with
`internal/redact`'s existing posture; this is not a new redaction policy.

#### Scenario: An intent's statement is redacted before export

- **WHEN** an intent whose statement contains a credential-shaped value
  (matching an existing `internal/redact.Text` pattern) is exported
- **THEN** the exported record's statement field has that value replaced by
  the same placeholder `internal/redact.Text` already produces elsewhere

#### Scenario: An exported record contains no worktree path, branch name, or PR URL

- **WHEN** a bullet with a worktree, branch, and PR URL set is exported
- **THEN** the exported record contains none of those three fields

### Requirement: A project with no export target configured exports nothing

Export SHALL be strictly opt-in per project. A project with no `Export`
block configured SHALL produce no calls to any `Target`.

#### Scenario: No target is configured

- **WHEN** a project has no `export:` block in its configuration
- **THEN** no `Target.Export` call is made for that project's transitions
