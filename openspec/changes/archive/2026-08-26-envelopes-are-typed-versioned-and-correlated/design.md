# Design — Envelopes are typed, versioned and correlated

## Ownership and merge order

One repository, `sergeant-v2`. First of four bullets against R5; bullets 2 to 4
merge after this one because a delivery state machine needs an envelope identity
to key on.

## The added metadata

`EnvelopeRecord` gains, alongside the existing fields:

- `Type` and `SchemaVersion` — what this is and which shape its payload takes.
- `OccurredAt` and `PublishedAt` — when the thing happened and when it was
  recorded. Kept separate because collapsing them hides delay, and delay is
  exactly what a transport is judged on.
- `Producer` — what emitted it.
- `CorrelationID` and `CausationID` — the chain.
- `PhaseID` — the missing link in the reference chain; run and repo already exist.

## Correlation is derived, not invented

The correlation id is the run id. A run is already the unit every envelope belongs
to, and reusing it means the chain cannot drift from the records it describes. A
fresh identifier would have to be kept in step with the run id, and would
eventually disagree.

Causation is the id of the envelope that preceded this one within the run, where
there is one. The first envelope of a run has none, and absent must be
distinguishable from empty.

## Validation at publication

`RecordEnvelope` rejects an envelope missing a type, a schema version, a producer
or a correlation id. Rejection returns an error rather than writing a partial
record — a transport that accepts malformed input and stores it has moved the
failure somewhere harder to find.

Validation applies to new writes only. Rows written before this change are read
back as they are.

## Immutability

Publication is final. `RecordEnvelope` refuses an id that already exists rather
than overwriting it, so an accepted envelope cannot be silently rewritten. R5.1
calls for immutability after publication and the current code has nothing
enforcing it.

## Migration

Additive columns with the established `PRAGMA`-guarded pattern, defaulting empty.
An envelope written before this change reads back with no type, which is the truth
about it. Backfilling a type would invent one.

## Rejected alternatives

**A separate `envelope_metadata` table.** A join for data that is always read with
the envelope, and it makes partial writes representable.

**Storing metadata inside the existing `Data` payload.** Unqueryable without
parsing every row, and it conflates the envelope with its contents — the exact
confusion R5.1 exists to remove.

**Generating a fresh correlation id per run.** A second identifier for a thing
that already has one, requiring them to be kept in step forever.

**Validating on read instead of write.** Moves the failure away from the code that
caused it and leaves bad rows in the store.
