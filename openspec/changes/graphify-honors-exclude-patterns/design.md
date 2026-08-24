# Design — Graphify `exclude_patterns` is honored

## Ownership

One repository, `sergeant-v2`. Touches only `internal/graphify/graphify.go`
(a new filtering step) and a new small helper for pattern matching in the
same package.

## Where filtering runs

In `BuildProjectGraph`, immediately after the merged graph at `mergedPath`
is validated non-empty and before the manifest is written / the existing
atomic publish (backup-rename, rename, cleanup) runs:

```go
if err := filterGraphFile(mergedPath, proj.Graphify.ExcludePatterns); err != nil {
    return fmt.Errorf("applying exclude_patterns: %w", err)
}
```

A failure here returns before any publish step touches `output`, so it
cannot corrupt or partially replace the prior graph — it fails exactly
like a merge failure does today, before publish is ever reached.

## `graph.json` shape (confirmed against a real built graph)

```json
{
  "nodes": [{ "id": "...", "source_file": "path/relative/to/repo", ... }],
  "links": [{ "source": "<node id>", "target": "<node id>", "source_file": "...", ... }],
  "hyperedges": [{ "id": "...", "nodes": ["<node id>", ...], "source_file": "...", ... }]
}
```

Every node, link, and hyperedge carries `source_file`; links reference
node ids via `source`/`target`; hyperedges reference node ids via `nodes`.
All other top-level keys (`directed`, `multigraph`, `graph`,
`built_at_commit`) pass through unchanged — this pass edits three arrays
and leaves everything else alone.

## `filterGraphFile`

```go
func filterGraphFile(path string, patterns []string) error {
	if len(patterns) == 0 {
		return rewriteGraphFile(path, readGraphFile(path)) // no-op pass, still exercised
	}
	g, err := readGraphFile(path)
	if err != nil {
		return err
	}

	survivingIDs := map[string]bool{}
	keptNodes := g.Nodes[:0]
	for _, n := range g.Nodes {
		if matchesAny(patterns, n.SourceFile) {
			continue
		}
		keptNodes = append(keptNodes, n)
		survivingIDs[n.ID] = true
	}
	g.Nodes = keptNodes

	keptLinks := g.Links[:0]
	for _, l := range g.Links {
		if matchesAny(patterns, l.SourceFile) {
			continue
		}
		if !survivingIDs[l.Source] || !survivingIDs[l.Target] {
			continue // dangling: one endpoint's node was excluded
		}
		keptLinks = append(keptLinks, l)
	}
	g.Links = keptLinks

	keptHyper := g.Hyperedges[:0]
	for _, h := range g.Hyperedges {
		if matchesAny(patterns, h.SourceFile) {
			continue
		}
		remaining := 0
		for _, id := range h.Nodes {
			if survivingIDs[id] {
				remaining++
			}
		}
		if remaining < 2 {
			continue // fewer than two real endpoints is not a graph fact
		}
		keptHyper = append(keptHyper, h)
	}
	g.Hyperedges = keptHyper

	return rewriteGraphFile(path, g)
}
```

`readGraphFile`/`rewriteGraphFile` unmarshal/marshal into a struct that
declares only the fields this pass touches plus a
`json.RawMessage`-typed passthrough for everything else, so unrecognized
top-level keys the binary emits are preserved byte-for-byte rather than
dropped by a struct that doesn't know about them.

## Pattern matching

`matchesAny` needs `.gitignore`-style glob support — `*` for one path
segment, `**` for any number of segments — matched against the
repo-relative `source_file`. Go's standard `path.Match`/`filepath.Match`
does not support `**`. Implement a small, self-contained matcher (segment
split on `/`, `**` consumes zero or more segments, `*`/other segments
match via `path.Match` per-segment) rather than adding a third-party
dependency — this project currently has three direct dependencies
(`mcp-go`, `yaml.v3`, `modernc.org/sqlite`) and a `**`-aware glob is a
small, fully specifiable algorithm, not a reason to add a fourth.

## Rejected alternatives

**Filtering each per-repo graph before merge instead of the merged
result.** Rejected: `source_file` is already repo-relative in both cases,
so filtering once, after merge, is one implementation and one call site
instead of duplicating the same filter per repo for no behavioral
difference.

**Adding a third-party doublestar-glob dependency.** Rejected in favor of
a small hand-written matcher — see "Pattern matching" above.

**Skipping the filter pass entirely when `exclude_patterns` is empty.**
Rejected: this project's established convention (`include_groups` empty
already means "every repo" through the same function, not a bypassed one)
is to always run the real code path with a no-op input, so the path is
exercised by every build, not skipped by most of them.
