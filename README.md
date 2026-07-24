# Sergeant

A single-user, local-first project orchestrator for developers working across
one or more related repositories.

## Genesis

Sergeant was directly inspired by [firstmate](https://github.com/kunchenguid/firstmate) — an agent distro for running a crew of autonomous agents. Firstmate showed that the right unit of distribution is not a CLI tool or an MCP server, but a cloned directory of instructions, skills, and conventions that turns a general-purpose agent into a specialist.

Sergeant takes that idea and narrows the focus: instead of orchestrating a crew
across arbitrary tasks, it starts with project topology. A project is a named
collection of repositories. Context, instructions, dispatch, and Graphify output
flow from that definition.

If you want a shared or general-purpose multi-agent service, use a tool designed
for that deployment model. Sergeant is installed independently by each developer
and keeps registry, credentials, worktrees, workers, and fleet state local.

---

## What it is

You have a project. It has four repos: an API, a frontend, an infra chart, and a shared library. You open your agent and start working — but the agent has no idea these repos are related, what tooling each uses, or which one needs to change first when you add a new feature.

Sergeant fixes that. It is an **agent distro**: a cloned directory with an
`AGENTS.md`, shell toolbelt, documentation, and trigger-loaded skills. Launch an
agent harness inside the checkout so its repository instructions are loaded.

The checkout is the source of truth. `mise run install` optionally symlinks the
commands and OpenCode plugin into user-local locations. Sergeant supports Bash
3.2 and newer, including the system Bash shipped with macOS.

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

Each project is a YAML file. That file defines which repos belong to it, how they
group, where Sergeant publishes the merged Graphify output, and which default,
group, and repository instruction layers are emitted for each repo.

## Quick start

```bash
git clone https://github.com/callmeradical/sergeant
cd sergeant

mise run check
mise run install

# Set your dev root and create the config directory
mkdir -p ~/.config/sergeant
cat > ~/.config/sergeant/config.yaml << 'EOF'
dev_root: ~/Dev
EOF

# Register a project
cp schema/project.yaml.example ~/.config/sergeant/myproject.yaml
# Edit it — set your repo names and paths relative to dev_root

# Launch the coordinator in tmux so dispatch can bind exact ownership
tmux new-session -s sergeant-coordinator 'opencode --dangerously-skip-permissions'
```

Then talk to it:

```
> load context for myproject
> what repos are in this project?
> go work on smith-api
> add feature X across all repos
```

## Documentation

Start with the [documentation index](docs/README.md):

- [What Sergeant is and is not](docs/what-is-sergeant.md)
- [Getting started checklist](docs/getting-started.md)
- [Skills and their upstream sources](docs/skills.md)
- [Using Sergeant](docs/using-sergeant.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Project YAML schema](docs/schema.md)

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
| `bin/sgt-graphify <project>` | Build and publish the merged project graph |
| `bin/sgt-dispatch <project> "<brief>" [--intent-file <path>] [options]` | Dispatch agents with one canonical `.sergeant-intent.md` revision across repos |
| `bin/sgt-no-mistakes-finding <project> <repo> [options]` | Classify a no-mistakes finding and create/update owning-repo td work |
| `bin/sgt-watch <task-id>` | Monitor dispatched fleet |
| `bin/sgt-respond <task-id> <repo>` | Read a response from stdin and resume a waiting worker |
| `bin/sgt-ack-response <task-id> <repo> <response-id>` | Acknowledge consumed response transport from the exact worker pane |
| `bin/sgt-validate <task-id> <repo> [--skip <steps>]` | Run coordinator-owned no-mistakes in a split worker-window pane |
| `bin/sgt-cleanup <task-id>` | Remove worktrees and fleet state |
| `bin/sgt-treehouse-init <project>` | Initialize treehouse pools in a project's repos |

### No-mistakes findings

Routine dispatched workers use repository-native tests, lint/typechecking, and independent Standards/Spec/readiness reviews. They do not run no-mistakes for ordinary completion, prototypes, investigations, documentation drafts, intermediate commits, or remediation loops.

At an explicit final shipping boundary, the worker writes the recorded intent
revision, current HEAD, and passed review-axis evidence to
`.sergeant-validation-ready` after native validation and independent reviews
report zero blockers. The coordinator, not the worker, launches validation:

```bash
sgt-validate <task-id> <repo>
```

The command creates a split pane in the worker window, renames the window to
`validation-<repo>-<task>`, passes the unchanged canonical intent to no-mistakes,
and never uses `--yes`. Use `--skip <steps>` only for gates already proven
irrelevant and stop at `checks-passed`. The run is validation-only: it must not
fix findings. Route actionable findings into separate, deduplicated owning-repo
td tasks with `sgt-no-mistakes-finding`. For launch reservation, rollback
ownership, and retry semantics, see
[`docs/using-sergeant.md`](docs/using-sergeant.md#final-no-mistakes-boundary).

Safety-sensitive/stateful objectives require `sgt-dispatch --intent-file`; other
objectives use the generated `standard-isolated` lighter path. See
[`docs/using-sergeant.md`](docs/using-sergeant.md) for required sections and the
observable classifier.

The required `--disposition` is explicit per finding: `gate` creates or updates P1 work and retains the gate, `ask-user` creates or updates P1 work and preserves human escalation, `td` creates or updates nonblocking actionable debt, and `ignore` records that no card is needed. Warning debt becomes P2, informational debt becomes P3, and repeated finding IDs update the same card while retaining the latest run ID, head SHA, location, description, and originating intent. Reruns also preserve any existing repo-specific or manually added td labels while ensuring the required `no-mistakes` and `finding` labels remain present without duplication.

On rerun, visible active cards stay in their current state, while explicitly hidden states are resurfaced: closed cards are reopened and deferred cards are undeferred before the finding body is refreshed.

`sgt-no-mistakes-finding` accepts only JSON arrays from `td list --json`. Malformed JSON and every non-array JSON type fail closed before any td create, update, reopen, or defer operation.

Correctness, security, data-integrity, and test findings cannot be deferred or ignored. Cosmetic and evidence-only findings never create cards.

### Independent review routing

Generated worker briefs always require separate Standards and Spec reviews. For the authoritative UI-routing triggers and the added accessibility-review contract, see `skills/dispatch/SKILL.md`.

## Skills

Agent-loaded skills for structured workflows:

| Skill | What it does |
|---|---|
| `skills/load-project` | Resolve project registry, paths, instructions, schema, sync, and Graphify procedures |
| `skills/cross-repo-work` | Assign repository ownership and dependency/merge order |
| `skills/dispatch` | Operate td, worktrees, workers, fleets, escalation, review, and cleanup |
| `skills/wiki` | Validate automatic captures and generate curated daily wiki digests |
| `skills/sergeant-help` | Query repository docs for installation, usage, skills, and troubleshooting help |

## Requirements

See the complete [getting started checklist](docs/getting-started.md) for
installation and verification.

- [`github.com/marcus/td`](https://github.com/marcus/td) — task CLI, required for brief-based `sgt-dispatch` runs, `sgt-no-mistakes-finding`, and `sgt-td-*` commands; install with `brew install marcus/tap/td` or `go install github.com/marcus/td@latest`
- `yq` — YAML parser: `brew install yq`
- `git` and `gh` — for repo operations and PRs
- `tmux` — for local agent dispatch
- `lsof` — for verifying cleanup does not remove an in-use worktree
- `treehouse` — pre-warmed worktree pools (optional but recommended for dispatch)
- `graphify` — knowledge graph generation (optional, needed for `sgt-graphify`)
- OpenCode, Goose, or Claude Code for persistent interactive worker dispatch

## License

MIT
