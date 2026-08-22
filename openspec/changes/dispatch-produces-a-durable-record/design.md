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

Seven consequences fall out of that, all settled while implementing bullet 3.

**Five channels, not three.** The task names run, intent and bullet transitions.
Phase and envelope are announced too, because both already mutate what an operator
sees — `RecordPhase` bumps `runs.updated_at`, and an envelope is what the activity
view renders — and a client that could not see them would still need a timer to
notice them. Announcing a phase on its own channel, carrying its `run_id`, is also
what lets a client refresh one run's detail instead of the whole list.

**`CurrentSequence` reports the high-water mark, not `MAX(seq)`.** `AUTOINCREMENT`
keeps its mark in `sqlite_sequence`, which survives a delete. After a prune,
`MAX(seq)` is *below* a number already handed out, so a snapshot naming it would
tell a client to resume from behind reality and every later append would look like
a change it had already applied. The second scenario forbids reuse; this is the
read-side half of the same guarantee.

**A cursor at or below zero is no cursor, and no cursor means a snapshot.** The log
holds transitions, not state, so replaying it from zero cannot describe a run
recorded before the log existed. `CanReplayFrom` therefore refuses zero rather
than treating it as "replay everything", which would hand a fresh client an
authoritative-looking but incomplete view.

**`Last-Event-ID` outranks `?from`.** An `EventSource` reconnects to the URL it was
given, so `?from` keeps naming the sequence the *page* loaded with while
`Last-Event-ID` names the last event actually delivered. Preferring the query
string would re-deliver everything since page load on every reconnect — the cost
the change exists to remove, moved from a timer to the network.

**The stream still ticks once a second, per connection, as a fallback.** The
primary wake-up is an in-process notification from the store, which fires the
moment a change is appended. It cannot see a second process writing the same
database file, and that case is real: `sergeant mcp` records envelopes while
`sergeant ui` serves the stream. The retired cost was a *browser* re-reading the
whole run list thirty times a minute; one indexed `seq > ?` query per connected
client per second is not that, and without it an MCP-driven change would never
reach the dashboard. Refreshes on the client are coalesced over 80ms for the
mirror-image reason: a run recording twenty phases in one burst must not cause
twenty full re-reads at once.

**Only a statement that moved a row is announced.** `UpdateRunStatus` and
`DeleteRun` match nothing when the id names no run, and both are called with ids
whose existence the caller has not checked. A change row for a miss would tell
every subscriber that a run it cannot read had changed status — precisely the
claim the truthfulness rule forbids. Neither is turned into an error by this
change: whether relabelling an absent run should fail is a separate decision from
keeping the sequence truthful.

**`timed_out` joined the terminal run statuses, and the list became one exported
predicate.** `store.IsTerminalRunStatus` is now the single answer to "has this run
finished?", asked by slug reuse and by `sergeant_run_wait`. A second, shorter copy
of the list inside the MCP tool would eventually disagree and make a wait block
forever on a status the store already calls finished. `timed_out` belongs in it
because a timed-out run is listed as resumable precisely because nothing resumes
it by itself.

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

**Writing the change row in a transaction with the row it reports.** Considered and
declined for bullet 3. It would make eight write paths transactional to close a
window that only a disk failure opens, and the failure mode it prevents — a
transition recorded with no change row — is already reported: `AppendChange`'s
error is returned to the caller rather than swallowed, so a notification that did
not happen is never silently treated as one that did.

**Letting `sergeant_run_wait` infer a status from its own timeout.** The whole
point of the bound is that exceeding it says something about the *wait*, not about
the run. On timeout the tool reports the status the store holds, `terminal: false`,
`timed_out: true`, and says the run is still executing. Returning `failed` because
the caller ran out of patience would record a falsehood.
