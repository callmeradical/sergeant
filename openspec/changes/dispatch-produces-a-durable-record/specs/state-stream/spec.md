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
