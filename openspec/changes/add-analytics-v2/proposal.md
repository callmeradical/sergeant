## Why

Sergeant records operational lifecycle state, but answering fleet-health questions requires manually correlating per-task files and logs. A local analytics ledger and deterministic report will expose success, latency, recovery, and failure trends while preserving Sergeant's local-first privacy model.

## What Changes

- Add a versioned append-only lifecycle event ledger with atomic, locked NDJSON writes.
- Capture dispatch-start, terminal, and recovery events as a first vertical slice; expand coverage in follow-on work.
- Add `sgt-analytics` reporting with JSON/human output, time and project/repository filters, counts, success rate, duration median/p95, and failure categories.
- Tolerate malformed records, bound retention, and keep capture best-effort so observed operations never fail because analytics is unavailable.
- Explicitly exclude network telemetry, prompts, briefs, responses, results, credentials, transcripts, and arbitrary SQL.

## Capabilities

### New Capabilities

- `analytics-ledger`: Privacy-safe, durable lifecycle event recording and bounded retention.
- `analytics-reporting`: Deterministic filtered aggregate reports in JSON and human-readable forms.

### Modified Capabilities

None.

## Impact

Adds a small local analytics package/CLI and minimally invasive hooks at existing lifecycle status transitions. No existing command contract, scheduler behavior, worker semantics, or remote service changes. Tests add fixture-driven schema, concurrency, corruption, retention, privacy, and aggregate coverage.
