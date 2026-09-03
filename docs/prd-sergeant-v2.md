# Sergeant v2 — Product Requirements Document

**Status:** Draft for human review  
**Product:** Sergeant, a local-first, Go-native software factory  
**Audience:** Product owner, operators, implementers, reviewers

## 1. Product vision

Sergeant is a single software factory that turns bounded intent into safe,
evidenced, reviewed delivery across multiple projects and repositories. One
installation can load many project topologies, apply reusable factory
pipelines, execute repository-scoped phases, and report a complete result
without losing scope, evidence, or failure state.

Sergeant v2 is the Bash replacement and the intended Go execution model. It
replaces interactive tmux workers and the shell supervision plumbing built
around them with Go-native coordination, deterministic code gates, and durable
records. The Go code in `cmd/sergeant` and `internal/` is the current execution
foundation: a CLI for running and inspecting multi-repository factory DAGs,
project configuration, an embedded status/refinement UI, isolated Git worktrees,
bounded phase execution, handoff envelopes, and durable run/phase records.

v2 has **two ways in, and both write the same records**:

1. **Agent-driven.** The operator launches their own agent CLI (opencode/oc,
   codex, goose, pi, claude, copilot) in a terminal inside the project. That agent talks to
   Sergeant over MCP (`sergeant_get_brief`, `sergeant_run_gates`,
   `sergeant_emit_envelope`, `sergeant_seal_pr`, `sergeant_status`). Sergeant
   does not spawn, host, or multiplex the session; it is the system the agent
   works *within*.
2. **Coordinator-driven.** The operator dispatches from the UI and Sergeant
   coordinates the work itself, invoking bounded headless agent phases.

Both create and update the same records, and both go through the same gates. Neither uses tmux. Having two different execution models inside v2
would be a bug, not a feature.

Sergeant's lessons inform the product guarantees: reliability, explicit safety
boundaries, durable evidence, tasking, isolated workers, review, recovery, and
controlled delivery. The composable vocabulary of Super Simple Software
Factory informs the factory/project/phase model. Super Simple Software Factory
is not a second runtime or implementation to preserve.

## 2. Users and operating model

- **Operator/requester:** selects a project, starts a run, supplies bounded
  intent, observes progress, and receives delivery evidence.
- **Factory owner:** defines reusable phase pipelines, repository gates, worker
  policy, and delivery requirements.
- **Coordinator process:** loads configuration, creates a run, resolves the
  project DAG, prepares isolation, invokes bounded phases, records results, and
  advances or fails the run.
- **Headless phase worker:** one agent CLI invocation for one repository and
  phase, with a strict timeout and structured handoff output.
- **Reviewer/auditor:** inspects persisted run/phase records, artifacts, gate
  results, commits, and delivery state.

The baseline is local-first and single-operator. Credentials, configuration,
worker processes, worktrees, and durable state belong to the local installation.
A hosted multi-tenant control plane is not implied.

## 3. Scope

### In scope

- One installation operating multiple named projects.
- Each project spanning multiple repositories with explicit names, paths, roles,
  groups, instructions, and topology.
- Reusable factories expressed as ordered phases and cross-repository DAG
  stages, with repository-local pipelines and deterministic quality gates.
- Bounded, headless execution through supported agent CLIs.
- Go-native CLI execution, status inspection, embedded web observability, and
  machine-readable MCP integration where useful to the product.
- Isolated Git worktrees for every change-producing repository assignment.
- Durable run and phase records, typed notification/handoff envelopes, a
  durable envelope transport with retries and delivery evidence, timeouts,
  failure reporting, and delivery evidence.
- Human approval gates where a factory policy requires product, specification,
  destructive-action, security, privacy, or shipping decisions.
- Bash replacement: the supported v2 workflow is the Go engine, not parallel
  Bash and Go dispatch paths.

### Out of scope

- Interactive tmux workers, persistent worker sessions, wake/respond worker
  control, or tmux as an execution dependency.
- Preserving Sergeant's legacy shell dispatch behavior, command set, fleet file
  formats, or worker protocol as v2 compatibility requirements. Any adapter is
  future work outside this PRD.
- A hosted multi-tenant service, organizational RBAC, shared fleet database, or
  cross-machine worker leasing.
- Replacing Git, GitHub, CI, repository-native tests, or task/review systems.
- Treating Super Simple Software Factory as a runtime to embed or maintain.
- Automatic product decisions, fake human approval, or bypassing safety gates.
- Requiring a specific agent vendor beyond the supported headless command
  contract.

## 3a. Domain model (settled)

```
Project            a named set of repositories
  └─ Intent        a durable statement of desired change; may span repos
       └─ Bullet   a tracer bullet: ONE repo, vertical through that repo's
                   stack, implemented test-first, yielding one commit and one PR
```

**Intent is the primary durable object.** The system exists to satisfy intents.
Runs, phases, worktrees and sessions all exist to serve an intent. They are not
the thing being tracked.

**A tracer bullet is scoped to exactly one repository.** It is a vertical slice
through that repo's stack, not a horizontal slice across repos. Work in a second
repository is a second bullet. This makes atomicity real, because Git provides it
per repository; the intent is what holds the ordering
between repos.

**Breaking an intent down** into ordered bullets is done either by the configured
workflow or by the model. The two are trusted differently (see D2).

### Settled decisions

- **D1 — Two ways in, one set of records.** Agent-driven (MCP) and coordinator-driven
  (UI dispatch) both create the same intents, bullets and evidence.
- **D2 — Trust the workflow, review the inference.** Workflow-defined
  decomposition executes immediately; it is deterministic given the intent's repo
  set and was approved when the workflow was authored. Inferred decomposition
  produces a *proposed* plan requiring explicit human approval before any worktree
  is created.
- **D3 — TDD is enforced, not assumed.** A bullet must record a *failing*
  gate result before implementation and a *passing* one after. Red→green is
  evidence, produced by deterministic gates with no model judgment. Bullets with
  no natural red state (pure refactor) require an explicit, recorded exemption.
- **D4 — Sergeant stores intents and bullets itself.** Intents and bullets are first-class rows in
  Sergeant's own store with referential integrity to worktree, branch, commit and
  PR. Sergeant cannot enforce rules about data it does not own. Exporting a
  read-only copy to a task tracker is optional.
- **D5 — Three interruptions only.** A human is notified when (a) an inferred plan
  awaits approval, (b) a bullet is blocked on a human decision, (c) a bullet is
  ready for an irreversible step. Everything else just shows up in the
  fleet view. Telling the operator everything is fine regardless of what actually
  happened is a bug.
- **D6 — Sequenced submission, human merge.** Sergeant releases a bullet's PR only
  once its upstream bullets are reviewed and merged, observing real PR state to
  advance the chain. Sergeant never merges. So Sergeant is never the thing that made
  an irreversible change across several repos, which keeps R3.4 honest.
- **D9 — graphify is a v2 capability, implemented natively.** A project may declare
  a `graphify:` block (`output`, `include_groups`, `exclude_patterns`). The system
  builds a graph per repository, merges them into one cross-repository graph, and
  publishes it atomically to the configured output. It must not call `sgt-graphify`
  (D7). The graph is exposed to agents over MCP as query, affected and explain
  tools, so a dispatched agent navigates by graph rather than by grepping files.

  Today the block is parsed and discarded: `config.Project` has no `Graphify`
  field. It survives a config save only because saving patches the YAML node tree
  and preserves keys the server does not model.

- **D10 — Sergeant is an agent host, and its client contract follows the Agent
  Host Protocol where AHP has already settled the question.** AHP
  (`microsoft/agent-host-protocol`) is the client-facing state-synchronisation
  layer *above* an agent runtime; ACP is the point-to-point layer below. Their own
  framing is "AHP is a mutex over ACP". Sergeant already occupies the host
  position: it owns authoritative run state, spawns agents, and serves a
  dashboard client. It therefore inherits AHP's solved problems and must stop
  hand-rolling worse versions of them:

  - a dispatch carries a caller-supplied idempotency key, and a repeat of the same
    key returns the original run instead of starting a second one (AHP
    `runAutomation` + `requestId`);
  - clients receive an ordered, sequence-numbered stream and reconnect by
    replaying from the last sequence they saw, rather than re-reading the whole
    world every two seconds (AHP subscribe/snapshot/replay).

  Sergeant does **not** adopt AHP as its wire protocol at this time. The protocol
  is five months old, its Go client is pre-1.0 (0.8.0 against spec 1.0.0), and its
  doctrine still reserves the right to break. This decision borrows AHP's settled
  designs; it does not create a dependency.

  AHP is explicitly not a substitute for anything sergeant decides. Its stated
  anti-goals include agent-to-agent coordination, tool registries, and the agent
  loop itself — which is to say, intent decomposition, merge ordering, TDD
  evidence, gates and chain of custody all remain sergeant's own problem.

- **D8 — The dashboard is a view of intents, and it renders the workflow from a
  definition.** The primary list is intents, not runs. Selecting an intent shows its
  bullets, one row per repository. Each bullet renders the workflow as a *definition*
  with progress against it, so a stage that has not started is still visible rather
  than absent. The definition is served from configuration (`factory.pipeline`,
  `factory.gates`) plus the bullet lifecycle, so adding a gate changes the view with no
  UI change. Runs and phases are drill-down evidence beneath a bullet, never the
  top-level object.

  Rationale: section 3a states that runs, phases, worktrees and sessions exist to serve
  an intent and are not the thing being tracked. A dashboard whose primary object is the
  run tracks precisely the wrong noun. Deriving columns from phases that already
  executed also makes the view retrospective: it can answer "what happened" but not
  "what happens next" or "where are we".

- **D7 — v1 is not a dependency.** Sergeant must not shell out to `sgt-*`, adopt
  v1's fleet file layout, or reuse its supervision plumbing. Where a v1 capability
  is absent, that is unimplemented v2 scope.

## 3b. Planning method: OpenSpec (first-class)

[OpenSpec](https://openspec.dev) (`@fission-ai/openspec`, OPSX workflow) is a
supported first-class planning method. It is a lightweight spec-driven layer:
`openspec/specs/<capability>/spec.md` holds living requirements; a **change** is
one unit of work in `openspec/changes/<id>/` containing `proposal.md`,
delta `specs/`, `design.md` and `tasks.md`; archiving folds the delta into the
living spec. Requirements carry `#### Scenario:` blocks in WHEN/THEN form, and
upstream states plainly that "each scenario is a potential test case".

**Why it is adopted.** Not for planning ergonomics. The problem being solved is
governance: distributed contributors who do not consistently follow development
practice, PRs that arrive undocumented, and no reliable visibility into what is
being worked on or why. OpenSpec supplies chain of custody — the intent behind a
change, reviewable alongside the diff, and continuously maintained as
documentation rather than decaying in a wiki or a chat log.

### Settled decisions

- **O1 — Planning lives per code repository.** Each repo carries its own
  `openspec/`. Stores (upstream's separate planning repo, currently beta) are not
  adopted: the spec must travel *in the pull request* to produce chain of custody
  at review time, which is the entire point. Grouping related changes across repos is
  something Sergeant does, not OpenSpec.
- **O2 — Change-to-code linkage has three legs, with ranked trust.** Audit relies
  on the strongest leg available and never on the branch alone:
  1. **`openspec/changes/<id>/` present in the PR diff** — primary. Self-evident
     at review; cannot be produced without doing the work.
  2. **`Change-Id: <id>` commit trailer** — durable secondary link. CI must
     enforce it into the PR body, because GitHub builds squash commits from the
     PR title/body and would otherwise drop trailers carried on individual
     commits.
  3. **Branch named `<type>/<change-id>`** — convenience only. Preserves the
     conventional-commit prefix already in use (`feat/`, `fix/`) while making the
     branch machine-resolvable, since OpenSpec change ids are already kebab-case
     slugs. Branches are ephemeral and renameable, so they are never the audit
     link.
- **O3 — Dispatched work is held to the same standard.** A dispatch must resolve
  to a change; the system scaffolds one via the `openspec` CLI from the brief if
  none is referenced, before any worktree is created. Without this the system
  becomes the largest producer of exactly the undocumented work it exists to
  eliminate, and faster than any human. The change then serves three roles at
  once: the durable intent record (D4), the approval surface (D2), and the audit
  artifact.

### Open questions

- **Schema.** Use stock `spec-driven`, or fork a project-local schema
  (`openspec schema fork`) whose `tasks` artifact enforces one-repo-per-bullet and
  declares merge-order dependencies? `openspec schema` is flagged
  *experimental* upstream.
- **Enforcement posture.** Does CI *block* a PR with no linked change, or report
  coverage and escalate? Blocking is the lever that changes behaviour; it also
  invites circumvention on a distributed team.
- **Scenario-to-test binding.** D3 requires a recorded failing gate before
  implementation. Scenarios are the natural source of that red state, but the
  mechanism (generated test stubs, or scenario ids referenced by existing tests)
  is undecided.
- **`skip_specs`.** Upstream supports `skip_specs: true` in a change's
  `.openspec.yaml` for pure refactor/tooling/docs work. This is a candidate
  answer to D3's outstanding refactor-exemption gap — the two should be
  reconciled rather than solved twice.

## 4. Core abstractions

### Factory

A reusable blueprint with a stable identity and version. It defines ordered
phase/stage composition, repository gates, worker policy, dependency rules,
retry/timeout policy, approval requirements, and delivery policy. A factory can
be applied to many projects; each run records the factory configuration it
used.

### Project

A named topology grouping repositories worked on together. The current
configuration model supports project name/description, a repository map or
list, per-repository path/role/group/factory settings, defaults for agent/model,
and an optional cross-repository DAG with named stages, repository membership,
predecessors, briefs, and task references.

### Repository

A project member with an explicit stable name and path, plus optional role,
group, local factory pipeline, and quality-gate commands. Every phase assignment
names its repository; an unknown repository is rejected rather than invented.

### Phase and stage

A **phase** is a bounded unit of work with a name, input context, permitted
outputs, repository scope, worker command, timeout, and structured result. A
**stage** is the cross-repository DAG unit that groups phase pipelines and
expresses `after` dependencies. Code gates run deterministically, including
stable ordering when multiple gates are configured. Neither abstraction may
silently widen repository scope.

### Run, assignment, envelope, and evidence

A **run** is one application of a factory/DAG to one project. An **assignment**
is one repository/phase execution in the run's isolated worktree. A **typed
envelope** is the canonical software-factory notification and handoff message:
it has an immutable envelope ID, schema/type/version, producer and timestamps,
a correlation ID, optional causation ID, and explicit factory, project,
repository, run, phase, and assignment references. Its validated payload and
artifact references carry the bounded result or lifecycle event; delivery
metadata is recorded separately from business payload. **Evidence** includes
run and phase IDs, statuses, durations, gate commands/results, sanitized agent
output, envelopes and their delivery history, worktree/branch references,
commits, and final delivery reports. A live process is never sufficient
evidence of success.

### Notification and envelope transport

The software factory owns a durable, first-class notification transport. It
publishes and consumes typed envelopes for phase results, dependency handoffs,
operator approvals, lifecycle changes, failures, and delivery outcomes. The
transport is the stable boundary between the coordinator, bounded headless
workers, project/repository pipelines, and operator surfaces; a file copied into
a worktree or a process wake-up is only a projection, never the authoritative
message. Existing Go handoff code (`handoff.Envelope`/`Router`) and the SQLite
`envelopes` records establish the terminology and are v1 implementation
foundations, but v2 must extend them to the contract below rather than create a
second notification protocol.

### R1 — Multi-project and multi-repository operation

1. The installation can list, load, validate, and run multiple named project
   configurations without cross-project state leakage.
2. A project can contain multiple repositories and a cross-repository DAG whose
   stages declare repository membership and predecessor dependencies.
3. The loader accepts the supported project configuration shape, including
   repository maps/lists, defaults, local factory pipelines, and gates; malformed
   configuration fails with an actionable error.
4. A run validates every referenced repository before execution and refuses
   missing or unknown repositories.
5. Project and run records identify the project and every repository assignment.

### R2 — Composable factory and phase execution

1. Factory pipelines are ordered and composable at project/repository and
   cross-repository stage levels.
2. A phase receives only its bounded prompt/context and repository scope and
   produces a structured handoff envelope or a recorded failure.
3. Supported headless agent invocations are constructed with non-interactive
   flags appropriate to each configured CLI; no phase depends on terminal input.
4. Each agent phase attempt is bounded by a strict timeout, and configured retry
   policy is explicit and observable.
5. Deterministic code gates run in stable order, record command/output/status,
   and prevent successful delivery when required gates fail.
6. A worker/phase process exit, generated file, or commit alone cannot falsely
   mark a stage or run as passed.

### R3 — Safety and isolation

1. Every change-producing repository assignment runs in a dedicated Git
   worktree and per-run branch; dispatch into a non-Git or otherwise unisolated
   directory is refused.
2. The source checkout is not mutated by preparing or running an assignment.
3. Agent prompts, phase outputs, and commit operations are scoped to the
   assignment worktree and configured repository.
4. Delivery reports distinguish committed changes, uncommitted changes, and no
   changes; the system never claims delivery that disk/Git state does not prove.
5. Human approval is explicit and required for factory-configured gates that
   authorize product/specification transitions or risky delivery actions.

### R4 — Durable evidence and privacy

1. Run and phase state is persisted durably and remains inspectable after a
   process exits.
2. Records correlate project, run, stage, repository, phase, attempt, handoff,
   gate, worktree, branch, commit, and delivery identifiers.
3. Captured agent output is sanitized for terminal control sequences before it
   is stored or rendered.
4. Logs, records, responses, and notifications must not retain credentials,
   tokens, environment dumps, or unrelated secrets. Product design must define
   redaction and retention before production release.
5. The product must distinguish operational metadata from request/brief content
   and retain only the minimum content needed to reproduce or audit a run.
6. Every agent phase record identifies the agent CLI, the model, and the
   model's provider that actually executed it, derived from real evidence of
   that execution rather than only from requested configuration. A result
   must be attributable to what produced it, not only to which sergeant
   component dispatched it.

### R5 — Notification/envelope transport

1. Every published envelope is typed and versioned, schema-validated, and
   immutable after publication. Minimum metadata: `envelope_id`, `type`,
   `schema_version`, `occurred_at`, `published_at`, `producer`,
   `correlation_id`, optional `causation_id`, and references for `factory_id`,
   `project_id`, `repo_id`, `run_id`, `phase_id`, and `assignment_id` where
   applicable. Payloads are bounded, redacted, and use explicit artifact
   references rather than unbounded logs or secrets.
2. Correlation IDs are stable across the full factory/project/repository/run/
   phase/assignment chain. Consumers reconstruct causation and ordering without
   parsing prose, filenames, tmux state, or worker process output.
3. Publication is durably persisted before acknowledgement to the producer;
   the authoritative record includes envelope, schema/type, correlation
   references, timestamps, and append-only delivery history. SQLite or an
   equivalent local-first durable store is acceptable, but process exit,
   restart, or a disconnected consumer must not lose an accepted envelope.
4. Each delivery has explicit state (`pending`, `leased`, `delivered`,
   `acknowledged`, `retrying`, `failed`, or `dead_letter`), attempt count,
   lease/next-attempt timestamps, consumer identity, and error classification.
   Delivery uses bounded retry with observable backoff and an idempotency key;
   redelivery cannot create duplicate authoritative phase results, approvals,
   or commits.
5. Permanent schema/validation errors, exhausted retries, poison messages,
   and unavailable destinations move to a durable dead-letter record containing
   the original envelope, attempts, reason, and recovery instructions.
   Dead-lettering fails or blocks the dependent phase/run unless policy marks
   that notification non-critical; it never silently drops or reports success.
   Operators can inspect, replay, or quarantine a dead letter through an
   auditable action with the same idempotency guarantees.
6. CLI and embedded UI expose envelope history and correlation: delivery state,
   attempts and errors, pending work, and dead letters scoped by project,
   repository, run, phase, assignment, and correlation ID. MCP, when enabled,
   provides structured notification status and policy-controlled replay /
   quarantine operations. These surfaces operate the same durable transport,
   not a parallel dispatch mechanism.
7. Notification transport is Go-native, bounded, and headless. It may use
   local files, SQLite, or another specified adapter, but v2 correctness must
   not depend on a terminal, tmux pane, interactive worker, shell injection,
   or an in-memory-only queue.

### R6 — Recovery and failure handling


1. A timeout, missing agent executable, malformed handoff envelope, failed gate,
   worktree error, or commit error produces an actionable phase/run failure,
   never a false success.
2. Run and phase writes are idempotent or safely reconciled so status polling,
   UI refresh, and process interruption do not create duplicate authoritative
   records.
3. A restarted coordinator can inspect the durable run and phase records and
   report the known state without starting speculative duplicate assignments.
4. Retry is bounded, recorded per attempt, and cannot bypass a failed required
   gate or isolation check.
5. Cleanup refuses to remove active or diagnostically incomplete worktrees and
   preserves the evidence needed to recover or review the run.
6. Cancellation prevents new assignments and records the terminal disposition
   of each known assignment; exact shutdown mechanics are an implementation
   design to be specified.

### R7 — Operator surfaces and delivery

1. `sergeant run <project>` starts a multi-repository factory run and reports
   stage progression and failure clearly.
2. `sergeant status` shows recent runs with project, status, and creation time;
   the operator can inspect phase-level state through the observability surface.
3. The embedded UI can list projects, show project details, refine supported
   project configuration, list runs by project, show phases, and present
   delivery status without becoming a second execution engine.
4. The MCP surface, where enabled, exposes structured run/status information for
   headless integrations rather than interactive worker control.
5. Delivery is explicit and reports actual worktree, branch, commit, pull
   request, and gate evidence. A successful run is not equivalent to a merged
   or deployed change unless the delivery evidence proves that outcome.

## 6. Product contracts vs implementation decisions

The multi-project/multi-repository scope, factory/project/phase abstractions,
bounded headless execution, Go-native v2 direction, typed envelope notification
transport, durable delivery/retry/dead-letter semantics, worktree isolation,
safety boundaries, evidence/privacy, recovery semantics, and measurable outcomes
above are product requirements.

The following remain implementation decisions to be resolved by technical
specification: exact Go package boundaries; SQLite schema and migrations;
precise YAML schema evolution; CLI/UI route details; supported agent version
matrix; timeout and retry values; Git branch naming; envelope schema registry and
payload catalog; transport adapter details; MCP method details; task adapter
integration; redaction implementation;
artifact/content-addressing mechanics; approval command UX; and rollout or
migration tooling. These decisions must not reintroduce interactive tmux
execution or require preservation of the legacy Bash implementation.

## 7. Quality and acceptance gates

A release candidate must pass repository-native Go tests and focused tests for
configuration parsing, multi-project isolation, DAG dependency ordering,
headless command construction, timeout/retry behavior, worktree isolation,
deterministic gates, handoff parsing, durable state, privacy/redaction,
recovery, UI/API behavior, and delivery reporting. Exact commands are recorded
by the owning project before implementation begins.

Minimum observable outcomes:

1. One installation runs two projects, each spanning multiple repositories,
   without cross-project scope or state leakage.
2. One factory definition can run against multiple projects while each run
   remains tied to its project and configuration snapshot.
3. No worker phase requires a terminal, tmux pane, persistent session, wake
   command, or response command.
4. A headless agent timeout or malformed output is visible as failure and cannot
   become a passed run through fallback text alone; malformed or undeliverable
   envelopes are retried or dead-lettered with no silent loss.
5. Every change-producing assignment uses an isolated worktree and leaves the
   source checkout untouched.
6. Cross-repository stages honor declared DAG dependencies and local pipelines
   execute deterministically.
7. Restart, retry, and status inspection preserve a coherent run and envelope
   history, deliver idempotently, and do not create speculative duplicate
   assignments or phase results.
8. Privacy fixtures prove that retained state does not expose credentials,
   tokens, environment dumps, or unrelated secrets, and terminal escapes are
   absent from rendered output.
9. Delivery evidence identifies actual gates, commits, worktrees, branches,
   pull requests, and terminal outcomes.
10. The Go CLI, embedded UI, and structured integration surfaces remain
    observability/operation views over the same durable run state rather than
    parallel dispatch implementations.

## 8. Open product questions

- Which factory and phase catalog ships first beyond the current DAG/stage and
  repository pipeline model?
- Which product/specification/risk gates are mandatory for every factory versus
  configurable by a trusted factory owner?
- Which headless agent CLIs and versions are supported at v2 launch?
- Is a graphical phase/run detail view required for v2, or is the current
  embedded UI plus CLI sufficient?
- What evidence retention, export, and operator deletion controls are required?
- What task-tracking integration is required in the Go-native model?
- Which envelope types and schema/version compatibility policy ship at v2
  launch, and which local transport adapter is first supported?

## 9. Delivery boundary

Approval of this PRD authorizes technical specification and validation of the
product contracts above. It does not authorize implementation or migration.
The specification must define the Go-native repository decomposition,
configuration/state interfaces, typed envelope notification transport, headless
execution contracts, rollout, and
quality commands while preserving the multi-project, cross-repository factory
model and the bounded execution requirements in this document.


**Runtime boundary:** tmux and interactive workers are legacy Sergeant concerns
and are out of scope as Sergeant v2 runtime dependencies. They may remain as
historical documentation or separately maintained legacy adapters, but no v2
factory, notification, envelope, recovery, or acceptance path may require them.
