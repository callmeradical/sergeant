# Bullet approval

## ADDED Requirements

### Requirement: Creating a pull request is refused for a bullet that has not passed its gates

A pull-request-creation request SHALL be refused when the target bullet's
current status is not green. Requirement R3.5 requires human approval to be
required, not merely possible, for a risky delivery action.

#### Scenario: PR creation for a green bullet is permitted

- **WHEN** a pull-request-creation request names a run whose bullet for that
  repo is green
- **THEN** the request proceeds

#### Scenario: PR creation for a non-green bullet is refused

- **WHEN** a pull-request-creation request names a run whose bullet for that
  repo is not green (pending, red, already sealed, or failed)
- **THEN** the request is refused with an error identifying the bullet's
  actual status, and no pull request action is attempted

### Requirement: A successful pull-request-creation action durably records that a human approved it

Approving a bullet's delivery via pull-request creation SHALL transition
that bullet to a distinct, durable state, not leave it indistinguishable
from a bullet that has not yet been approved. Requirement R3.5 requires
explicit approval for a risky delivery action; D5 names "a bullet ready for
an irreversible step" as a legitimate interruption.

#### Scenario: A successful PR-creation request seals the bullet

- **WHEN** a pull-request-creation request for a green bullet succeeds
- **THEN** that bullet's status becomes sealed

#### Scenario: Sealing affects only the one bullet the action was for

- **WHEN** a pull-request-creation request seals one bullet in a multi-repo
  intent
- **THEN** the intent's other bullets are unaffected

### Requirement: A run's bullets and their statuses are inspectable

An API caller SHALL be able to list the bullets belonging to a run's intent
and their current statuses, so which bullets are green (awaiting approval)
versus sealed (already approved) is observable rather than only inferable.

#### Scenario: Listing a run's bullets shows their current statuses

- **WHEN** a run with an intent and one or more bullets is queried
- **THEN** the response lists each bullet with its current status, including
  green and sealed

#### Scenario: A run with no intent returns an empty list, not an error

- **WHEN** a run that predates intent tracking (no intent id) is queried
- **THEN** the response is an empty list, not an error
