# Sergeant

A project-aware first mate for working across multi-repo projects.

## Genesis

Sergeant was directly inspired by [firstmate](https://github.com/kunchenguid/firstmate) — an agent distro for running a crew of autonomous agents. Firstmate showed that the right unit of distribution is not a CLI tool or an MCP server, but a cloned directory of instructions, skills, and conventions that turns a general-purpose agent into a specialist.

Sergeant takes that idea and narrows the focus: instead of orchestrating a crew of agents across arbitrary tasks, it starts with the project topology. A project is a named collection of repositories. Everything — context, instructions, dispatch, graphify output — flows from that definition. Where firstmate asks "how do I run a crew?", Sergeant asks "what does this project look like, and how do I work across all of it?"

If you want a general-purpose multi-agent crew orchestrator, use firstmate. If you want your agent to deeply understand your specific projects, their repos, and how they relate — use Sergeant.

---

## What it is

You have a project. It has four repos: an API, a frontend, an infra chart, and a shared library. You open your agent and start working — but the agent has no idea these repos are related, what tooling each uses, or which one needs to change first when you add a new feature.

Sergeant fixes that. It is an **agent distro**: a cloned directory with an `AGENTS.md`, shell toolbelt, and skills that turn a general-purpose agent into a project-aware first mate. Launch your agent harness inside it and Sergeant takes over — it knows your projects, their repos, how they group, and what instructions apply to each one.

No install. The cloned repo is the distro.

## Mental model

```
~/.config/sergeant/           ← project registry (one YAML per project)
  config.yaml                 ← global config (dev_root)
  smith.yaml
  myapp.yaml

~/Dev/smith/                  ← your repos
  smith-api/
  smith-app/
  smith-infra/

sergeant/                     ← this distro (you are here)
  AGENTS.md
  bin/                        ← cross-repo shell toolbelt
  skills/                     ← agent-loaded skills
```

Each project is a YAML file. That file defines which repos belong to it, how they group, what graphify output to use, and what agent instructions apply — per group and per repo.

When you use `sgt-graphify`, each `repos[].name` must match `[A-Za-z0-9._-]+`.

## Quick start

```bash
git clone https://github.com/callmeradical/sergeant
cd sergeant

# Set your dev root and create the config directory
mkdir -p ~/.config/sergeant
cat > ~/.config/sergeant/config.yaml << 'EOF'
dev_root: ~/Dev
EOF

# Register a project
cp schema/project.yaml.example ~/.config/sergeant/myproject.yaml
# Edit it — set your repo names and paths relative to dev_root

# Launch your agent harness — AGENTS.md takes over from here
opencode    # or: claude
```

Then talk to it:

```
> load context for myproject
> what repos are in this project?
> go work on smith-api
> add feature X across all repos
```

## Project YAML

Projects live at `~/.config/sergeant/<name>.yaml`. Paths are relative to `dev_root`.

```yaml
name: myapp
description: My SaaS — Go API, SvelteKit frontend, Helm infra.

repos:
  - name: myapp-api
    path: myapp/myapp-api         # resolved as $dev_root/myapp/myapp-api
    url: git@github.com:myorg/myapp-api.git
    group: backend
    role: Go REST API
    agent_instructions: |
      Go 1.22. Run `go test ./...` before committing.

  - name: myapp-app
    path: myapp/myapp-app
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

## Toolbelt

Shell scripts for the agent (and for you directly):

| Script | What it does |
|---|---|
| `bin/sgt-list` | List all known projects |
| `bin/sgt-status <project>` | Git status across every repo |
| `bin/sgt-sync <project>` | Clone missing repos, pull existing ones |
| `bin/sgt-context <project>` | Emit full agent context block for a project |
| `bin/sgt-graphify <project>` | Run graphify across all repos → knowledge graph |
| `bin/sgt-dispatch <project> "<brief>" [options]` | Dispatch agents across repos |
| `bin/sgt-no-mistakes-finding <project> <repo> [options]` | Route a no-mistakes finding to a gate, td, ignore, or user escalation |
| `bin/sgt-watch <task-id>` | Monitor dispatched fleet |
| `bin/sgt-respond <task-id> <repo> "<response>"` | Respond to and resume a waiting worker |
| `bin/sgt-cleanup <task-id>` | Remove worktrees and fleet state |
| `bin/sgt-treehouse-init <project>` | Initialize treehouse pools in a project's repos |

### Deferred no-mistakes findings

Dispatched workers use `sgt-no-mistakes-finding` at no-mistakes gates. The required `--disposition` is explicit per finding: `gate` retains blocking work, `td` creates or updates actionable debt in the owning repo, `ignore` records that no card is needed, and `ask-user` preserves human escalation. Warning debt becomes P2, informational debt becomes P3, and repeated finding IDs update the same card while retaining the latest run ID, head SHA, location, description, and originating intent.

On rerun, visible active cards stay in their current state, while explicitly hidden states are resurfaced: closed cards are reopened and deferred cards are undeferred before the finding body is refreshed.

Correctness, security, data-integrity, and test findings cannot be deferred or ignored. Cosmetic and evidence-only findings never create cards.

## Skills

Agent-loaded skills for structured workflows:

| Skill | What it does |
|---|---|
| `skills/load-project` | Load and internalize full project context |
| `skills/cross-repo-work` | Plan and execute changes across multiple repos |
| `skills/dispatch` | Dispatch subagents per repo with worktrees + briefs |

## Requirements

- `td` — task CLI, required for brief-based `sgt-dispatch` runs, `sgt-no-mistakes-finding`, and `sgt-td-*` commands
- `yq` — YAML parser: `brew install yq`
- `git` and `gh` — for repo operations and PRs
- `tmux` — for local agent dispatch
- `treehouse` — pre-warmed worktree pools (optional but recommended for dispatch)
- `graphify` — knowledge graph generation (optional, needed for `sgt-graphify`)
- `babydriver` — remote dispatch to cleanthes (optional)
- A supported agent harness: OpenCode or Claude Code

## License

MIT
