# State stream

## ADDED Requirements

### Requirement: Clients follow state by ordered sequence rather than polling

State changes SHALL be appended to a monotonic sequence, and a client SHALL be
able to resume from the last sequence it saw. Decision D10 adopts this from AHP's
subscribe/snapshot/replay model, which treats reconnection as a protocol concern
rather than leaving each client to re-read the world.

#### Scenario: Sequence numbers strictly increase

- **WHEN** a state change is recorded
- **THEN** it is appended with a sequence number strictly greater than every
  sequence number already assigned

A reused sequence number would make replay ambiguous, so the sequence must not
reuse a value after a delete.

#### Scenario: A subscription from a sequence excludes that sequence

- **WHEN** a client subscribes from sequence N
- **THEN** it receives every change after N in ascending sequence order, and no
  change at or before N

Fails today: there is no sequence and no subscription. A client can only re-read
the full run list.

#### Scenario: An unknown sequence yields a snapshot, not an error

- **WHEN** a client subscribes from a sequence number the server has never
  assigned, or from one it no longer holds
- **THEN** the server answers with a full snapshot and the current sequence number

Covers a client returning after its history was pruned, and a client returning
after the database was rebuilt.

#### Scenario: An idle dashboard issues no repeated re-reads

- **WHEN** the dashboard is open and no state changes for sixty seconds
- **THEN** it issues no repeated full re-reads of the run list

Fails today: `setInterval(..., 2000)` in `internal/ui/static/index.html`
guarantees thirty full re-reads in that window, per connected browser. This is the
scenario that retires the polling loop.

### Requirement: An agent can follow a run it dispatched

The MCP surface SHALL expose a run's status by run id, and SHALL expose a call
that returns when the run reaches a terminal state. Decision D1 makes the
agent-driven path equal in standing to the coordinator-driven one, so an agent
that dispatches work must be able to observe it without scraping the dashboard's
HTTP endpoints or guessing a duration.

This requirement exists because the gap was hit in practice. With no way to follow
a run, both known consumers resorted to inventing a duration: the dashboard polls
every two seconds forever, and an operating agent slept for a guessed interval and
re-read the run list. The same missing capability produced the same wrong answer
twice.

#### Scenario: A run's status is addressable by run id

- **WHEN** an MCP client requests the status of a known run id
- **THEN** it receives that run's status, slug and phase results

Fails today: the MCP server exposes five tools and none accepts a run id.
`sergeant_status` takes an optional project filter, so a caller can enumerate runs
but cannot address one.

#### Scenario: An unknown run id is reported as unknown

- **WHEN** an MCP client requests the status of a run id that does not exist
- **THEN** it receives an explicit not-found result rather than an empty status

An empty status is indistinguishable from a run that has not started, which would
let a caller wait forever on a typo.

#### Scenario: Waiting returns when the run reaches a terminal state

- **WHEN** an MCP client waits on a run that is still executing
- **THEN** the call returns once the run's status is terminal, reporting that
  status

#### Scenario: Waiting on an already-terminal run returns immediately

- **WHEN** an MCP client waits on a run that has already finished
- **THEN** the call returns without delay

A wait that blocks on a finished run would reintroduce the guessed duration this
requirement removes.

#### Scenario: Waiting is bounded and says so when it gives up

- **WHEN** a wait exceeds its caller-supplied bound
- **THEN** it returns reporting that the run is still executing, and does not
  report a terminal status

A wait that returns "failed" on its own impatience would record a falsehood, which
the truthfulness rule forbids: the run's status is whatever the store says, not
whatever the caller's patience implies.
