# Proposal — A run's outcome advances its intent and bullets

## Repository

One repository: `sergeant-v2`, which owns the store and the run lifecycle.

## Requirements and decisions served

- **D4 — Sergeant stores intents and bullets itself.** Half-implemented. Dispatch
  writes them; nothing ever updates them.
- **D8 — the dashboard is a view of intents.** Blocked in practice: the primary
  object would display a status that is false for most rows.
- **D6 — sequenced submission, human merge.** Constrains the answer. Sergeant
  never merges, so no automatic transition may claim an intent is satisfied.

## Problem

`UpdateIntentStatus` and `UpdateBulletStatus` exist, are tested, and have no
production callers. Every dispatch creates an intent and its bullets; nothing
moves them afterwards.

Measured on the live database at the time of review:

```
intents:  in_progress 4   satisfied 2
bullets:  pending     4   merged    4
```

The two satisfied intents and four merged bullets were set by hand in SQL during
review. Every row the product wrote itself is still in its initial state,
including rows for runs that passed and runs that were cancelled.

This is worse than the state before D4 landed. An empty table was honestly empty.
A table of permanently `in_progress` intents asserts something untrue, and the
standing rule is that no value may be displayed or recorded that is not derived
from stored state.

## Proposal

Advance bullets from the run's recorded outcome, and derive intent status from its
bullets rather than from any single run.

The mapping is not a new decision. It follows from D6 and the documented lifecycle
`pending → red → green → sealed → merged`:

| Run outcome | Bullet becomes | Why |
|---|---|---|
| `passed` | `green` | gates passed; the work exists and is not delivered |
| `failed` | `failed` | recorded, and a resume can move it on |
| `cancelled` | unchanged | an operator stopping a run concludes nothing |

`sealed` stays owned by the pull-request path and `merged` by observed PR state.
An intent becomes `satisfied` only when every one of its bullets is `merged`.
Nothing else may set it, because under D6 sergeant is never the thing that merged.

## Out of scope

- Observing real PR state to advance `sealed` to `merged`. That is D6's own
  mechanism and needs its own change.
- Backfilling the rows currently stuck. The defect is the missing transition, not
  the rows; hand-patching them again would hide whether this change works.
