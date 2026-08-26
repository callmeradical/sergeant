# Tasks — Graphify is a native v2 capability

One repository, `sergeant-v2`, so one task.

## Task 1 — config, native orchestrator, and MCP query surfaces

Repository: `sergeant-v2`. Depends on: nothing. The `graphify` binary is
already installed on this machine at `/Users/lars/.local/bin/graphify` and is
on `PATH` in the dispatch environment — confirm this yourself first with
`graphify --help` before writing any code, and read its actual `extract`,
`merge-graphs`, `query`, `explain`, and `affected` subcommand behavior
(`graphify --help` lists all subcommands and their flags in one place). Do
not guess at flag names or output format; confirm them against the real
binary.

- Add `config.Graphify` (`Output string`, `IncludeGroups []string`,
  `ExcludePatterns []string`, YAML tags `output`, `include_groups`,
  `exclude_patterns`) and `config.Project.Graphify *Graphify` (a pointer, so
  "no block declared" is `nil`, distinguishable from an empty block) to
  `internal/config/config.go`.
- Add a new package `internal/graphify` with `BuildProjectGraph(proj
  *config.Project) error`:
  - Resolve participating repos: all of `proj.Repos` if
    `proj.Graphify.IncludeGroups` is empty, otherwise only repos whose
    `Group` is in that list.
  - Error immediately if there are zero participating repos — this is a
    misconfiguration, not a valid empty build.
  - For each participating repo, run `graphify extract <repo.Path> --out
    <scratch>/<repo-name>` via `exec.Command`, capturing combined output;
    a non-zero exit is a failed build, returned with the captured output in
    the error (matching how `internal/runner` reports agent-CLI failures).
    Observe empirically what `graphify extract` actually does in this
    environment (no LLM API key is set here) and let its own exit status be
    the source of truth — do not add flags or environment variables to force
    a particular extraction mode unless the binary requires one to complete
    at all.
  - Run `graphify merge-graphs <each repo's produced graph.json...> --out
    <scratch>/graph.json`.
  - Verify `<scratch>/graph.json` exists and is non-empty; write
    `<scratch>/manifest.json` (repo names, a timestamp).
  - Publish atomically: remove any prior directory at `proj.Graphify.Output`,
    then `os.Rename(scratch, proj.Graphify.Output)`.
- Add `POST /api/build-graph` to `internal/ui/server.go`: body
  `{"project": "..."}`, loads the project via the existing
  `config.LoadProject`, 400 if the project has no `Graphify` block, calls
  `graphify.BuildProjectGraph`, 500 with the error on failure, 200 with
  `{"status": "built", "output": "<Graphify.Output>"}` on success. Register
  alongside the other `/api/*` routes.
- Add three MCP tools to `internal/mcp/server.go`'s existing `[]Tool{...}`
  literal and `executeTool` switch: `sergeant_graph_query`,
  `sergeant_graph_explain`, `sergeant_graph_affected`. Each resolves the
  named project's `Graphify.Output`, returns a clear "no graph built for
  this project" error if `graph.json` does not exist there (do not run the
  underlying `graphify` command against a missing graph and surface whatever
  cryptic error it produces instead), otherwise runs the matching
  subcommand (`graphify query "<question>" --graph <output>/graph.json`,
  `graphify explain "<node>" --graph ...`, `graphify affected "<node>"
  --graph ...`) and returns its stdout as the tool result.
- Do not implement `exclude_patterns` application, LLM backend/mode
  selection beyond observing the binary's default behavior,
  `GRAPH_REPORT.md`/clustering, `graphify watch`/`add`/global-graph, or any
  automatic build trigger. Do not add a CLI binary or dashboard UI element.

Verification: `go build ./... && go vet ./... && go test ./internal/... -count=1`.
For the tests that exercise `BuildProjectGraph` against the real `graphify`
binary (this is real infrastructure already on the machine, not something to
mock — the whole point of this bullet is that v2 shells out to it for real),
use a minimal test repository (a temp dir with one or two trivial files,
`git init`'d if `graphify extract` requires a git repo — confirm whether it
does) so extraction completes quickly regardless of which mode `graphify`
runs in without an LLM key configured. Tests must cover every scenario in
`specs/project-graph/spec.md`: a project's graphify block parses into typed
fields; a project without one has an absent (nil), not zero-value,
configuration; building a graph for a multi-repo project reflects all
participating repos; `include_groups` correctly excludes non-matching repos;
zero participating repos is a build error; a build never leaves `Output` in
a partial state observable by a concurrent reader (a reasonable test: start
a build, and — if `BuildProjectGraph`'s steps are fast enough that this is
hard to observe directly — at minimum assert that `Output` still contains
the complete prior graph's content until the rename, not a directory
half-populated with the new build's scratch files); no `sgt-graphify`
process is ever spawned (grep the implementation, and/or assert on the exact
`exec.Command` invocations made, e.g. via a thin seam that records commands
in a test); an MCP query/explain/affected call against a built graph returns
the underlying `graphify` command's real output; the same three calls against
a project with no graph built yet return a clear "no graph" error, not an
empty or fabricated answer, and do not shell out to `graphify` for a graph
file that does not exist. Exit status decides the outcome.
