## Context

The proposal introduces analytics without changing Sergeant's control plane. Existing lifecycle state is represented by files under per-task fleet directories and shell commands are the primary integration surface. See `proposal.md`, `analytics-ledger/spec.md`, and `analytics-reporting/spec.md` for product and behavioral authority.

## Goals / Non-Goals

**Goals:** Add a small, dependency-free ledger/reporting seam; preserve Bash 3.2 portability; make writes atomic and concurrency-safe; keep analytics failures non-fatal; enable deterministic fixture testing.

**Non-Goals:** Replace fleet state, introduce a database, expose a network endpoint, index transcripts, or alter dispatch/recovery decisions.

## Decisions

1. **NDJSON ledger under the existing Sergeant data root.** NDJSON is inspectable, append-friendly, and streamable without a database migration. SQLite was rejected because it adds locking/migration coupling and risks private-state coupling.
2. **One shared shell library plus `sgt-analytics`.** Existing commands are shell scripts; a sourced helper minimizes integration and preserves installation behavior. A Go-only service was rejected for the first slice because it would require a new runtime boundary.
3. **Exclusive lock plus temp-and-rename maintenance.** `mkdir` lock acquisition works on macOS and Linux; append writes complete records while pruning uses a temporary file and rename. Advisory-only locking was rejected because concurrent writers could interleave records.
4. **Closed schema and categorical errors.** Identifiers and bounded categories are safer than free-form payloads. Raw operational text is deliberately unavailable to reporting.
5. **Best-effort hooks after state transitions.** State files remain authoritative; capture occurs after successful writes and failures are diagnostics only. Making event persistence transactional with lifecycle state was rejected because it would violate non-interference.

## Risks / Trade-offs

- [Risk] A crash between lifecycle transition and capture loses an event → reports document best-effort semantics and later coverage can add recovery scans.
- [Risk] Lock contention delays capture → bounded acquisition and non-fatal timeout diagnostics.
- [Risk] Percentiles are approximate for small samples → define nearest-rank deterministic calculation and expose sample counts.
- [Risk] Existing installations have no ledger → empty report is a supported successful state.

## Migration Plan

Create the ledger lazily on first event. Existing state remains readable. Disable capture with an explicit configuration flag if needed. Rollback removes hooks and the command; retained ledger files are inert local data and need not affect prior commands.

## Open Questions

None for the initial vertical slice.
