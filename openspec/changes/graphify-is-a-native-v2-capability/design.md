# Design — Graphify is a native v2 capability

## Ownership

One repository, `sergeant-v2`. Standalone — does not depend on any R5 bullet
and nothing depends on it yet.

## `graphify` the binary is an external tool, like `goose` or `git`

Confirmed present at `/Users/lars/.local/bin/graphify` (`graphify --help`
lists `extract`, `merge-graphs`, `query`, `explain`, `affected`, and many
more subcommands). v1's `sgt-graphify` is bash orchestration around this same
binary — it does not implement graph extraction itself. This proposal
replaces the bash orchestration with Go, invoking the identical binary the
same way `internal/runner.BuildAgentCommand` already invokes agent CLIs:
`exec.Command`, captured output, a non-zero exit treated as failure.

## Config

```go
// Graphify declares a project's cross-repository code graph. When set, the
// project can build and publish one via BuildProjectGraph.
type Graphify struct {
	// Output is the directory the merged graph is published to.
	Output string `yaml:"output" json:"output"`
	// IncludeGroups filters which repos participate, matched against each
	// repo's Group. Empty means every repo in the project participates —
	// the same "unset means everything" default other per-repo filters in
	// this config already use.
	IncludeGroups []string `yaml:"include_groups,omitempty" json:"include_groups"`
	// ExcludePatterns is parsed and stored but not yet applied — see
	// proposal.md's out-of-scope section. A future bullet applies it without
	// another config migration.
	ExcludePatterns []string `yaml:"exclude_patterns,omitempty" json:"exclude_patterns"`
}
```

Added to `config.Project` as `Graphify *Graphify` (a pointer: a project that
declares no `graphify:` block has one, `nil`, distinguishable from a project
that declares an empty block).

## `internal/graphify.BuildProjectGraph`

```go
// BuildProjectGraph builds a graph for each repo in proj that participates
// (per Graphify.IncludeGroups), merges them into one cross-repository graph,
// and publishes the result atomically to Graphify.Output.
//
// "Atomically" means: every artifact is written into a scratch directory
// first; only once every expected artifact exists and is non-empty does a
// single directory rename move the scratch directory into place at Output.
// A reader of Output never observes a partially-written graph — the same
// property sgt-graphify's bash implementation already guarantees, structured
// as Go instead of a shell script.
func BuildProjectGraph(proj *config.Project) error
```

Steps:
1. Resolve participating repos: every repo in `proj.Repos` if
   `IncludeGroups` is empty, otherwise only those whose `Group` is in
   `IncludeGroups`.
2. For each participating repo, run `graphify extract <repo.Path> --out
   <scratch>/<repo-name>` (`exec.Command`, captured combined output, treat a
   non-zero exit as a failed build — do not guess at what `graphify extract`
   does without an LLM API key configured; observe its actual behavior in
   this dispatch environment and let its own exit status decide success,
   exactly like every agent-CLI invocation in `internal/runner` already
   does).
3. Run `graphify merge-graphs <each repo's graph.json...> --out
   <scratch>/graph.json`.
4. Verify `<scratch>/graph.json` exists and is non-empty. Write a small
   manifest (repo names, timestamp) to `<scratch>/manifest.json`.
5. `os.Rename(scratch, Output)` (removing any prior `Output` first, since
   `os.Rename` onto an existing non-empty directory fails on most
   filesystems — remove-then-rename is still atomic with respect to a reader
   only ever seeing a complete prior version or a complete new one, never a
   partial one, because the remove and the rename are the only two
   operations touching `Output` and nothing reads mid-sequence in this
   single-writer flow).

A single participating repo with zero repos to extract (empty project, or an
`IncludeGroups` matching nothing) is an error, not a silently empty
"success" — an operator who declared a graphify block and got nothing needs
to know that, not infer it from an empty output directory.

## MCP tools are thin subprocess wrappers

```go
{Name: "sergeant_graph_query", ...}     // -> graphify query "<question>" --graph <Output>/graph.json
{Name: "sergeant_graph_explain", ...}   // -> graphify explain "<node>" --graph <Output>/graph.json
{Name: "sergeant_graph_affected", ...}  // -> graphify affected "<node>" --graph <Output>/graph.json
```

Each resolves the project's `Graphify.Output` from its config, checks
`graph.json` exists there (a clear "no graph built for this project yet"
error if not — not a crash, not a silent empty result), then runs the
matching `graphify` subcommand and returns its stdout as the tool result.
No parsing of the graph's own JSON structure is needed in Go for this
task — `graphify` already answers the question in each case.

## `POST /api/build-graph`

Body `{"project": "..."}`. Loads the project config, 400 if it has no
`Graphify` block, calls `BuildProjectGraph`, 500 with the error on failure,
200 with `{"status": "built", "output": "<path>"}` on success. Follows
`internal/ui/server.go`'s existing route/response conventions exactly.

## Rejected alternatives

**Reimplementing extraction/graph algorithms in Go.** Rejected in
`proposal.md`'s scoping-correction section — `graphify` the binary already
does this, well, and D7/D9 do not ask for it to be rewritten.

**Applying `exclude_patterns` in this bullet.** v1's approach (stage a
filtered copy of each repo via tar-exclude before extraction) is real
additional mechanism this task would have to build and test correctly on top
of everything else here; deferring it, disclosed, keeps this bullet to one
honestly-scoped vertical slice rather than two bundled into one dispatch.

**A background/scheduled graph rebuild.** Out of scope per `proposal.md` —
D9's text describes the build-and-publish mechanism and the query surfaces
over it, not a triggering policy.
