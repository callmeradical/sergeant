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
- `lsof`
- [Marcus td](https://github.com/marcus/td)
- OpenCode or Claude Code

Optional:

- `mise` for installation tasks
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
command -v git gh tmux yq lsof
td version
td create --help
```

Continue only when `td create --help` shows Marcus `td` support for
`--description`, `--json`, and `--work-dir`.

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

`mise run install` also links the OpenCode `oc-inject` plugin. Restart the entire
OpenCode process after first installation; creating a new conversation inside an
existing process does not reload plugins.

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

Follow [Skills and their sources](skills.md). Most engineering skills referenced
by Sergeant come from `mattpocock/skills`; Sergeant's project orchestration skills
ship in this repository.

## 9. Launch Sergeant

Start the agent from the Sergeant checkout so `AGENTS.md` is loaded:

```bash
opencode
# or
claude
```

First checks:

```text
load context for myproject
show the open task queue
explain which repository owns <feature>
```

## Completion checklist

- [ ] Required commands resolve on `PATH` or through `bin/`
- [ ] OpenCode was restarted after plugin installation
- [ ] `sgt-list` shows the project exactly once
- [ ] `sgt-context` resolves every owning repository and instruction layer
- [ ] Required repositories are cloned
- [ ] Marcus td is installed with create/json/work-dir support and initialized
- [ ] GitHub CLI can access required repositories
- [ ] Optional Treehouse/Graphify features pass their verification commands
- [ ] Engineering skills are installed from reviewed sources
