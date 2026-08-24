# Plan approval

## ADDED Requirements

### Requirement: A dispatch with no explicit repository list requires human approval before any work begins

A dispatch whose decomposition was not stated explicitly by the caller
SHALL be recorded as a plan awaiting approval, not executed. Decision D2
requires inferred decomposition to require explicit human approval before
any worktree is created; decision D5(a) requires a human to be notified
when such a plan awaits approval.

#### Scenario: A dispatch naming no repositories creates a proposed plan and starts nothing

- **WHEN** a dispatch request supplies no `repos`
- **THEN** an intent is recorded with status `proposed`, one bullet per
  resolved repository is recorded with status `proposed`, and no run,
  worktree, branch, or agent process is created

#### Scenario: A dispatch naming explicit repositories is unaffected

- **WHEN** a dispatch request supplies a non-empty `repos` list
- **THEN** the request proceeds exactly as it did before this change: a run
  is created and dispatched immediately, with no proposed intermediate
  state

### Requirement: A plan awaiting approval is inspectable

An operator SHALL be able to see which plans are awaiting approval and what
each one proposes, so decision D5(a)'s "a human is notified" is actionable
rather than only theoretically true.

#### Scenario: Proposed plans are listable with their proposed bullets

- **WHEN** one or more intents exist with status `proposed`
- **THEN** they are listed, each with its proposed bullets and target
  repositories

### Requirement: A human can explicitly approve or reject a proposed plan

Approving a plan SHALL be the only way its work begins. Rejecting a plan
SHALL end it without starting any work.

#### Scenario: Approving a proposed plan starts dispatch

- **WHEN** a proposed intent is approved
- **THEN** the intent and its bullets transition out of `proposed`
  (`in_progress` and `pending` respectively) and the same dispatch sequence
  an explicit-repos request uses begins for those bullets' repositories

#### Scenario: Rejecting a proposed plan starts nothing

- **WHEN** a proposed intent is rejected
- **THEN** the intent transitions to `abandoned` and no run, worktree,
  branch, or agent process is created

#### Scenario: Approving an already-approved plan is idempotent

- **WHEN** an intent that has already left `proposed` (via prior approval)
  is approved again
- **THEN** the existing state is returned unchanged; no second run is
  created

#### Scenario: Rejecting an already-rejected plan is idempotent

- **WHEN** an intent that is already `abandoned` is rejected again
- **THEN** the existing state is returned unchanged, without error

#### Scenario: Approving or rejecting a plan that was never proposed is refused

- **WHEN** approval or rejection targets an intent whose status is neither
  `proposed` nor the terminal state that action would produce
- **THEN** the request is refused and no state changes
