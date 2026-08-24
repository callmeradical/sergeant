## Purpose

Provides a durable, privacy-safe local record of Sergeant lifecycle transitions so reporting can measure fleet health without remote telemetry or control-plane coupling.

## ADDED Requirements

### Requirement: Append lifecycle events
The system SHALL append versioned newline-delimited lifecycle events containing only an explicit allowlist of installation-safe identifiers, UTC timestamp, lifecycle type, agent, and bounded outcome category.

#### Scenario: Valid event is recorded
- **WHEN** a lifecycle transition is captured
- **THEN** one complete parseable event is appended with a unique event identifier and RFC3339 UTC timestamp

#### Scenario: Sensitive content is submitted
- **WHEN** a capture request contains prompts, briefs, responses, results, credentials, transcripts, or unbounded free text
- **THEN** the sensitive values are excluded and the event remains within the allowlisted schema

### Requirement: Isolate analytics failures
The system SHALL treat lock, serialization, filesystem, and schema failures as non-fatal diagnostics that never alter the observed command's status or lifecycle transition.

#### Scenario: Ledger is unavailable
- **WHEN** an event append cannot complete
- **THEN** Sergeant continues the observed operation and exposes a bounded diagnostic without persisting sensitive input

### Requirement: Bound retention
The system SHALL support bounded retention by age and record count, with atomic pruning that preserves the newest event.

#### Scenario: Retention is applied
- **WHEN** retention runs after an append or explicit maintenance request
- **THEN** records beyond configured age/count limits are removed atomically and the newest event remains available

### Requirement: Tolerate corruption
The system SHALL skip unknown versions and malformed records while retaining valid records before and after the malformed record, and SHALL count skipped records in diagnostics.

#### Scenario: Ledger has malformed tail
- **WHEN** a report reads a truncated or malformed record
- **THEN** valid records remain queryable, the malformed record is omitted, and skipped count is reported
