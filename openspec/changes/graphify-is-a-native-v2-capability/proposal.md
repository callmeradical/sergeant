# Proposal — Graphify is a native v2 capability

## Repository

One repository: `sergeant-v2`.

## Requirement served

**D9** (decision, not a numbered R-requirement): "A project may declare a
`graphify:` block (`output`, `include_groups`, `exclude_patterns`). The
system builds a graph per repository, merges them into one cross-repository
graph, and publishes it atomically to the configured output. It must not
call `sgt-graphify` (D7). The graph is exposed to agents over MCP as query,
affected and explain tools, so a dispatched agent navigates by graph rather
than by grepping files." Today the block is parsed and discarded:
`config.Project` has no `Graphify` field.

## What "native" actually means here — a scoping correction

D7 forbids shelling out to `sgt-graphify` (v1's bash orchestrator) and v1's
fleet layout — it does not forbid calling an external binary at all, any more
than v2 running `goose` or `git` as a subprocess makes those parts of v2 "not
native." Research this session confirmed `sgt-graphify`
(`/Users/lars/Dev/sergeant/bin/sgt-graphify`) is itself a thin bash wrapper
around a separate, general-purpose, already-installed CLI tool (`graphify`,
at `/Users/lars/.local/bin/graphify` on this machine) that does the actual
parsing, LLM-assisted extraction, and graph algorithms. That tool is real
infrastructure already present, not something to reimplement in Go.

So "native" means: **v2's own Go code owns the orchestration, configuration,
and publication — replacing the bash — while still invoking `graphify` the
binary as an external tool**, the same relationship `internal/runner`
already has with `goose`/`claude`/`codex`. Rewriting `graphify`'s AST/LLM
extraction and graph algorithms in Go would be reimplementing working
infrastructure for no benefit D9 asks for, and is explicitly not this
proposal.

Also relevant: `graphify`'s CLI already has direct commands matching all
three requested MCP operations — `graphify query "<question>"`, `graphify
explain "<node>"`, and `graphify affected "<node>"` (reverse-dependency
traversal) all exist today, confirmed via `graphify --help`. The three MCP
tools this proposal adds are thin wrappers over these three commands against
the graph this proposal's orchestrator publishes, not new graph algorithms.

## Problem

`config.Project` has no `Graphify` field, so a project's `graphify:` YAML
block survives only because config saving patches the YAML node tree rather
than reserializing a typed struct — the block is inert. There is no code
path anywhere in `internal/` that builds, merges, or publishes a graph, and
no MCP tool exposes one.

## Proposal

Add `config.Project.Graphify` (`Output`, `IncludeGroups []string`). A new
`internal/graphify` package: `BuildProjectGraph(proj *config.Project) error`
runs `graphify extract <repo-path> --out <scratch>` for each repo whose
`Group` is in `IncludeGroups` (all repos, if unset — matching how other
per-repo filters in this config default to "everything" when the operator
names nothing), then `graphify merge-graphs <scratch-graphs...> --out
<scratch>/graph.json`, then publishes atomically: stage in a scratch
directory, verify the merged graph and a manifest are both non-empty, then
one directory rename into `Graphify.Output` — the same
stage-verify-then-rename shape `sgt-graphify` already uses, reimplemented in
Go rather than bash.

Add three MCP tools to `internal/mcp/server.go`, following the existing
`[]Tool{...}`/`executeTool` pattern: `sergeant_graph_query`,
`sergeant_graph_explain`, `sergeant_graph_affected` — each a thin subprocess
wrapper around the matching `graphify` subcommand, pointed at the project's
published `graph.json`.

## Out of scope

- **`exclude_patterns`.** v1 implements this by staging a filtered copy of
  each repo (tar-exclude globs) before extraction. This proposal parses and
  stores the field (so a future bullet can implement it without another
  config migration) but does not yet apply it — every repo in scope is
  extracted in full. Disclosed here, not silently dropped.
- **LLM backend selection, `--code-only`/AST-only fallback behavior, and any
  other `graphify extract` flag beyond `--out`.** This dispatch environment
  (the launchd-run sergeant UI server) sets no LLM API key in its
  environment; `graphify extract`'s actual behavior with none configured is
  something the implementing task must observe empirically (run it, see what
  happens) rather than something this proposal predicts. Whatever
  `graphify extract <path> --out <dir>` does by default is what this
  orchestrator gets — no flag is added to force a particular mode.
- **`GRAPH_REPORT.md` / clustering / community labeling** (`graphify
  cluster-only`). v1 generates this; this proposal does not, since D9's text
  does not ask for a human-readable report, only a graph and query surfaces
  over it.
- **`graphify watch`, `graphify add`, the global graph, or any interactive
  skill workflow.** D9 describes a per-project build-and-publish step, not a
  live-updating or cross-project graph.
- **Triggering the build automatically** (e.g. on every dispatch, or on a
  schedule). This proposal adds one explicit trigger — `POST
  /api/build-graph`, following this codebase's existing convention that the
  HTTP API is the shared substrate a CLI or dashboard button would call
  (the same reasoning `dashboard-shows-delivery-history-and-quarantine`
  used) — not an automatic one wired into the dispatch lifecycle.
- Any CLI subcommand binary or dashboard UI button for graphify. The API
  endpoint is the substrate either would call; building either on top of it
  is separate scope.
