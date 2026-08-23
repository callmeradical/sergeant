# Proposal — A restarted coordinator reconciles orphaned runs

## Repository

One repository: `sergeant-v2`.

## Requirements and decisions served

- **R6.3 — "A restarted coordinator can inspect the durable run and phase records
  and report the known state without starting speculative duplicate
  assignments."** Unmet.

## Problem

A run's status is written to the database when it starts and again when it
finishes. If the coordinator dies in between, the row stays `running` forever.
Nothing reconciles it on restart.

Observed for real, not hypothesised. The UI server was killed while run
`rust-newt-taipei` was executing:

```
run rust-newt-taipei      status: running     process: none
POST /api/run-resume  -> refused: "is running and cannot be resumed"
```

The work became unrecoverable through any supported path. Resume is right to
refuse — it cannot distinguish an orphan from a live run, and resuming a live run
would put two agents in one worktree. Cancel is the only way out, and it requires
an operator who knows to do it.

Every run is therefore one crash away from being stranded, and the crash need not
be dramatic: a terminal closing, a laptop sleeping, or a deploy is enough.

## Proposal

On startup, before serving, find every run marked `running` and move it to a
terminal status this process did not observe finishing. A restarted coordinator
knows one thing with certainty: it is not driving any run, because it has only
just begun. Any run claiming otherwise is stale.

The status recorded is `interrupted`, not `failed`. The run did not fail — nothing
judged the work. It was cut off. Recording `failed` would assert a verdict no gate
delivered, which the truthfulness rule forbids and which would also mislead an
operator into thinking the work was tried and found wanting.

`interrupted` is resumable, so the normal recovery path applies with no operator
archaeology.

## Out of scope

- Detecting a *second* coordinator running concurrently. Reconciliation assumes
  one coordinator per store; two would each reconcile the other's live runs.
  Guarding that needs a lease, which is its own change.
- Automatically resuming reconciled runs. A crash may have been caused by the run,
  and relaunching it unattended could loop. The operator decides.
