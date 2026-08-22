# Proposal — A dispatch produces a durable, idempotent, observable record

## Repository

One repository: `sergeant-v2`. It owns every part of this change — the store
schema, the dispatch handler, and the embedded dashboard. No second repository is
involved, so this change is a single bullet chain rather than a cross-repo intent.

## Requirements and decisions served

- **D4 — Sergeant stores intents and bullets itself.** Currently unimplemented.
  `store.CreateIntent` and `store.CreateBullet` exist, are tested, and are called
  from nothing but `internal/store/store_test.go`. `handleDispatch` writes a
  `RunRecord` and stops. The `intents` and `bullets` tables are therefore empty in
  every real deployment.
- **D8 — The dashboard is a view of intents.** Blocked by the above. The primary
  list cannot be intents while no intent is ever written.
- **D10 — Sergeant follows AHP where AHP has settled the question.** Two of its
  settled designs are missing here: an idempotency key on run creation, and an
  ordered sequence that clients replay from instead of polling.

## Problem

Three defects, all in the same seam — what a dispatch durably records, and how a
client learns about it.

1. **The domain model is inert.** A dispatch produces a run. It does not produce
   the intent that motivated it or the bullets that carry it out. The product's
   own primary noun is never persisted, so nothing can render it, query it, or
   hold a merge order.

2. **A dispatch is not idempotent.** `handleDispatch` accepts
   `{project, brief, repos, agent, change_id}` and derives its identity from
   `time.Now().Unix()`. Two identical POSTs one second apart produce two runs, two
   worktrees, two branches, and two agents editing the same change. There is no
   key by which a caller can say "this is a retry, not a new request". AHP's
   `runAutomation` resolves this with a caller-supplied `requestId` and returns the
   existing run on repeat.

3. **Clients re-read the whole world every two seconds.** `index.html` calls
   `fetchRuns()` and `fetchFleet()` on a 2000ms interval, forever, per connected
   browser. There is no sequence number and no replay, so a client that misses an
   update cannot ask for what it missed — it can only wait for the next full
   re-read. This is why the dashboard needed hand-written key-diff DOM patching to
   avoid destroying scroll position and focus on every tick.

## Proposal

Make a dispatch write the full record it implies, make it safe to retry, and let
clients follow it by sequence.

- `POST /api/dispatch` accepts an optional `request_id`. A repeat of a known
  `request_id` returns the original run and starts nothing.
- A dispatch persists an `IntentRecord` for the brief and one `BulletRecord` per
  target repository, positioned in merge order, before any worktree or branch
  exists.
- Every state change appends to a monotonic sequence. Clients subscribe from a
  sequence number and receive what they missed, replacing the polling interval.

## Out of scope

- Adopting AHP as the wire protocol. D10 borrows the designs and explicitly
  declines the dependency.
- Triggers and schedules. AHP's automation channel has them; sergeant's dispatch
  is manual-only and stays that way until a decision says otherwise.
- The three hardcoded v1 fleet paths in `internal/ui/server.go` (lines 600, 669,
  1035). They are a v1-prohibition violation and a separate, more urgent bug.
  Filed separately; not mixed into this change.
