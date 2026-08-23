# Progress reporting

## ADDED Requirements

### Requirement: A dispatch seeds a checklist derived from its change

A dispatch SHALL write a plan into the worktree, derived from the OpenSpec change
the dispatch resolved to, before the agent phase begins.

#### Scenario: The checklist has one item per declared scenario

- **WHEN** a dispatch resolves to a change declaring eight scenarios
- **THEN** the seeded plan holds eight items, each with a stable id and the
  scenario text, each `pending`

#### Scenario: The checklist exists before the agent starts

- **WHEN** an agent phase begins
- **THEN** the plan file is already present in the worktree

An agent cannot report against a checklist it was never given.

#### Scenario: A change declaring no scenarios yields an empty plan, not a missing one

- **WHEN** a dispatch resolves to a change with no scenarios
- **THEN** a plan exists holding zero items

The absence of scenarios is a fact about the change. A missing file would be
indistinguishable from a dispatch that failed to seed one.

### Requirement: Reported progress is published without polling

Observed changes to the checklist SHALL be appended to the change sequence and
delivered over the existing stream.

#### Scenario: Marking an item is observable

- **WHEN** the agent marks three of eight items complete
- **THEN** a subscriber to the change stream observes progress of three of eight
  for that run

#### Scenario: An unwritten plan reports nothing, not zero

- **WHEN** the agent has not yet written to the plan
- **THEN** the run reports that no progress has been reported

"No report yet" and "reported zero complete" are different statements, and only
one of them is true before the agent has written.

#### Scenario: A malformed plan does not fail the run

- **WHEN** the plan file cannot be parsed
- **THEN** the run continues and reports that no progress has been reported

A reporting channel must never be able to fail the work it reports on.

### Requirement: Reported progress is never presented as verified completion

Reported progress SHALL be labelled as reported and SHALL NOT change a run's or a
phase's status.

#### Scenario: A fully reported plan does not pass a run

- **WHEN** the agent marks every item complete and a required gate then fails
- **THEN** the run's status is `failed`

Decision R2.6 and the truthfulness rule: nothing but a real gate result may mark
work as passed, and an agent's self-report is not a gate result.

#### Scenario: Progress is shown alongside status, not instead of it

- **WHEN** a run reports progress
- **THEN** the run's phase status remains visible

An operator reading `8/8` must still be able to see that the run failed.

### Requirement: Each item shows its state, with a total beneath

The interface SHALL show one marker per checklist item, distinguishing three
states, with the completed count and total beneath them.

#### Scenario: A completed item is a solid circle

- **WHEN** an item is marked complete
- **THEN** it renders as a solid circle

#### Scenario: An item not yet started is an open circle

- **WHEN** an item has not been started
- **THEN** it renders as an open circle

#### Scenario: The item being worked on is a spinner

- **WHEN** an item is in progress
- **THEN** it renders as an animated spinner

The spinner is what distinguishes a working run from a hung one. A run showing
only solid and open circles is indistinguishable from a stalled process, which is
the condition this change exists to remove.

#### Scenario: The count appears beneath the markers

- **WHEN** three of eight items are complete
- **THEN** the count reads three of eight, beneath the markers

#### Scenario: Exactly one item is in progress at a time

- **WHEN** the agent marks a new item in progress
- **THEN** no other item is in the in-progress state

Two spinners would tell the operator the agent is doing two things at once, which
the execution model does not do: concurrency has never exceeded one.

#### Scenario: A run with no reported progress shows open circles, not a spinner

- **WHEN** no progress has been reported
- **THEN** every item renders as an open circle and none as a spinner

A spinner asserts that work is underway on a specific item. Before the agent has
reported, that is not known.
