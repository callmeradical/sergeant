# delivery-surfaces Specification

## Purpose
Make a run's delivery history — including dead letters — visible and
actionable where an operator already looks: queryable as a whole per run,
exposed over HTTP, and rendered in the embedded dashboard alongside a
quarantine action that is a thin pass-through to the store's own guard, never
a second place that guard's rule could drift.
## Requirements
### Requirement: A run's delivery history is queryable as a whole, not only per envelope/consumer pair

The store SHALL provide a way to list every delivery belonging to any
envelope of a given run. Requirement R5.6 requires delivery state, attempts,
and errors to be exposed scoped by run, among other dimensions.

#### Scenario: Deliveries from multiple envelopes and consumers are all returned for a run

- **WHEN** a run has produced deliveries for more than one envelope and more
  than one consumer
- **THEN** listing that run's deliveries returns all of them

#### Scenario: A run with no deliveries returns an empty list, not an error

- **WHEN** a run exists but no delivery has ever been recorded for it
- **THEN** listing that run's deliveries returns an empty list

### Requirement: The API exposes a run's delivery history

An HTTP endpoint SHALL return a run's delivery history as JSON. Requirement
R5.6 requires the CLI and embedded UI to expose this; the API is the shared
substrate both read from.

#### Scenario: Requesting delivery history for a run returns its deliveries

- **WHEN** a GET request names a run with recorded deliveries
- **THEN** the response is a JSON array of those deliveries, including state,
  attempt, error, error class, and recovery instructions

#### Scenario: Requesting delivery history without a run id is refused

- **WHEN** a GET request omits the run id
- **THEN** the response is an HTTP 400, not a server error or an empty result
  that could be mistaken for "no deliveries"

### Requirement: An operator can quarantine a dead-lettered delivery through the API

An HTTP endpoint SHALL call the store's existing quarantine guard, refusing
exactly when the guard refuses. Requirement R5.6 requires policy-controlled
quarantine operations; this is the surface an operator or future CLI/MCP tool
calls.

#### Scenario: Quarantining a dead letter through the API succeeds

- **WHEN** a POST request names an envelope/consumer pair whose latest
  delivery state is dead_letter, with a reason
- **THEN** the delivery is quarantined and a subsequent history request shows
  the quarantined state and reason

#### Scenario: Quarantining a non-dead-lettered delivery through the API is refused

- **WHEN** a POST request names an envelope/consumer pair whose latest
  delivery state is not dead_letter
- **THEN** the response is an error and no new delivery row is written

The API must not weaken or bypass the guard `Store.QuarantineDelivery`
already enforces — it is a thin transport over the same store call, not a
second place the rule could drift.

### Requirement: The dashboard shows a run's delivery history, including dead letters, and can quarantine one

The embedded dashboard SHALL render a run's delivery history where an
operator already looks at that run's activity, and SHALL let an operator
quarantine a dead-lettered delivery with a reason. Requirement R5.6 requires
the embedded UI to expose delivery state and dead letters.

#### Scenario: A run's drawer shows its deliveries alongside its envelopes

- **WHEN** an operator opens a run's activity drawer and that run has
  recorded deliveries
- **THEN** the drawer shows each delivery's state, consumer, and attempt
  count without requiring a separate view or page

#### Scenario: A dead-lettered delivery is visually distinguishable and quarantinable

- **WHEN** a run's drawer shows a delivery in the dead_letter state
- **THEN** it is visually distinct from a delivered or pending one, and
  offers a quarantine action that submits a reason

