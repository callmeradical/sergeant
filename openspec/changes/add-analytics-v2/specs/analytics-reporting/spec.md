## Purpose

Gives a developer deterministic, bounded views of Sergeant fleet health, including outcomes, latency, recovery, and failure categories, in both machine-readable and human-readable formats.

## ADDED Requirements

### Requirement: Produce filtered reports
The system SHALL provide a report command with JSON and human-readable output modes and filters for time window, project, and repository.

#### Scenario: Empty installation is queried
- **WHEN** a developer requests JSON analytics with no ledger
- **THEN** the command exits successfully and returns a versioned empty report with zero totals

#### Scenario: Filters are supplied
- **WHEN** a report includes valid since, project, or repository filters
- **THEN** only matching events contribute to the report and output ordering is deterministic

### Requirement: Compute fleet aggregates
The report SHALL include started, completed, failed, orphaned, and recovered totals; success rate; median and p95 dispatch-to-terminal duration; and sorted failure categories.

#### Scenario: Fixture events are reported
- **WHEN** a report reads valid fixture lifecycle events
- **THEN** every aggregate equals the deterministic result for the selected events and no raw payload is emitted

### Requirement: Keep reports privacy-safe
The report SHALL omit prompts, briefs, responses, results, credentials, transcript content, and arbitrary event payloads from every output mode.

#### Scenario: Sensitive event fields exist in source input
- **WHEN** source data includes prohibited sensitive fields
- **THEN** those values never appear in JSON or human-readable report output
