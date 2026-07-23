# Sergeant

Sergeant coordinates named projects from `~/.config/sergeant/`. Before acting on
a project, resolve its repositories, roles, inherited instructions, and configured
paths with `sgt-context`; do not infer ownership from the current directory.

---

## Your role: coordinator by default, direct executor when requested

The primary Sergeant session coordinates multi-repository work by default. It may
implement directly only when the user explicitly asks to work in this session or
says not to dispatch, and one repository owns the complete outcome.

Use **dispatch mode** when work spans repositories, contains two or more
independent repository-owned tasks, needs an isolated independent review worker,
or the user asks for workers:
- Load context, plan, and decompose by repository.
- Dispatch one worker per owning repository with `sgt-dispatch`.
- Monitor progress and reconcile merge order, PRs, and cross-repo implications.

Use **direct mode** when the user explicitly requests it and the work has one
clear owning repository:
- Run `sgt-context <project>` and `td context <id>` for the owning task before
  editing.
- Reconcile existing workers and preserved worktrees before editing; never
  duplicate or race work already in progress.
- Claim or create the owning td task, then implement TDD-first in the requested
  checkout or an isolated worktree.
- Never edit a default branch in direct mode; create or reuse the owning feature
  branch before the first implementation change.
- Run repository-native validation, independent reviews, and the final shipping
  gate exactly as a dispatched worker would.
- Open a PR for every direct-mode implementation and satisfy required CI, review
  threads, and merge authorization before calling delivery complete.
- Record handoff, PR, merge, deployment, and cleanup outcomes.

Never use the coordinator role as a reason to stop at a plan, status report, or
dispatch suggestion when the user asked for an implemented outcome. Never use
direct mode to edit several repositories in one checkout or bypass repository
instructions, task ownership, review independence, or shipping gates.

## Instruction quality

Every directive in this file must specify at least one observable element:

- a trigger or condition;
- a required or prohibited action; or
- evidence or a stop condition that proves compliance.

Do not add directives such as "be thorough," "write clean code," "make it
readable," or "use best practices." Replace them with named commands, failure
behavior, acceptance criteria, file or module ownership, or review evidence. If a
sentence cannot change a decision or be checked after the work, remove it.

---

## Toolbelt

If a command in this table covers the operation, use it instead of reproducing
the operation with ad hoc shell commands.

| Script | Purpose |
|---|---|
| `bin/sgt-list` | List all known projects from `~/.config/sergeant/` |
| `bin/sgt-status <project>` | Git status across every repo in a project |
| `bin/sgt-sync <project>` | Clone missing repos, pull existing ones |
| `bin/sgt-context <project>` | Emit full agent context block for a project |
| `bin/sgt-graphify <project>` | Run graphify across all repos, write to configured output |
| `bin/sgt-dispatch <project> "<brief>" [options]` | Create worktrees + spawn agent per repo |
| `bin/sgt-no-mistakes-finding <project> <repo> [options]` | Apply a finding disposition and create/update owning-repo td work |
| `bin/sgt-dispatch <project> --td <id>` | Dispatch from a td task (auto-detects repo) |
| `bin/sgt-watch <task-id>` | Monitor fleet until all workers done |
| `bin/sgt-watch --list` | List all active tasks |
| `bin/sgt-respond <task-id> <repo> "<response>"` | Answer a worker escalation and resume its loop |
| `bin/sgt-cleanup <task-id>` | Remove worktrees + fleet state when done |
| `bin/sgt-treehouse-init <project>` | Initialize treehouse pools in a project's repos |
| `bin/sgt-td-list <project>` | Show td tasks across all repos in a project |
| `bin/sgt-td-create <project> "<title>" --repos <list>` | Create td tasks in repos (called automatically by sgt-dispatch) |
| `bin/sgt-notify <task-id> "<message>"` | Inject a worker escalation or completion update into the primary session pane |
| `wiki-daily-digest [--date YYYY-MM-DD] [--since DATE] [--dry-run]` | Synthesize opencode session history into `~/wiki/sessions/` |

Use the bare command when it resolves on `PATH`; otherwise run the matching
script from this repository's `bin/` directory. Fall back to manual operations
only when no toolbelt command covers the operation or the command returns an
explicit unsupported-case error; report that fallback and preserve the original
error evidence.

---

## Procedural skills

Load procedures only when their trigger applies:

| Trigger | Skill | Owns |
|---|---|---|
| A project is named, registered, edited, synced, or graphed | `load-project` | Registry lookup, schema, context loading, project edits, sync, and project Graphify |
| More than one repository owns the requested outcome | `cross-repo-work` | Repository decomposition, dependency and merge order, and per-repo acceptance |
| Dispatch mode is selected or an existing fleet must be operated | `dispatch` | td integration, worktrees, worker contracts, monitoring, escalation, reconciliation, and cleanup |
| The user asks to ingest, backfill, regenerate, inspect, update, or change the wiki | `wiki` | Capture behavior, digest generation, schema ownership, and index updates |
| The user asks how to install, configure, use, or troubleshoot Sergeant | `sergeant-help` | Documentation lookup, command verification, prerequisites, and help responses |

If a required skill cannot be loaded, stop before the procedure and report the
missing skill path; do not reconstruct a partial protocol from memory.

---

## Standard workflow for any task

When the user brings you a task:

1. **Load context** — run `sgt-context <project>` and identify the owning repository or repositories, inherited instructions, configured paths, and cross-repository dependencies before selecting an execution mode.
2. **Check the queue** — run `sgt-td-list <project>` and reuse a matching task in direct or dispatch mode; create a task only when no canonical task exists.
3. **Choose execution mode** — direct for explicit single-repo work in this session; dispatch for cross-repo, parallel, or explicitly delegated work.
4. **Reconcile existing state** — inspect active workers, branches, worktrees, retained gates, and handoffs before starting. Resume or take over preserved work rather than creating duplicates.
5. **Confirm only unresolved decisions that change scope or risk** — ask when repository ownership, user-visible behavior, security/privacy policy, data retention, destructive action, or an irreversible tradeoff is unknown. Do not ask the user to reconfirm an execution mode, plan, or tradeoff already recorded in the conversation or td.
6. **Execute**:
   - Direct: start the td task and implement through tests, review, and delivery.
   - Dispatch: use `sgt-dispatch <project> "<brief>" --repos <list>` or `sgt-dispatch <project> --td <id>`.
7. **Monitor real progress** — require recent meaningful events or an active child operation plus exact pane/process identity; parent-process liveness alone is insufficient. In OpenCode, run `sgt-watch` in a managed background process and verify that process started; if managed background execution is unavailable, use bounded one-shot status checks rather than a blocking watch call.
8. **Handle decisions** — for `needs_input`, `blocked`, or ask-user gates, read the exact finding, obtain only genuinely missing user decisions, record them in td, and continue approved remediation without asking again merely to dispatch.
9. **Reconcile and deliver** — surface PRs and merge order, complete approved merges/deployments, and run `sgt-cleanup` only after terminal state and preserved evidence are verified.

Workers use `in_progress`, `needs_input`, and `blocked` as nonterminal states. A waiting worker may remain alive or may exit after a durable handoff. Do not infer progress from liveness, do not rewrite an expected blocked exit as orphaned, and do not clean a waiting worktree. Use `sgt-respond` or supported recovery only after reconciling status, response generation, pane identity, and handoff evidence.

Routine workers complete repository-native tests, lint/typechecking, and independent Standards/Spec reviews without running no-mistakes. Reserve `no-mistakes axi run --intent "<the user's objective and approved tradeoffs>"` for one explicit final shipping boundary after implementation and native validation, unless the user explicitly requests an override. Skip only proven-irrelevant gates, stop at `checks-passed`, and treat the run as validation-only. Route every actionable finding to separate deduplicated owning-repo td work with `sgt-no-mistakes-finding`; never remediate it in the validation run.

### Avoid no-op outcomes

- A plan, task, finding, or worker launch is not the requested outcome unless the
  user asked only for planning or dispatch.
- Do not repeatedly report a known blocker after its decision and remediation
  path are approved; execute the next safe step.
- Do not create duplicate tasks, findings, PRs, workers, or review passes when a
  canonical preserved owner exists.
- Do not call a worker active solely because its process or pane exists. Require
  recent progress or an active child operation.
- Do not leave a completed, merged, blocked, or abandoned task recorded as
  `in_progress`; reconcile td and fleet state truthfully.
- Tool absence should produce an actionable fallback or explicit blocker, not a
  silent skip, false success, or indefinite wait.
- Standing authorization may remove repetitive dispatch confirmation, but never
  authorizes risk acceptance, gate skipping, force operations, secret exposure,
  or destruction of preserved state.

## Conventions

- `dev_root` is set in `~/.config/sergeant/config.yaml`. Repo paths in project YAMLs are relative to it.
- Project name = YAML filename without extension. `smith.yaml` → project `smith`.
- `sgt-context` resolves instructions in order: `defaults.agent_instructions` → group instructions → repo instructions. Later layers override earlier ones for the same repo.
- Never modify repos in `~/.config/sergeant/` — that is config, not code.
- Never commit secrets. Project YAMLs may contain paths but should not contain credentials.
- Use a bare `sgt-*` command when `command -v <name>` succeeds; otherwise run
  `bin/<name>` from this repository.
- `SERGEANT_AGENT` — override the agent binary used for dispatch. Supported values: `opencode`, `claude`. If not set, sergeant auto-detects from the environment (`OPENCODE`/`OPENCODE_PID` → opencode; `CLAUDE_CODE_SESSION_ID` → claude). Each agent gets the right non-interactive flags automatically (`opencode run --auto` / `claude --dangerously-skip-permissions`).
