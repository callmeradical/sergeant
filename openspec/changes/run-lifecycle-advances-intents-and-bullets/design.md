# Design — A run's outcome advances its intent and bullets

## Ownership and merge order

One repository, `sergeant-v2`. One bullet, so no merge order.

## Where the transition belongs

`Server.executeRun` already computes the terminal status through `setTerminal`,
and it is the one place both a dispatch and a resume finish. Putting the
transition there means a resumed run advances its bullets exactly as a dispatched
one does, without a second code path to keep in step.

`setTerminal` currently writes the run status and returns. It gains the bullet
advance, so the two cannot diverge: a run that records `passed` cannot leave its
bullets `pending`.

## Deriving the intent rather than assigning it

Intent status must be computed from its bullets, never assigned from a run's
outcome. A single intent may span several bullets and several runs, so no one run
knows whether the intent is done. A helper answers it from the bullets:

- any bullet not `merged` → the intent stays `in_progress`
- every bullet `merged` → `satisfied`

This makes the D6 guarantee structural. There is no code path that can mark an
intent satisfied without every bullet having reached `merged`, and `merged` is
only reachable from observed pull-request state.

## Cancellation

A cancelled run must not move its bullets. An operator stopping a run has
concluded nothing about the work, and recording `failed` would assert a judgment
the operator did not make. This is the case most likely to be got wrong by
treating "not passed" as "failed".

## Idempotence

The transition must be safe to apply twice. A resumed run reaches `setTerminal`
again, and a bullet already `green` must stay `green` rather than error or
regress. Advancing to the same status is a no-op.

## Rejected alternatives

**Marking the intent satisfied when its run passes.** Directly violates D6.
Passing gates means the work exists, not that it was delivered.

**Storing intent status as a column updated by triggers.** Two authorities for one
truth. The bullets are the truth; the intent's status is a reading of them.

**Advancing bullets from inside the runner.** The runner reports phase outcomes and
should not know what an intent is. The seam is the run's terminal status.
