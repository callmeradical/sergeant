# Proposal — A dispatched agent reports progress against its plan

## Repository

One repository: `sergeant-v2`.

## Requirements and decisions served

- **R7.1 — a run "reports stage progression and failure clearly."** Partially met:
  stage transitions are visible, but the agent phase is a single opaque block that
  is most of the wall time.
- **D8 — the dashboard renders a definition with progress against it.** Progress
  currently means "which phases finished", which cannot move for 20 minutes.

## Problem

An agent phase reports `running` and nothing else until it ends. Observed on a
live run while writing this: 6 files modified in the worktree, 0 commits, phase
status `running 0s`. The operator has no way to tell that from a hung process.

Duration cannot be predicted from the plan, so an estimated bar would be a
fabrication. Measured across five completed changes, plan size correlates
*negatively* with agent time (r = -0.91): 9 scenarios took 394s, while 4 scenarios
took 1309s. Anything resembling "60% complete, 4 minutes remaining" would be
invented.

But the plan itself is already known, in machine-readable form, before the work
starts. Every change declares `#### Scenario:` blocks, and this repository's own
rule is that a scenario must be able to fail as a test. That is a checklist with a
fixed denominator.

## Proposal

Seed a checklist into the worktree at dispatch, derived from the change the
dispatch resolved to. Instruct the agent to mark items as it completes them.
Publish changes to the checklist on the existing change stream, and render
`5/8` against the run.

Progress is **reported**, not proven. The gates remain the only authority on
whether work is done. The interface must never present a reported 8/8 as though a
gate had passed — they answer different questions, and conflating them would
breach the standing rule against recording a value stored state does not support.

## Out of scope

- Estimated time remaining. The data does not support it.
- Deriving progress by matching tests to scenarios automatically. Useful later,
  and it needs a mapping this change does not have.
