# Independent review

## ADDED Requirements

### Requirement: A repo whose pipeline does not configure review is unaffected

A repository's factory pipeline that does not list `"review"` SHALL behave
exactly as it did before this change — no review phase is dispatched, no
new store writes occur, and a bullet's path from green to sealed is
unchanged. Decision D5 is not amended by this requirement: this proposal
adds no interruption that did not already exist for such a repo.

#### Scenario: A pipeline with no review phase runs unchanged

- **WHEN** a repo's `Factory.Pipeline` contains no `"review"` entry
- **THEN** `RunStage` dispatches no review agent, and the run's pass/fail
  outcome is determined exactly as before this change

### Requirement: A configured review phase runs after other phases and before a bullet can seal

When a repo's pipeline lists `"review"`, the review phase SHALL run using
the bullet's diff and its available spec context, not the implementing
phases' own reasoning, satisfying decision D3's need for a second,
independent check beyond deterministic gates.

#### Scenario: A review phase is dispatched with the diff, not prior envelopes

- **WHEN** a repo's `Factory.Pipeline` lists `"review"` after `"build"` and
  `"test"`
- **THEN** the review phase's prompt is built from the worktree's diff
  against its merge base and the stage/repo context only, and contains no
  content copied from the `"build"` or `"test"` phases' envelopes

### Requirement: A blocking finding moves the bullet to blocked, carrying the finding as the reason

A review phase reporting a `severity: "error"` finding SHALL cause the run
to conclude in a way that reuses the existing blocked-bullet mechanism
(`a-stuck-bullet-is-blocked-not-failed`) rather than a new bullet state,
consistent with decision D5's "three interruptions only."

#### Scenario: A blocking finding blocks the bullet with the finding's summary as the reason

- **WHEN** a review phase's envelope reports a finding with `severity:
  "error"` and a `summary`
- **THEN** the run concludes `"failed"`, and the bullet the run's intent
  carries becomes `"blocked"` with `BlockedReason` equal to that finding's
  summary

#### Scenario: Multiple blocking findings still produce one recorded reason

- **WHEN** a review phase's envelope reports more than one `severity:
  "error"` finding
- **THEN** the bullet becomes `"blocked"` with a reason that includes each
  blocking finding's summary, not only the first

### Requirement: A non-blocking finding is recorded without interrupting anyone

Findings below blocking severity SHALL be recorded as evidence and SHALL
NOT change the bullet's status or trigger any of D5's three interruptions.

#### Scenario: An info or warning finding does not block the bullet

- **WHEN** a review phase's envelope reports only findings with severity
  `"warning"` or `"info"`
- **THEN** the review phase does not fail, the run proceeds to conclude
  based on the rest of the pipeline, and a passing outcome still advances
  the bullet to `"green"`

#### Scenario: Recorded findings are readable after the run concludes

- **WHEN** a review phase's envelope reports any findings, blocking or not
- **THEN** those findings are readable from the run's stored envelopes
  after the run concludes, via the same access pattern as any other
  envelope payload

### Requirement: The review phase's prompt excludes other phases' envelope content

The independence property SHALL be structural: the function that builds a
review phase's prompt SHALL NOT accept or reference any other phase's
envelope for the same run.

#### Scenario: The review prompt builder has no access to prior envelopes

- **WHEN** the review phase's prompt is constructed for a run whose earlier
  phases produced envelopes with distinct summaries
- **THEN** the constructed prompt string does not contain any of those
  earlier envelopes' summary or payload text
