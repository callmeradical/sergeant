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

No install. The cloned repo is the distro. Sergeant supports Bash 3.2 and newer, including the system Bash shipped with macOS.

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

Each project is a YAML file. That file defines which repos belong to it, how they group, where Sergeant publishes the merged graphify output, and what agent instructions apply — per group and per repo.

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

## Documentation

Start with the [documentation index](docs/README.md):

- [What Sergeant is and is not](docs/what-is-sergeant.md)
- [Getting started checklist](docs/getting-started.md)
- [Skills and their upstream sources](docs/skills.md)
- [Repo-scoped worker skills](docs/repo-scoped-skills.md)
- [Using Sergeant](docs/using-sergeant.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Project YAML schema](docs/schema.md)
- [Durable callback protocol](docs/callbacks.md)

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

Full schema reference: `docs/schema.md`. Annotated example: `schema/project.yaml.example`. Detailed documentation: `docs/README.md`.

## Toolbelt

Shell scripts for the agent (and for you directly):

| Script | What it does |
|---|---|
| `bin/sgt-list` | List all known projects |
| `bin/sgt-status <project>` | Git status across every repo |
| `bin/sgt-sync <project>` | Clone missing repos, pull existing ones |
| `bin/sgt-context <project>` | Emit full agent context block for a project |
| `bin/sgt-graphify <project>` | Build and publish the merged project graph |
| `bin/sgt-dispatch <project> "<brief>" [options]` | Dispatch agents across repos |
| `bin/sgt-no-mistakes-finding <project> <repo> [options]` | Classify a no-mistakes finding and create/update owning-repo td work |
| `bin/sgt-review-findings <project> <repo> [options]` | Route structured independent-review findings to td and fleet supervision |
| `bin/sgt-watch <task-id>` | Monitor dispatched fleet |
| `bin/sgt-watch --snapshot [<task-id>] [--repo <repo>]` | Bounded read-only JSON observation of whether Sergeant is verifiably working |
| `bin/sgt-respond <task-id> <repo> "<response>"` | Respond to and resume a waiting worker |
| `bin/sgt-cleanup <task-id>` | Remove worktrees and fleet state |
| `bin/sgt-treehouse-init <project>` | Initialize treehouse pools in a project's repos |
| `bin/sgt-callback <command>` | Operate durable profile-bound callback events |

#### Observing activity without side effects

`sgt-watch --list` renders every retained record, including terminal ones, for a
human reader. `--sync` and `--sync-all` reconcile lifecycle state and may kill
panes. Neither is safe for a coordinator or bridge that only wants to observe.

`sgt-watch --snapshot` is strictly read-only and emits constant-size versioned
JSON:

```console
$ sgt-watch --snapshot
{"schema":"sergeant.watch-status/v1","observed_at":"2026-08-05T17:41:02Z","scope":{"kind":"fleet","task_id":null,"repo":null},"busy":null,"basis":"no_verified_active_witness"}

$ sgt-watch --snapshot my-task --repo app
{"schema":"sergeant.watch-status/v1","observed_at":"2026-08-05T17:41:09Z","scope":{"kind":"repo","task_id":"my-task","repo":"app"},"busy":true,"basis":"verified_active_witness"}
```

`busy: true` requires all three of a stable `in_progress` status, an exact live
Sergeant worker pane identity, and progress attributable to that pane within
`SERGEANT_SNAPSHOT_RECENT_SECONDS` (default 300). Every other outcome is
`busy: null` with `basis: no_verified_active_witness`; version 1 never emits
`busy: false`, because the absence of a verified witness is not proof of
idleness. `basis` is a closed allowlist of those two values, so an unrecognised
condition maps to the null basis rather than inventing one.

### Pinning the worker's model

`sgt-dispatch --agent` (or `SERGEANT_AGENT`) chooses the harness *executable*.
`sgt-dispatch --model` (or `SERGEANT_MODEL`) pins what that harness *runs*. The
two are orthogonal, and precedence is explicit:

```
--model  >  SERGEANT_MODEL  >  the harness's own ambient default
```

The tuple is written `provider/model` with an optional `:variant`. Providers use
`[a-z0-9-]` and models use `[A-Za-z0-9._-]`; a tuple outside that charset is
rejected, which is also why recorded launch evidence can never carry a secret.

```bash
sgt-dispatch smith "Add OAuth" --repos smith --model anthropic/claude-opus-5
SERGEANT_MODEL=openai/gpt-5.2 sgt-dispatch smith --td td-a3cf60
```

Every transport below is **measured** on a host with that harness installed, never
inferred from documentation. Sergeant validates against it before creating any
state:

| Harness | Model transport | Variant transport |
|---|---|---|
| `opencode`, `oc` | argv `--model <provider>/<model>` | argv `--agent <name>` against a Sergeant-generated agent definition carrying the variant |
| `goose` | env `GOOSE_PROVIDER` + `GOOSE_MODEL` — `goose session` has no model flag, and Sergeant controls the worker environment at spawn | none known — a pinned variant fails closed |
| `claude` | not measured by Sergeant | not measured by Sergeant |

`opencode` has no `--variant` flag, but it does accept `--agent <name>` at launch
and its agent definitions carry a first-class `variant` field. So Sergeant writes
a definition pinning both model and variant into **fleet state** (never the
worktree, so a pinned variant cannot leave untracked files in the repository
under review) and points the harness at it with `OPENCODE_CONFIG`.

A pin fails closed in two distinct situations, and the diagnostic says which:

- **no known transport** — the harness has been measured and exposes no way to
  pin that axis at launch. Configure it in the harness itself.
- **unmeasured** — the harness is not installed here, so its launch surface has
  not been observed. This is *not* a claim that the harness cannot do it.

Dispatch records the resolved tuple in `agent_model` and its origin in
`agent_model_source`. The worker records what it actually launched in
`launch_record`: harness, model, provider, both transports, the generated
definition, and the exact model argv and environment it used.

`launch_record` also carries two honesty fields:

- `launch_state` is `intended` before the harness is executed and becomes
  `confirmed` only once the harness reports itself ready, so a harness that
  rejects a pin and exits never leaves evidence claiming the model ran.
- `provider_verified` says whether the invocation itself proves the provider.
- `variant_verified` is always `false` today. The variant *transport* is real, but
  no supported harness reports back which variant it resolved, so Sergeant records
  the pin without claiming it was honored.

A resumed or recovered worker reads the same fleet record, so it inherits the
same pin. A worker handed a tuple its harness cannot honor fails terminally
rather than falling back to the ambient default.

The tuple is resolved from the flag, the environment, or the unpinned default —
**explicitly only**. There is deliberately no project-level model default; that
would expand the project schema and is tracked separately.

### Dispatching without an interactive coordinator pane

By default `sgt-dispatch` binds the tmux pane it was invoked from. An API-driven
coordinator that is not inside a pane has two options, both of which still
require a persistent interactive worker and still fail before any intent file,
td task, worktree, or fleet state is created:

```bash
# Create or select Sergeant's single managed coordinator pane.
sgt-dispatch smith "Add OAuth" --repos smith --managed-coordinator-pane

# Bind a pane the caller already prepared.
sgt-dispatch smith "Add OAuth" --repos smith --coordinator-pane '%7'
```

The two options cannot be combined. Every path — ambient, explicit, and managed
— goes through one verification: the live tmux server must confirm the pane
exists, is not dead, and reports back the same pane id, so an absent, stale, or
forged identity is refused rather than adopted.

`--managed-coordinator-pane` deliberately does **not** start a tmux server; a
coordinator must already be able to reach a live one, so a headless environment
fails loudly instead of acquiring a pane nobody can observe. The managed pane is
reused across dispatches and runs a reader that displays each line it receives
and never executes it, so a tmux-injected notification can never become a shell
command in the coordinator's pane.

### No-mistakes

**Use no-mistakes as a final shipping gate, not an implementation loop.** Implementation, focused repository-native tests, lint, and independent review must be complete before starting it. A clean run takes several minutes; invoking it during development or repeatedly restarting it multiplies that cost.

#### Starting a run

Before starting: finish and commit on a feature branch, ensure `no-mistakes doctor` is healthy, and check `no-mistakes axi` for an already-active matching run — reattach rather than create a duplicate.

```bash
no-mistakes axi run --intent-file .sergeant-intent.md
# or: no-mistakes axi run --intent "<the user's objective and approved tradeoffs>"
```

Do not use `--yes`. Use `--skip=<steps>` only for stages already proven irrelevant (e.g. `--skip=document` for changes that cannot affect docs). Skipping is not a substitute for checks that have not been performed.

Routine dispatched workers do not invoke no-mistakes for ordinary completion, prototypes, investigations, documentation drafts, intermediate commits, or remediation loops. The coordinator starts a single run only after the implementation branch is committed and native validation is complete.

#### Driving gates

`axi run` and `axi respond` block while work is active — a quiet step is not a stall. Check progress with `no-mistakes axi status` without issuing duplicate run commands.

At each gate, inspect every finding:

- **`auto-fix`** — authorize selectively: `no-mistakes axi respond --action fix --findings <ids>`. Review the exact finding first.
- **`ask-user`** — relay to the user and wait for their decision. Never approve, fix, or skip autonomously.
- **`no-op`** — informational; approve the gate.

While a run is active: do not edit the pipeline-owned worktree, do not abort or rerun to escape a gate, and preserve all pipeline-created commits. Abort only when intentionally discarding the entire run.

#### Finishing

Stop driving at `checks-passed`. The PR is ready; no-mistakes monitors it in the background. Do not poll or wait for merge.

If the outcome is `failed` or `cancelled`, inspect `branch_sync` state first:
- `sync` → run `no-mistakes axi sync`
- `continue_active_run` → keep driving the reported run
- `recover_custody` → use `no-mistakes axi sync --recover`

Never improvise a reset, stash, force-push, or branch replacement around a blocked sync state.

#### Findings routing

The run is validation-only: it must not fix findings. Route actionable findings into separate, deduplicated owning-repo td tasks with `sgt-no-mistakes-finding`.

The required `--disposition` is explicit per finding: `gate` creates or updates P1 work and retains the gate, `ask-user` creates or updates P1 work and preserves human escalation, `td` creates or updates nonblocking actionable debt, and `ignore` records that no card is needed. Warning debt becomes P2, informational debt becomes P3, and repeated finding IDs update the same card while retaining the latest run ID, head SHA, location, description, and originating intent. Reruns also preserve any existing repo-specific or manually added td labels while ensuring the required `no-mistakes` and `finding` labels remain present without duplication.

On rerun, visible active cards stay in their current state, while explicitly hidden states are resurfaced: closed cards are reopened and deferred cards are undeferred before the finding body is refreshed.

Correctness, security, data-integrity, and test findings cannot be deferred or ignored. Cosmetic and evidence-only findings never create cards.

### Independent review routing

Generated worker briefs require one independent review per axis named in `SGT_REVIEW_AXES_REQUIRED` in `bin/_sgt-review-axes.sh` — Standards, Spec, and Readiness. Frontend, UI, visual, interaction, accessibility, or user-facing output language in the mission, repo role, or repo group additionally requires the conditional Accessibility axis. That one definition drives both the axes the generated brief demands and the `--axis` values `sgt-review-findings` accepts, so the contract and the router cannot drift. `sgt-no-mistakes-finding` continues to route structured accessibility findings whenever a review supplies them.

### Independent review findings

Dispatched workers pass each axis's strict JSON finding artifact to `sgt-review-findings`. The router creates or updates one owning-repository td task per actionable finding, preserves active task state on reruns, and publishes blocking task IDs and remediation guidance through `.sergeant-message`, `.sergeant-status`, and `sgt-notify`. Cosmetic and false-positive dispositions create no cards. The schema rejects free-form review bodies, and credential-shaped values in accepted fields are redacted before durable storage.

Set each finding's `severity` to a canonical `error`, `warning`, or `info`. The router also accepts and normalizes the spellings reviewers actually emit — `blocker`, `critical`, and `high` become `error` (P1); `major` and `medium` become `warning` (P2); `minor`, `low`, and `informational` become `info` (P3). Only the `error` family publishes a blocking gate, so reserve it for must-fix findings. The canonical set, the alias table, and the accepted axes are all printed by `sgt-review-findings` with no arguments.

Deduplication is scoped to the owning repo, axis, source, finding id, parent mission, and branch, so two sessions cannot collide on a generic finding id such as `spec-1`. An update never replaces a stored card: each revision the router writes ends with a `Revision block digest:` line over its own bytes, so a later route can tell whether the stored revision is still exactly what the router wrote. If anything has changed it — an edited value, an added line, a hand-written note, or a changed card title — the whole stored revision is kept below a `--- Superseded revision (preserved) ---` separator and the card is labelled `needs-reconciliation`. Remove that label once a human has merged the two accounts of the finding; nothing else clears it. A closed card matching a finding is always reopened rather than abandoned, and the reopen is always reported.

When a route fails after parsing, the sanitized findings are retained under `<worktree>/.sergeant-review-artifacts/<axis>-<source>/` and the blocked message names the exact retry command:

```bash
sgt-review-findings <project> <repo> --retry <artifact-dir> --worktree <path>
```

The retained artifact holds only post-redaction fields, never the reviewer's original output, and a retry re-validates every field and recomputes each content digest before anything reaches td. A route will refuse rather than overwrite an artifact nobody has retried yet.

## Skills

Agent-loaded skills for structured workflows:

| Skill | What it does |
|---|---|
| `skills/load-project` | Load and internalize full project context |
| `skills/cross-repo-work` | Plan and execute changes across multiple repos |
| `skills/dispatch` | Dispatch subagents per repo with worktrees + briefs |

## Requirements

See the complete [getting started checklist](docs/getting-started.md) for
installation and verification.

- [`github.com/marcus/td`](https://github.com/marcus/td) — task CLI, required for brief-based `sgt-dispatch` runs, `sgt-no-mistakes-finding`, `sgt-review-findings`, and `sgt-td-*` commands; install with `brew install marcus/tap/td` or `go install github.com/marcus/td@latest`
- `yq` — YAML parser: `brew install yq`
- `python3` — callback state/protocol runtime and dispatch JSON processing
- `git` and `gh` — for repo operations and PRs
- `tmux` — for local agent dispatch
- `lsof` — for verifying cleanup does not remove an in-use worktree
- no additional locking tool is required: drain admission locking uses an atomic
  hard link, so `flock` is deliberately not a prerequisite (macOS system
  installs and minimal images ship without it). The drain state directory
  (`$SERGEANT_CONFIG/drain`, default `~/.config/sergeant/drain`) must be
  writable by the invoking user and on a filesystem that supports hard links;
  otherwise dispatch and respond fail closed rather than proceeding unlocked.
- `treehouse` — pre-warmed worktree pools (optional but recommended for dispatch)
- `graphify` — knowledge graph generation (optional, needed for `sgt-graphify`)
- [`dagr`](https://github.com/callmeradical/dagr) — SQLite DAG execution engine (optional; needed only for `sgt-dag-run` and DAG-directed workflows; all other Sergeant commands work without it)
- A supported agent harness: OpenCode or Claude Code

## License

MIT
