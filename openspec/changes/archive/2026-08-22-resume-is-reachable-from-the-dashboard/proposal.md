# Proposal — Resume is reachable from the dashboard

## Repository

One repository: `sergeant-v2`, which owns the endpoint and the embedded dashboard.

## Requirements and decisions served

- **D5 — only three interruptions.** A blocked bullet is one of them. A run that
  died is the most common way a bullet blocks, and the operator currently has no
  way to act on it from the interface that told them about it.
- **R4.2 — worktree and branch are recorded and shown.** The drawer already shows
  both. Recovery is the action the operator wants once they have seen them.

## Problem

`POST /api/run-resume` exists, is tested, and recovered a real orphaned run. No
part of the dashboard calls it. An operator who sees a failed run in the interface
has to leave it, find the run id, and issue a curl request.

That is the whole gap. It is small, and leaving it means the capability
effectively does not exist for the person it was built for.

## Proposal

Offer resume on a run that can be resumed, from the run's own detail view, and
report what it will skip before doing it.

The control appears only for a run whose status the endpoint will accept —
`failed`, `cancelled` or `timed_out`. Rendering it on a passed run would invite an
action the server refuses, and rendering it on a running run would invite an
action that corrupts a worktree. The server already refuses both; the interface
must not offer what the server will reject.

## Out of scope

- Retrying an individual phase. Resume re-enters a run at the first phase without
  a passed record. Selecting an arbitrary phase to re-run is a different
  capability and needs its own decision about what happens to the phases after it.
- Resuming several runs at once. Concurrency has never exceeded one run, so a bulk
  control would be speculative.
