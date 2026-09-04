# Install and set up Sergeant v2

This is the supported first-install path for Sergeant v2. Sergeant is a
single-user, local-first Go engine. It does not clone repositories, manage
credentials, or use tmux.

## Install the required tooling

Sergeant's prerequisite check expects these commands to be available on
`PATH`. The commands below are examples for macOS and Debian/Ubuntu Linux;
use the equivalent package-manager command for another platform.

### macOS

Install Homebrew if it is not already present, then install the system tools,
Go, GitHub CLI, and mise:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install bash curl git gh go mise node pipx
pipx ensurepath
```

Install OpenSpec and the GitHub Copilot CLI with npm:

```bash
npm install --global @fission-ai/openspec @github/copilot
```

### Debian or Ubuntu Linux

Install the system tools and Go:

```bash
sudo apt update
sudo apt install --yes bash curl git gh golang nodejs npm pipx
```

Install mise using its official installer, then restart the shell so mise is
available on `PATH`:

```bash
curl https://mise.run | sh
```

Install OpenSpec and the GitHub Copilot CLI with npm:

```bash
npm install --global @fission-ai/openspec @github/copilot
```

### Graphify

Graphify is an optional Sergeant dependency. Install it when the project YAML
contains a `graphify:` block or when you want to build and query a project
code graph. Graphify publishes the `graph.json` and `GRAPH_REPORT.md` files
configured by the project; Sergeant invokes the `graphify` executable and does
not install it automatically.

Install Graphify with `pipx` so its Python dependencies stay isolated:

```bash
pipx install graphifyy
pipx ensurepath
```

Open a new shell if `~/.local/bin` was not already on `PATH`, then verify it:

```bash
graphify --help
command -v graphify
```

Graphify's AST/code-only mode does not require an LLM credential:

```bash
graphify extract /path/to/repository --code-only
```

Full semantic extraction and community labeling may require a provider
credential. Configure the provider and model according to Graphify's own
current documentation; never put API keys in Sergeant project YAML. Sergeant's
Graphify integration uses the `extract`, `merge-graphs`, `query`, `explain`,
and `affected` commands, so the installed executable must provide those
subcommands:

```bash
graphify extract --help
graphify merge-graphs --help
graphify query --help
```

The OpenSpec and Copilot packages require a working Node.js/npm installation.
If your distribution provides an older Node.js version, install a current
LTS release before running the npm command.

### Alternative agent harnesses

Sergeant accepts `opencode`, `oc`, `claude`, `goose`, `codex`, `pi`, or
`copilot`. You only need one. Install the harness you intend to use by
following its vendor's current instructions, then confirm its executable is
on `PATH`:

```bash
command -v opencode || command -v oc || command -v claude ||
  command -v goose || command -v codex || command -v pi ||
  command -v copilot
```

GitHub Copilot CLI is the documented path for this guide and can be installed
with `npm install --global @github/copilot` as shown above.

### Verify the installed tooling

Before cloning or building Sergeant, confirm the required commands resolve:

```bash
go version
git --version
bash --version
mise --version
openspec --version
gh --version
node --version
npm --version
pipx --version
copilot --version
```

If Graphify was installed for a project that uses it, also run
`graphify --help`.

`curl` is used by the API verification examples later in this guide. It is
normally preinstalled on macOS and Linux; install it with the system package
manager if `command -v curl` fails.

## Prerequisites

The required tools are:

- Go 1.21 or newer
- Git
- Bash
- [`mise`](https://mise.jdx.dev/)
- [`openspec`](https://github.com/Fission-AI/OpenSpec)
- [`gh`](https://cli.github.com/) authenticated for repositories you will use
- One supported agent harness: `opencode`, `oc`, `claude`, `goose`, `codex`,
  `pi`, or `copilot`

From the Sergeant checkout, run:

```bash
mise run check
```

The check reports each prerequisite and fails if any required command is
missing. `mise run install` installs the helper symlink and builds
`bin/sergeant`; `mise run build` only builds the Go binary.

```bash
mise run install
# or, without installing the helper symlink:
mise run build
```

If `~/.local/bin` is not already on `PATH`, add it to your shell startup file
as instructed by `mise run install`, then start a new shell.

## Register the first project

Sergeant reads one project file per project from `~/.config/sergeant/`. A repo
must already exist locally and be a Git worktree; Sergeant does not clone it.

```bash
mkdir -p ~/.config/sergeant
cp schema/project.yaml.example ~/.config/sergeant/myproject.yaml
$EDITOR ~/.config/sergeant/myproject.yaml
```

Set `name` to `myproject` and replace every example repository with the actual
repository name and path. Use absolute paths or `~/...` paths. Keep `url` only
as repository metadata; it does not cause automatic cloning.

Start the dashboard from the Sergeant checkout:

```bash
bin/sergeant ui
```

Verify that the project is loaded:

```bash
curl -fsS http://127.0.0.1:8484/api/projects
curl -fsS 'http://127.0.0.1:8484/api/project-details?name=myproject'
```

The project-details response must show every repository's resolved path,
role, group, and inherited instructions. If a path is missing or is not a Git
repository, fix the YAML or local checkout before dispatching.

See [schema.md](schema.md) for all fields and [troubleshooting.md](troubleshooting.md)
for server, authentication, and stale-run problems.

## Use Sergeant from GitHub Copilot CLI

### Authenticate Copilot

Authenticate once before the first agent-driven session:

```bash
copilot login
```

On a remote or headless machine use:

```bash
copilot login --device-code
```

For automation, Copilot also accepts `COPILOT_GITHUB_TOKEN`, `GH_TOKEN`, or
`GITHUB_TOKEN`. Do not put tokens in project YAML, MCP configuration committed
to a repository, or shell history.

Confirm the installed CLI exposes the flags Sergeant uses:

```bash
copilot --version
copilot --help
```

Sergeant's Copilot argv was measured against Copilot CLI v1.0.82. Sergeant
does not currently enforce a minimum Copilot version, so an older CLI must be
checked manually for the flags listed above.

Sergeant invokes Copilot non-interactively with `-p`, `--allow-all-tools`, and
`--no-ask-user`. A requested model is passed as `--model <model>`. Sergeant
sets the process working directory itself; it does not add Copilot's `-C`.

### Register Sergeant as an MCP server

Copilot discovers user MCP configuration from `~/.copilot/mcp-config.json` or
workspace configuration from `.mcp.json` or `.github/mcp.json`. The repository's
root `mcp.json` is a reference configuration for MCP-capable clients; Copilot
does not use that filename as its workspace configuration.

Register the server with an absolute path to the Sergeant binary:

```bash
copilot mcp add sergeant-v2 -- \
  /absolute/path/to/sergeant/bin/sergeant mcp
```

Use the actual path on your machine. The absolute path matters because Copilot
is normally launched from the application repository, where `./bin/sergeant`
would refer to that repository rather than the Sergeant checkout.

Verify registration:

```bash
copilot mcp list
copilot mcp get sergeant-v2
```

The server command must point to the built `sergeant` binary and end with the
`mcp` argument. Start `bin/sergeant ui` separately; the current v2 MCP process
is the agent-facing server and the UI is the dashboard/API process.

### Run an agent-driven session

Launch Copilot from a repository that is registered in the project:

```bash
cd /path/to/registered/repository
copilot -p "Use Sergeant to load the project context, inspect the brief, and report the applicable gates." \
  --allow-all-tools --no-ask-user
```

The agent can use Sergeant MCP tools such as `sergeant_get_brief`,
`sergeant_run_gates`, `sergeant_emit_envelope`, `sergeant_status`, and the
graph query tools. Agent-driven sessions and dashboard dispatches write the
same durable Sergeant records. Sergeant does not host or multiplex the
interactive Copilot session.

For coordinator-driven work, use the dashboard instead. It creates an
isolated worktree and runs bounded headless phases using the configured agent
harness.

## First-install checklist

1. `mise run check` succeeds.
2. `mise run install` or `mise run build` produces `bin/sergeant`.
3. `gh auth status` succeeds for the repositories involved.
4. `copilot --version` is compatible with the documented headless flags.
5. `copilot login` succeeds when Copilot is the selected harness.
6. `~/.config/sergeant/<project>.yaml` names existing Git repositories.
7. `bin/sergeant ui` answers `/api/projects`.
8. `/api/project-details?name=<project>` shows resolved paths and instructions.
9. `copilot mcp list` shows `sergeant-v2` when using Copilot agent-driven work.
