# What is Sergeant?

Sergeant gives an agent a local model of a developer's projects: which
repositories belong together, what each repository owns, which instructions
apply, how work is tracked, and how implementation workers are isolated and
observed.

## Audience and deployment model

Sergeant is designed for one developer per installation. Adoption by a larger
development organization means each developer installs Sergeant independently;
it does not turn one Sergeant installation into a shared team service.

Each installation owns:

- `~/.config/sergeant/` project configuration;
- local Git credentials and GitHub account selection;
- worktrees or Treehouse leases;
- `~/.local/share/sergeant/fleet/` worker state;
- local tmux panes and agent processes;
- local wiki captures and optional knowledge graphs.

Sergeant does not provide central tenancy, organization RBAC, shared credentials,
cross-machine worker leases, or a team-wide fleet database.

## Core concepts

### Project

A named YAML configuration containing repositories, groups, roles, inherited
instructions, and optional project-level Graphify output.

### Repository

One source repository with a resolved local path, optional clone URL, role, group,
and repository-specific agent instructions.

### Task

Tracked work in the configured task adapter. Current Sergeant workflows use
[Marcus `td`](https://github.com/marcus/td). A task records ownership, decisions,
handoff state, review, and closure.

### Fleet

The local collection of dispatched workers for a Sergeant task. Fleet state is
operational evidence, not a replacement for Git, task, PR, or validation state.

### Worker

An agent running in an isolated worktree and tmux pane. A live process is not
proof of progress; recent meaningful output or an active child operation is
required.

### Decision request

A `needs_input`, `blocked`, or validation ask-user gate that requires a human
product, security, privacy, destructive-action, or risk decision. Mechanical
findings are not human decision requests.

## Execution modes

### Direct mode

Use when the user explicitly requests implementation in the current session and
one repository owns the outcome. Direct mode still requires a task, TDD,
repository-native checks, independent review, shipping validation, and handoff.

### Dispatch mode

Use for cross-repository work, independent parallel repository tasks, isolated
review workers, or an explicit request for workers. Sergeant creates isolated
worktrees, injects repository instructions, and records fleet state.

## What Sergeant is not

- It is not a centralized team orchestration service.
- It is not a replacement for GitHub, Git, CI, or the task tracker.
- It is not permission to push directly to default branches.
- It does not make a worker healthy merely because its process exists.
- It does not treat a plan, task, worker launch, or finding as delivered work.
- It does not authorize validation agents to modify source while reporting
  findings.

## Related tools

- **tmux** hosts local worker panes.
- **Marcus td** tracks work and handoffs.
- **Treehouse** optionally supplies leased worktrees.
- **Graphify** optionally builds one knowledge graph per Sergeant project.
- **no-mistakes** validates one explicit final shipping boundary.
- **OpenCode, Goose, or Claude Code** runs coordinators and persistent interactive workers.
