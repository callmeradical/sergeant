# Design — A dispatch produces a durable, idempotent, observable record

## Ownership and merge order

One repository owns every part: `sergeant-v2`. Because a single repository is
involved, the merge order is the bullet order within the intent, not a cross-repo
sequence:

1. persist intent and bullets
2. idempotency key
3. sequenced change stream

Bullet 2 depends on bullet 1 because a deduplicated dispatch must return the
existing intent, which requires the intent to exist. Bullet 3 depends on bullet 1
because the stream carries intent and bullet transitions, which are not yet
recorded.

## Bullet 1 — persist intent and bullets

`handleDispatch` currently writes a `RunRecord` and nothing else. Insert the
intent and bullet writes *after* `resolveChange` and *before* `CreateRun`, so the
ordering reads: planning record, then domain record, then execution record. O3
already forbids a run preceding the change; this extends the same rule inward.

Identity: intent id derives from the run id (`<run-id>-intent`) rather than a
random value, so the linkage is reconstructible from either side without a join
table. Bullet ids follow `<run-id>-b<position>`.

Position is the index of the repository in the resolved target list. The list is
already computed for the DAG fallback path; hoist that computation above the
record writes so both use one list and cannot disagree.

`RunRecord` gains an `intent_id` column so a run points at its intent. Migration
follows the existing additive pattern used for `slug` and `change_id`: add the
column, backfill nothing, tolerate empty.

## Bullet 2 — idempotency key

Add `request_id TEXT` to `runs` with a **unique index**, so the guarantee is
enforced by the database rather than by a check-then-insert race between two
concurrent POSTs. The handler inserts and inspects the constraint violation; it
does not query first.

`handleDispatch` gains `request_id` in its request struct. On a violation, look up
the existing run by key and return it with the same response shape as a fresh
dispatch, so the caller cannot tell the difference and does not need to branch.

An empty `request_id` must not collide with another empty one. A unique index
treats SQL `NULL` as distinct in SQLite, so store the absent case as `NULL`, never
as `''`.

Two consequences fall out of that, both settled while implementing bullet 2.

**The run row is written before the intent and the bullets.** Bullet 1 wrote the
intent first, on the reading "planning record, then domain record, then execution
record". That ordering cannot survive an idempotency key: the key is claimed by
the run insert, so a repeat that wrote the intent first would have created an
intent and N bullets by the time the key refused it. D8 makes the intent the
dashboard's primary noun, so every retry would surface as a duplicate intent on
the operator's screen. The run insert therefore comes first and carries the key.
O3's ordering is untouched — the change is still resolved before any row exists —
and the intent id stays derivable from the run id, so the run can point at its
intent before the intent row is written.

**A run id no longer comes from `time.Now().Unix()`.** Two dispatches inside one
second produced the same id and collided on the runs primary key. That made a
same-second repeat *look* deduplicated when nothing had deduplicated it, and it
made two dispatches that legitimately omit `request_id` fail outright. The spec's
same-second scenario names this: accidental collision is a different failure from
deliberate deduplication. Ids are now `sgt-<epoch>-<hex>` from `naming.RunID`,
which keeps the epoch readable and makes deduplication the key's job alone.

## Bullet 3 — sequenced change stream

Add an append-only `changes` table: `seq INTEGER PRIMARY KEY AUTOINCREMENT`,
channel, payload, timestamp. `AUTOINCREMENT` gives a strictly increasing sequence
that is never reused after a delete, which the second scenario requires.

Serve `GET /api/stream?from=<seq>` as Server-Sent Events. SSE over WebSocket
because the traffic is one-directional — the client sends commands over the
existing POST endpoints and only *reads* the stream. It needs no new framing, no
upgrade handshake, and it reconnects on its own.

When `from` exceeds the current maximum, or names a sequence no longer held, reply
with a snapshot event carrying the current sequence, then stream forward. The
client applies the snapshot wholesale and continues.

Frontend: replace the `setInterval` with an `EventSource`. The existing key-diff
render path stays — it is already the right shape for applying incremental updates
and becomes cheaper when fed actual deltas.

## Rejected alternatives

**Deriving idempotency from a hash of the request body.** Two deliberate, distinct
dispatches of the same brief would silently collapse into one. The key must be the
caller's stated intent to retry, not an inference from equal bytes.

**Keeping the poll and adding a sequence number to it.** Cheaper to build, and it
retires none of the cost: a client still wakes every two seconds and still cannot
learn what it missed while away.

**Adopting the AHP Go client for the stream.** Rejected by D10 for this change.
The client is 0.8.0 against a spec at 1.0.0 and the protocol reserves the right to
break. Borrow the design, decline the dependency.

**Shelling out to any `bin/sgt-*` helper for stream fan-out.** Forbidden by D7 and
not considered.
