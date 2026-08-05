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
- Treehouse for leased worktree pools
- Graphify for project knowledge graphs
- no-mistakes for final shipping validation
- Node.js/npm to install external agent skills

On macOS with Homebrew, or Linux with `apt-get`, the bootstrap installs every
required entry above plus the optional `mise`, `graphify`, and `no-mistakes`.
It does not install `treehouse` or `dagr`, which have their own installers.
Preview it first, then run it:

```bash
git clone https://github.com/callmeradical/sergeant.git
cd sergeant
./bin/sgt-bootstrap --dry-run
./bin/sgt-bootstrap
```

The bootstrap is safe to rerun and never overwrites an existing command, tool,
or user file; anything already occupying a path Sergeant wants is preserved and
reported as a conflict. Conflicts are reported before the first package is
installed, so a run that cannot finish declines without changing anything.

Sergeant writes to the command directory (`SGT_INSTALL_DIR`, default
`~/.local/bin`) and to this repository, whose git hooks it installs. It writes
nothing under `~/.config/opencode`, `~/.claude`, or `~/.agents` except to remove
the deprecated `oc-inject` plugin link an older checkout created. The
third-party installers it invokes (`mise`, `go`, `uv`) manage their own data
directories.

It does not automate or probe any login; follow the `MANUAL:` actions it reports.

On any other platform, or to check an existing installation, verify without
changing anything. Both read-only modes work everywhere: on a platform without a
supported package manager they report the platform packages as a `MANUAL:` step
and still verify everything else. Neither runs a package manager, an installer,
or an agent harness; the only third-party command either runs is `yq --version`,
to tell Mike Farah's `yq` from the Python package of the same name:

```bash
./bin/sgt-bootstrap --verify-only   # or: mise run verify
```

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

`./bin/sgt-bootstrap` already does this. To install or refresh only the command
links:

```bash
git clone https://github.com/callmeradical/sergeant.git
cd sergeant
mise run install      # or: ./bin/sgt-install
```

Remove them again with `mise run uninstall` (or `./bin/sgt-uninstall`), which
removes only links still pointing into this checkout.

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

## 8. Install engineering skills

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
