# Tasks — Envelopes are typed, versioned and correlated

One repository, `sergeant-v2`, so one task and no cross-repo merge order. This is
bullet 1 of 4 against R5; the remaining three merge after it.

## Task 1 — give an envelope its metadata, validate it, and make it immutable

Repository: `sergeant-v2`. Depends on: nothing.

- Extend `EnvelopeRecord` with `Type`, `SchemaVersion`, `OccurredAt`,
  `PublishedAt`, `Producer`, `CorrelationID`, `CausationID` and `PhaseID`.
- Migrate additively with the established `PRAGMA`-guarded pattern, defaulting
  empty, so existing rows remain readable.
- Validate on publication: refuse an envelope missing type, schema version,
  producer or correlation id, returning an error and writing nothing.
- Refuse an id that already exists rather than overwriting it.
- Set the correlation id to the run id at every existing call site, and set
  causation where one envelope follows another within a run.
- Keep `Summary`, `Artifacts` and `Data` as they are.

Verification: `go build ./... && go vet ./... && go test ./internal/... -count=1`.
Tests must cover each refusal, both timestamps surviving a round trip, one
correlation id shared across a run's envelopes, an absent causation id on the
first envelope, republication being refused, and a pre-migration row reading back
with an empty type rather than erroring. Exit status decides the outcome.
