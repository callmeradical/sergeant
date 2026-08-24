# Sergeant V2 Analytics — Product Requirements Document

**Status:** Draft for implementation; local-first, privacy-preserving  
**Owner:** Sergeant maintainers

## Summary

Sergeant records rich operational state in per-task fleet directories, but users must inspect many files and logs to answer basic questions: how often dispatches succeed, where time is spent, which failure classes recur, and whether workers make progress. Analytics V2 adds a deterministic, local-only telemetry ledger and query command deriving aggregates without sending data off-machine or changing dispatch behavior.

## Users and outcomes

The primary user is a single developer operating Sergeant across projects. They need to (1) understand recent fleet health in seconds, (2) compare outcomes by project/repository/agent, (3) identify latency and recovery hotspots, and (4) export bounded, reviewable data for local troubleshooting. Success means one command returns stable JSON suitable for scripts and a readable summary for humans.

## Scope

### In scope

- Append-only lifecycle events for dispatch, worker start, progress witness, response, recovery, terminal completion, and cleanup.
- Versioned event schema with event id, timestamp, project/repository/task identifiers, lifecycle state, agent, and bounded outcome/error category.
- Best-effort event capture at existing lifecycle seams; analytics must never block or fail the operation being observed.
- Local query/report command supporting time window, project/repository filters, JSON output, and human-readable summary.
- Derived counts (started, completed, failed, orphaned, recovered), success rate, median and p95 dispatch-to-terminal duration, and top failure categories.
- Corruption/truncation tolerance: valid records remain queryable and malformed tail records are reported as skipped diagnostics.
- Configurable bounded retention, with no prompts, briefs, result bodies, tokens, paths outside configured project identity, or worker transcript content in events.

### Out of scope

- Remote telemetry, hosted dashboards, accounts, tracking, or network calls.
- Changes to scheduling, worker selection, recovery policy, or task semantics.
- Full-text log indexing, arbitrary SQL exposure, or unbounded event storage.
- Predictive analytics, billing/cost attribution, or cross-user aggregation.
- Replacing fleet state or making the event ledger the authoritative control plane in this phase.

## Product requirements

1. **Privacy by construction.** Event fields are an explicit allowlist. Free-form input is categorized and bounded; raw brief, prompt, response, result, credentials, environment, and transcript text are rejected or redacted.
2. **Durability and ordering.** Each event is one atomic newline-delimited JSON record. Writers use an exclusive lock and append complete records. Event IDs are unique per installation and timestamps are UTC RFC3339.
3. **Non-interference.** Capture is best effort. Lock, disk, serialization, and schema errors are surfaced in diagnostics but never change the exit status of dispatch/watch/worker operations.
4. **Deterministic reporting.** Identical input produces identical ordering and aggregates. Unknown event versions/types are skipped with a count. No report includes raw payload text.
5. **Retention.** Default retention is 30 days and 50,000 records, whichever is smaller. Pruning is explicit or after successful append; pruning never removes the newest record and is atomic.
6. **Compatibility.** Existing commands and state files retain current interfaces. Analytics is disabled only when explicitly configured off; old installations can query an empty ledger successfully.
7. **Testability.** Tests cover schema allowlisting, concurrent append, malformed tail handling, deterministic aggregation, retention, privacy, and capture failure isolation.

## Initial vertical slice

Implement the event ledger library/command and report `dispatch_started`, `terminal`, and `recovery` events. Add a `sgt-analytics` CLI with `--json`, `--since`, `--project`, and `--repo`; report totals and duration percentiles. Wire capture into the least invasive existing lifecycle seam after status writes, then expand event coverage in follow-on changes.

## Acceptance criteria

- `sgt-analytics --json` exits 0 with an empty, versioned report on a new install.
- Valid events append atomically and concurrent writers produce parseable records.
- A report over fixture events returns exact totals, success rate, median, p95, and sorted failure categories.
- Malformed records are omitted, counted, and do not hide valid earlier records.
- Inputs containing prompt/brief/response-like fields never appear in the ledger or report.
- Injected ledger I/O failure leaves the observed Sergeant command's exit status and state transition unchanged.
