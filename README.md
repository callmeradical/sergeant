# Sergeant

A project-aware first mate for working across multi-repo projects.

## Genesis

Sergeant was directly inspired by [firstmate](https://github.com/kunchenguid/firstmate) — an agent distro for running a crew of autonomous agents. Firstmate showed that the right unit of distribution is not a CLI tool or an MCP server, but a cloned directory of instructions, skills, and conventions that turns a general-purpose agent into a specialist.

Sergeant takes that idea and narrows the focus: instead of orchestrating a crew of agents across arbitrary tasks, it starts with the project topology. A project is a named collection of repositories. Everything — context, instructions, dispatch, graphify output — flows from that definition. Where firstmate asks "how do I run a crew?", Sergeant asks "what does this project look like, and how do I work across all of it?"

If you want a general-purpose multi-agent crew orchestrator, use firstmate. If you want your agent to deeply understand your specific projects, their repos, and how they relate — use Sergeant.

---

## What it is

You have a project. It has four repos: an API, a frontend, an infra chart, and a shared library. You open your agent and start working — but the agent has no idea these repos are related, what tooling each uses, or which one needs to change first when you add a new feature.

Sergeant fixes that. It is a Go-native engine (`sergeant`) plus an
`AGENTS.md` and skills that turn a general-purpose agent into a
project-aware first mate. Either dispatch work from its embedded
dashboard, or launch your own agent harness inside a registered
project and let it talk to Sergeant directly — either way, Sergeant
knows your projects, their repos, how they group, and what instructions
apply to each one.

## Mental model

```
~/.config/sergeant/           ← project registry (one YAML per project)
  smith.yaml
  myapp.yaml

~/Dev/smith/                  ← your repos
  smith-api/
  smith-app/
  smith-infra/

sergeant/                     ← this checkout (you are here)
  AGENTS.md
  skills/                     ← agent-loaded skills
  cmd/sergeant/               ← the engine binary
```

Each project is a YAML file. That file defines which repos belong to it, how they group, where Sergeant publishes the merged graphify output, and what agent instructions apply — per group and per repo.

## Quick start

```bash
git clone https://github.com/callmeradical/sergeant
cd sergeant

# Register a project
mkdir -p ~/.config/sergeant
cp schema/project.yaml.example ~/.config/sergeant/myproject.yaml
# Edit it — set your repo names and absolute paths on disk

# Build and start the engine, opening its dashboard, or launch your own
# agent harness inside a repo and let it talk to Sergeant over MCP —
# see AGENTS.md's "Two ways in" for both paths.
mise run build
bin/sergeant ui
```

Then talk to it:

```
> load context for myproject
> what repos are in this project?
> go work on smith-api
> add feature X across all repos
```

## Documentation

Start with the [documentation index](docs/README.md), which is the
current, maintained map of what's v2-native versus historical. In brief:

- [Architecture overview](docs/architecture.md)
- [PRD: Sergeant v2](docs/prd-sergeant-v2.md) — binding requirements and settled decisions
- [Repo-scoped worker skills](docs/repo-scoped-skills.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Project YAML schema](docs/schema.md)

v1's usage docs (what Sergeant is, getting started, skill sources, using
Sergeant) described the removed `sgt-*` shell toolbelt throughout and have
been archived to [`docs/archive/v1/`](docs/archive/v1/) rather than left
live and stale — see `docs/README.md`'s "Not yet written for v2" section.

## Project YAML

Projects live at `~/.config/sergeant/<name>.yaml`. `path` is an absolute
path on disk (`~` expands to `$HOME`); v2 does not clone a repo for you —
the path must already exist.

```yaml
name: myapp
description: My SaaS — Go API, SvelteKit frontend, Helm infra.

repos:
  - name: myapp-api
    path: ~/Dev/myapp/myapp-api
    url: git@github.com:myorg/myapp-api.git
    group: backend
    role: Go REST API
    agent_instructions: |
      Go 1.22. Run `go test ./...` before committing.

  - name: myapp-app
    path: ~/Dev/myapp/myapp-app
    url: git@github.com:myorg/myapp-app.git
    group: frontend
    role: SvelteKit frontend

groups:
  backend:
    agent_instructions: |
      All Go. Use golangci-lint.
  frontend:
    agent_instructions: |
      All SvelteKit. Package manager: pnpm.

graphify:
  output: myapp/graphify-out
  include_groups: [backend, frontend]
```

Full schema reference: `docs/schema.md`. Annotated example: `schema/project.yaml.example`.

## Skills

Agent-loaded skills for structured workflows:

| Skill | What it does |
|---|---|
| `skills/load-project` | Load and internalize full project context |
| `skills/cross-repo-work` | Plan and execute changes across multiple repos |
| `skills/dispatch` | Dispatch subagents per repo with worktrees + briefs |

## Requirements

Run `mise run check` after cloning to verify all of the following resolve
on `PATH` — that task is the authoritative, up-to-date source (derived
directly from this engine's own `exec.Command` call sites), so treat it,
not this list, as ground truth if the two ever disagree:

- Go 1.21+ — to build the `sergeant` binary (`mise run build`)
- `git` — worktrees, branches, commits
- `bash` — runs each project's configured quality gates
- [`openspec`](https://github.com/Fission-AI/OpenSpec) — a dispatch resolves to a change before any run, intent, or worktree exists
- `gh` — opening a pull request
- A supported agent harness on `PATH`: `opencode`, `oc`, `claude`, `goose`, `codex`, `pi`, or `copilot`

tmux is explicitly **not** a dependency — v2 does not use it, drive it, or
require it for any command.

## License

MIT
