# Work type

## ADDED Requirements

### Requirement: A dispatch must state its work type from a fixed vocabulary

Decision O2 requires a dispatched branch to be named `<type>/<change-id>`.
A dispatch SHALL name its work type as one of `feat`, `fix`, `refactor`,
`docs`, `chore`, or `test`. A dispatch naming no type, or one outside this
set, SHALL be refused before any run, intent, or worktree is created.

#### Scenario: A recognized type is accepted

- **WHEN** a dispatch names a type from the fixed set
- **THEN** the request proceeds

#### Scenario: A missing type is refused

- **WHEN** a dispatch names no type
- **THEN** the request is refused, and no run, intent, or worktree is
  created

#### Scenario: An unrecognized type is refused

- **WHEN** a dispatch names a type outside the fixed set
- **THEN** the request is refused, naming the valid set, and no run,
  intent, or worktree is created

### Requirement: The stated type is durably recorded

The type SHALL be recorded as a queryable fact on the run (and, for a
dispatch that proposes a plan rather than executing immediately, on the
intent), not derived only from a branch name after the fact.

#### Scenario: An executed dispatch's run records its type

- **WHEN** a dispatch with an explicit repository list is executed
- **THEN** the created run records the stated type

#### Scenario: A proposed plan's intent records its type

- **WHEN** a dispatch with no explicit repository list creates a proposed
  plan (decision D5a)
- **THEN** the created intent records the stated type

#### Scenario: Approving a proposed plan reuses its recorded type

- **WHEN** a proposed plan is approved
- **THEN** the run created for it records the same type the plan was
  proposed with, not a re-stated or re-derived one

### Requirement: The dispatched branch name reflects the type and the change

Decision O2's `<type>/<change-id>` convention SHALL be the actual branch
name a dispatch creates, and every part of the system that names or
references that branch SHALL agree on the same name.

#### Scenario: A dispatched branch is named by its type and change

- **WHEN** a dispatch executes (immediately, or via approving a proposed
  plan)
- **THEN** the branch created for its work is named `<type>/<change-id>`
  using the type and change actually recorded for that run

#### Scenario: Pull-request creation targets the same branch that was created

- **WHEN** a pull request is created for a dispatched run
- **THEN** it targets the exact branch name that was actually created for
  that run's worktree, computed the same way in both places
