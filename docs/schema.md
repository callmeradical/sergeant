# Project YAML Schema

A sergeant project lives at `~/.config/sergeant/<name>.yaml`. The filename (without extension) is the project identifier used by all `sgt-*` commands.

---

## Global config

`~/.config/sergeant/config.yaml` holds machine-wide settings:

```yaml
dev_root: ~/Dev   # root of your development directory

# Optional. Default GitHub CLI identity for all dispatches.
# Overridden by project-level or repo-level identity fields.
# default_identity: callmeradical
```

All scripts read `dev_root` at startup. Repo `path` values that are not absolute (`/...`) or home-relative (`~/...`) are resolved relative to `dev_root`. This makes project YAMLs portable across machines — change `dev_root` in one place instead of every path in every YAML.

**Path resolution examples** (with `dev_root: ~/Dev`):

| YAML path | Resolved to |
|---|---|
| `smith/ascend-arch-smith` | `~/Dev/smith/ascend-arch-smith` |
| `~/Dev/smith/ascend-arch-smith` | `~/Dev/smith/ascend-arch-smith` (unchanged) |
| `/opt/repos/myapp` | `/opt/repos/myapp` (unchanged) |

---

## Top-level fields

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | string | yes | Project identifier. Must match the filename. |
| `description` | string | no | Human-readable description of the project. |
| `repos` | list | yes | Ordered list of repositories in this project. |
| `groups` | map | no | Logical groupings of repos, with shared instructions and optional descriptions that Sergeant can use for review routing. |
| `graphify` | map | no | Configuration for cross-repo knowledge graph generation. |
| `defaults` | map | no | Default values applied to every repo. |
| `identity` | string | no | GitHub CLI user for `gh auth switch` before dispatching. Overrides `config.default_identity`. Per-repo `identity` overrides this. |

---

## `repos[]` fields

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | string | yes | Short identifier for this repo. Used in output and context blocks. For `sgt-graphify`, it must match `[A-Za-z0-9._-]+`, cannot contain spaces, and cannot be `.` or `..`, so Sergeant can safely prefix merged source paths with it. |
| `path` | string | yes | Path on disk. Absolute (`/...`) and home-relative (`~/...`) paths pass through. Relative paths are resolved from `dev_root` in `config.yaml`. |
| `url` | string | no | Git remote URL. Used by `sgt-sync` to clone if path doesn't exist. |
| `group` | string | no | Group name this repo belongs to. Must match a key in `groups`. |
| `role` | string | no | Human description of this repo's role in the project. Sergeant includes it in worker context and review routing. |
| `agent_instructions` | string | no | Instructions injected into agent context when working in this repo. Overrides group-level instructions for the same repo and participates in merged review-routing context. |
| `identity` | string | no | GitHub CLI user for `gh auth switch` before dispatching this repo. Overrides project-level `identity` and `config.default_identity`. Resolution order: `repo.identity` → `project.identity` → `config.default_identity` → no-op. |

---

## `groups` fields

Each key under `groups` is a group name. Value is a map with:

| Field | Type | Required | Description |
|---|---|---|---|
| `description` | string | no | Human-readable description of this group. Sergeant also includes it when classifying UI-facing work for accessibility review routing. |
| `agent_instructions` | string | no | Instructions inherited by all repos in this group. Repo-level `agent_instructions` override this, and the merged instructions participate in review routing. |

---

## `graphify` fields

| Field | Type | Required | Description |
|---|---|---|---|
| `output` | string | yes | Published output directory for the merged project graph. A trailing `/` is allowed. If this path is a directory symlink, `sgt-graphify` preserves the symlink and publishes into its target. Sergeant only replaces the published graph after a complete run and preserves existing `wiki/` and `memory/` directories. |
| `include_groups` | list | no | Only graph repos belonging to these groups. Default: all repos. |
| `exclude_patterns` | list | no | Glob patterns to exclude from graphify traversal (e.g., `**/node_modules/**`). Sergeant applies them before `graphify extract`, so they keep working with current Graphify CLIs that do not accept exclude flags. If `graphify.output` lives inside a source repo, Sergeant stages extraction outside that repo and excludes the configured output path so published graph artifacts are never re-ingested as source. |

---

## `defaults` fields

| Field | Type | Description |
|---|---|---|
| `agent_instructions` | string | Baseline instructions for every repo. Applied first; group and repo levels override, and the merged instructions participate in review routing. |

---

## Instruction layering

Agent instruction prose is concatenated in this order:

1. `defaults.agent_instructions` — applies to all repos
2. `groups.<group>.agent_instructions` — applies to all repos in that group
3. `repos[].agent_instructions` — applies to a specific repo

`sgt-context` emits every nonempty layer in one block. Later layers appear later
in the block; when directives conflict, the later repository-specific directive
is the intended authority. Sergeant does not structurally merge or deduplicate
free-form instruction prose, but `sgt-dispatch` still classifies review routing
from a single normalized in-memory context built from the mission, repo role,
repo group name, repo group description, and merged default/group/repository
instructions.

---

## Path resolution

1. Absolute paths (`/...`) — used as-is.
2. Home-relative paths (`~/...`) — `~` expanded to `$HOME`.
3. Relative paths — resolved from `dev_root` (`~/.config/sergeant/config.yaml`). Default `dev_root` is `~/Dev` if no config exists.

Use relative paths in project YAMLs for portability. Use absolute paths when a repo lives outside your `dev_root`.
