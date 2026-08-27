# Getting Started

This checklist installs Sergeant for one local user and registers a first
project.

## 1. Prerequisites

Required:

- Bash 3.2 or newer
- Git
- GitHub CLI (`gh`), authenticated for repositories you use
- tmux
- `yq`
- Python 3
- `lsof`
- [Marcus td](https://github.com/marcus/td)
- OpenCode, Goose, or Claude Code, used as a persistent interactive worker terminal

Optional:

- `mise` for installation tasks
- `go` 1.21+ to build the MCP server (`sergeant-mcp`)
- Treehouse for leased worktree pools
- Graphify for project knowledge graphs
- no-mistakes for final shipping validation
- Node.js/npm to install external agent skills

Run the repository dependency check after cloning:

```bash
mise run check
```

If `mise` is unavailable, install the required commands with your platform's
package manager, then verify the required commands directly:

```bash
command -v git gh tmux yq python3 lsof
td version
td create --help
agent_found=false
for agent in opencode goose claude; do
  command -v "$agent" >/dev/null && agent_found=true
done
if ! $agent_found; then
  printf 'Install OpenCode, Goose, or Claude before using Sergeant interactive dispatch.\n' >&2
  exit 1
fi
```

Continue only when `td create --help` shows Marcus `td` support for
`--description`, `--json`, and `--work-dir`, and at least one supported agent
resolves on `PATH`.

## 2. Clone and install command links

```bash
git clone https://github.com/callmeradical/sergeant.git
cd sergeant
mise run install
```

By default, installation symlinks commands into `~/.local/bin`. Ensure that
directory is on `PATH`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Verify:

```bash
command -v sgt-list
command -v sgt-context
command -v sgt-dispatch
command -v sgt-watch
```

When commands are not installed on `PATH`, run them from this checkout as
`bin/<command>`.

Sergeant does not install harness-specific conversation-injection plugins.
Worker updates are surfaced from durable fleet state through `sgt-watch`.

## 3. Create global configuration

```bash
mkdir -p ~/.config/sergeant
cat > ~/.config/sergeant/config.yaml <<'YAML'
dev_root: ~/Dev
YAML
```

`dev_root` is the base for relative repository paths in project YAML files.

## 4. Register a project

```bash
cp schema/project.yaml.example ~/.config/sergeant/myproject.yaml
```

Edit the copy so:

- `name` matches the filename (`myproject`);
- every repository has a unique name and correct path;
- clone URLs are present for repositories `sgt-sync` may clone;
- roles and groups identify ownership;
- agent instructions contain commands and observable constraints, not vague
  quality slogans;
- `graphify.output`, when used, is one project-level path outside source repos.

Validate the registration:

```bash
sgt-list
sgt-context myproject
sgt-status myproject
```

Clone or refresh configured repositories when needed:

```bash
sgt-sync myproject
```

See [Project YAML schema](schema.md) for every field.

## 5. Initialize task tracking

Sergeant currently expects Marcus `td` in repositories that own tracked work.
Verify the implementation and initialize each repository according to the td
documentation:

```bash
td version
td create --help
td init --work-dir /path/to/repo
td status --json --work-dir /path/to/repo
```

Sergeant requires the Marcus implementation with JSON, task creation, and
`--work-dir` support. A different executable named `td` is rejected.

## 6. Optional worktree pools

```bash
sgt-treehouse-init myproject
```

Run this only for repositories where Treehouse leases are desired. Commit any
repository-owned `treehouse.toml` files through normal review.

## 7. Optional project graph

Configure `graphify.output` in the project YAML, then run:

```bash
sgt-graphify myproject
```

Require both `graph.json` and `GRAPH_REPORT.md` at the configured project output.

## 8. Optional: build the MCP server

`sergeant-mcp` is a Go binary that exposes every `sgt-*` script as an MCP
tool. It runs as one shared backend process per machine: each MCP-compatible
host (Claude Desktop, Cursor, Continue, etc.) actually launches the thin
`sergeant-mcp-client` proxy over stdio, which discovers an already-running
`sergeant-mcp` and connects to it over a Unix socket, or starts one itself if
none is running yet — so N connected host instances share one backend
process instead of each spawning a private one.

### Prerequisites

- Go 1.21 or newer: `go version`
- The repo already contains `go.mod` and `cmd/sergeant-mcp/`; no extra clone is needed.

### Build

```bash
# Quick build for the current OS/arch — output: bin/sergeant-mcp, bin/sergeant-mcp-client
mise run build

# Without mise:
go build -o bin/sergeant-mcp ./cmd/sergeant-mcp/
go build -o bin/sergeant-mcp-client ./cmd/sergeant-mcp-client/

# Cross-compile for all supported platforms (darwin/linux × amd64/arm64)
mise run build:all
# Output: dist/{sergeant-mcp,sergeant-mcp-client}-{os}-{arch}
```

Verify:

```bash
./bin/sergeant-mcp --version
./bin/sergeant-mcp-client --version
```

### Connect to an MCP host

The repository ships `mcp.json` at the root — an [Agent Plugins](https://agent-plugins.org)
manifest that points to `./bin/sergeant-mcp-client`. MCP hosts that
auto-discover `mcp.json` will pick it up automatically after you build both
binaries.

For hosts that require manual configuration add a stdio server entry:

```json
{
  "mcpServers": {
    "sergeant": {
      "type": "stdio",
      "command": "/path/to/sergeant/bin/sergeant-mcp-client"
    }
  }
}
```

Both binaries must remain in `bin/` (the same directory as the `sgt-*`
scripts): the server resolves script paths relative to itself, and the
client looks there for a sibling `sergeant-mcp` to start on demand.

### Available tools

`sergeant-mcp` registers 29 tools — one per public `sgt-*` script plus
`wiki-daily-digest`. Each tool accepts an `args` string (shell-quoted CLI
arguments) and, for `sgt-respond`, an optional `stdin` string. Run
`./bin/sergeant-mcp --list-tools` to see the full list with descriptions.

### Notes

- The binary is not included in GitHub releases; build it from source with
  `go build` or `mise run build`.
- `CGO_ENABLED=0` is set by default for a statically linked binary.
- Commands that require an interactive TTY (`sgt-interactive-worker`,
  `sgt-validation-worker`) emit a warning when called via MCP.

## 9. Install engineering skills

Sergeant-generated worker briefs already discover their required workflow skills
from this repository's vendored `.agents/skills/` tree. See
[Repo-scoped worker skills](repo-scoped-skills.md) for the canonical inventory.

Additional engineering skills you choose to install locally should still follow
[Skills and their sources](skills.md). Sergeant's project orchestration skills
ship in this repository.

## 9. Launch Sergeant

Start the coordinator from the Sergeant checkout in tmux so `AGENTS.md` is loaded
and dispatch can bind the exact coordinator identity:

```bash
tmux new-session -s sergeant-coordinator 'opencode --dangerously-skip-permissions'
# or: tmux new-session -s sergeant-coordinator 'goose session'
# or: tmux new-session -s sergeant-coordinator claude
```

First checks:

```text
load context for myproject
show the open task queue
explain which repository owns <feature>
```

If a dispatched worker's pane disappears but its td task is still open, use `sgt-session-resume <project> <repo>` before dispatching a replacement; it restores the agent in the existing worktree without duplicating work.

Terminal workers automatically retire their owned descendant processes on completion; agent, shell, and sleep processes started during a session are cleaned up when the worker finishes.

## Completion checklist

- [ ] Required commands resolve on `PATH` or through `bin/`
- [ ] The coordinator runs in a tmux pane
- [ ] `sgt-list` shows the project exactly once
- [ ] `sgt-context` resolves every owning repository and instruction layer
- [ ] Required repositories are cloned
- [ ] Marcus td is installed with create/json/work-dir support and initialized
- [ ] GitHub CLI can access required repositories
- [ ] Optional Treehouse/Graphify features pass their verification commands
- [ ] Required repo-scoped worker skills are present and any extra installed skills come from reviewed sources
