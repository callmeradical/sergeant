# Proposal — Graphify `exclude_patterns` is honored

## Repository

One repository: `sergeant-v2`.

## Requirements served

**D9**: "A project may declare a `graphify:` block (`output`,
`include_groups`, `exclude_patterns`)." `config.Graphify.ExcludePatterns`'s
own doc comment discloses: "parsed and stored but not yet applied by
`BuildProjectGraph`."

PRD: `docs/prd-graphify-exclude-patterns.md`.

## Problem

`BuildProjectGraph` (`internal/graphify/graphify.go`) never reads
`proj.Graphify.ExcludePatterns`. A project owner can declare exclude
patterns, save them, see no error, and get a published graph that still
contains every file from every participating repository. `include_groups`
(repo-level filtering) works; there is no file-level filtering at all
today.

The real `graphify` binary this package orchestrates (D9: "does not
reimplement graph algorithms") has no exclude/ignore flag on its `extract`
subcommand — confirmed against its actual `--help` output. Filtering
cannot be achieved by passing a flag through; it must happen on sergeant's
side, over the graph data the binary already produced. This is consistent
with D9's boundary: filtering already-extracted nodes/edges by file path is
orchestration-side data handling, not a reimplementation of extraction or
graph algorithms.

A real built graph's shape (`graph.json`) gives every node, link, and
hyperedge its own repo-relative `source_file` field — exactly what
`exclude_patterns` needs to match against.

## Proposal

Filter the merged graph once, in the scratch directory, before the
existing atomic-publish step (this project's D9 crash-safety fix): drop
every node, link, and hyperedge whose `source_file` matches a configured
exclude pattern, then drop anything left referencing a node that no longer
exists. An empty `exclude_patterns` list is a no-op that still runs the
filter code path (not a bypassed branch), matching this project's existing
`include_groups`-empty-means-everything convention.

Query/explain/affected (the existing MCP graph tools, D9) need no changes:
they read the published `graph.json`, which is already filtered.

## Out of scope

- **Reconciling or unifying `include_groups` and `exclude_patterns`.**
  They remain two independent filters — repository-level and file-level —
  and stay that way.
- **Excluding by anything other than file path** (node type, language,
  confidence score). This field filters by path only, matching its name.
- **Filtering per-repo before merge instead of on the merged result.**
  Filtering the merged graph once is the chosen mechanism.
- **Any change to the externally maintained `graphify` binary.** No fork,
  no patch, no upstream request.
