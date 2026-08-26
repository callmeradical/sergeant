# Tasks — Graphify `exclude_patterns` is honored

One repository, `sergeant-v2`, so one task.

## Task 1 — filter the merged graph before publish

Repository: `sergeant-v2`. Depends on: nothing. Read
`internal/graphify/graphify.go`'s `BuildProjectGraph` and
`participatingRepoNames` first, and inspect a real built `graph.json`'s
shape (`nodes`/`links`/`hyperedges`, each carrying `source_file`; links via
`source`/`target` node ids, hyperedges via a `nodes` id list) before
writing the filter.

- Add a filtering step, called on the merged graph at `mergedPath`, after
  it is validated non-empty and before the manifest/publish steps, exactly
  as design.md specifies.
- Implement pattern matching with `*` (one path segment) and `**` (any
  number of segments), matched against each node/link/hyperedge's
  `source_file`. Do not add a third-party glob dependency (design.md).
- Preserve every graph.json field this pass does not touch byte-for-byte
  (do not round-trip through a struct that silently drops unknown keys).
- An empty or absent `exclude_patterns` must still run the filter code
  path and produce byte-identical output to the unfiltered input.
- Do not change `participatingRepoNames`/`include_groups` behavior. Do not
  touch the `graphify` binary invocation itself.

Verification: `go build ./... && go vet ./... && go test ./internal/... -count=1`.
Tests must cover every scenario in `specs/graphify-exclusion/spec.md`: a
node from an excluded file is absent from the filtered output; a link/
hyperedge from an excluded file is absent; a link/hyperedge left dangling
by node exclusion (its own `source_file` did not match, but an endpoint's
did) is also absent; a `**`-style recursive pattern excludes an entire
directory's contents, not just direct children; an empty `exclude_patterns`
produces output identical to the unfiltered input (assert byte-for-byte or
structurally, not just "no error"). Exit status decides the outcome.
