# Intent brief

## ADDED Requirements

### Requirement: A bullet's brief renders from its stored intent and bullet rows

The brief a dispatched agent receives SHALL be derived entirely from the
stored `IntentRecord` and the one `BulletRecord` matching the target repo,
not from unrelated project configuration and not from an operator's raw
typed text alone. Requirement D1 requires both dispatch paths to describe
the same work identically; D4 requires that description to come from
Sergeant's own stored rows.

#### Scenario: The UI-dispatched path's agent prompt includes the intent statement and bullet state

- **WHEN** a stage's agent phase runs for a repo whose run has an intent id
- **THEN** the prompt passed to the agent includes the intent's statement,
  that bullet's repo, position, and current status

#### Scenario: A blocked bullet's brief includes its recorded reason

- **WHEN** a brief is rendered for a bullet whose status is blocked
- **THEN** the rendered brief includes the bullet's recorded blocked reason

#### Scenario: A bullet with no blocked reason omits the blocked-reason line

- **WHEN** a brief is rendered for a bullet whose status is not blocked
- **THEN** the rendered brief contains no blocked-reason line

### Requirement: The MCP brief tool and the UI-dispatched path render identical content for the same intent and repo

Both paths D1 names ("two ways in, one set of records") SHALL produce the
same brief content for the same intent and bullet, since both call the same
rendering function.

#### Scenario: sergeant_get_brief and the dispatch-time prompt agree

- **WHEN** `sergeant_get_brief` is called with an intent id and repo, and
  separately a dispatch-time prompt is rendered for the same intent id and
  repo with the same gate names
- **THEN** the two rendered documents are identical

#### Scenario: sergeant_get_brief refuses a repo with no matching bullet

- **WHEN** `sergeant_get_brief` is called with an intent id and a repo that
  has no bullet on that intent
- **THEN** the call returns an error and no brief

### Requirement: Rendering a brief is read-only and idempotent

Rendering SHALL never write a new stored copy of the brief. Requirement D4
resolved intents/bullets as the sole store for this state; a rendering that
wrote a second copy would recreate the problem D4 already closed.

#### Scenario: Rendering twice with no state change in between produces identical output

- **WHEN** a brief is rendered for the same intent and repo twice in a row,
  with no write to that intent or bullet in between
- **THEN** the two renderings are byte-for-byte identical and no new row or
  file was written by either call

### Requirement: A run with no intent id falls back to its existing behavior

A run created before this change, or any run whose intent id is empty,
SHALL continue to receive exactly the prompt it would have received before
this change existed.

#### Scenario: A run with no intent id still receives stage.Brief

- **WHEN** an agent phase runs for a stage whose run has no intent id
- **THEN** the prompt passed to the agent is `stage.Brief`, or the existing
  generic fallback string when `stage.Brief` is empty
