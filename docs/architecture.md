# Sergeant v2 — Architecture Overview

This document explains how sergeant-v2 is put together, why it is shaped
the way it is, and how it differs from sergeant v1 (the bash/tmux tool it
replaces). It is written for someone who has never read this codebase but
wants a working mental model of the whole system before diving into code.
It is a companion to `docs/prd-sergeant-v2.md` (the binding product
requirements and settled decisions this document explains and cross-links)
rather than a replacement for it — where a design choice traces back to a
specific PRD decision (`D1`, `R3.5`, `O3`, etc.), that decision is named so
you can go read its exact wording.

The doc has four parts: the core data model, how work actually gets
dispatched and executed, the observability/integration surfaces built on
top of that (dashboard, MCP, redaction), and a direct comparison against
v1.

## Data Model and Store

Sergeant-v2's entire domain model lives in `internal/store/store.go`, a
single ~1,500-line file wrapping SQLite (`modernc.org/sqlite`). There is no
ORM and no separate migration tool: `Store.migrate()` runs
`CREATE TABLE IF NOT EXISTS` for the full schema, then two idempotent
passes — `migrateAddTables` (proves via `PRAGMA` that a table the code
queries actually exists) and `migrateAddColumns` (a literal list of every
column ever added, each with an `ALTER TABLE ... ADD COLUMN` and a comment
explaining why it exists and what its default means for pre-existing rows).
This is deliberate: a reopened database from an earlier version of
sergeant must come up schema-complete without a separate migration step to
remember to run.

**The domain hierarchy is `Project → Intent → Bullet`.** A *Project* is a
named set of repositories. An *Intent* is "a durable statement of desired
change; may span repos" — the PRD calls it the primary durable object:
"the system exists to satisfy intents. Runs, phases, worktrees and
sessions all exist to serve an intent. They are not the thing being
tracked." A *Bullet* is a tracer bullet scoped to **exactly one**
repository — "a vertical slice through that repo's stack, not a
horizontal slice across repos. Work in a second repository is a second
bullet." The rationale is atomicity: Git provides atomic commits
per-repository but has no cross-repository transaction, so if a bullet
spanned two repos there would be no way to say "this unit of work landed"
— one repo could commit while the other failed. Making the bullet
single-repo pushes cross-repo *ordering* up to the Intent (via each
bullet's `Position` field, "merge order within the intent") rather than
pretending Git can do something it can't.

Run, Phase, and Envelope are all subordinate to this. A `RunRecord` is one
dispatch attempt; it carries `IntentID` (which intent it serves) and
`ChangeID` (which OpenSpec change authorized it — set once at resolution
time). A `PhaseRecord` is one step of a run (an agent invocation or a
deterministic gate). An `EnvelopeRecord` is a typed handoff/notification
message. None of these three is the dashboard's primary object — that's
Intent (decision D8) — because a run can fail and be redispatched, but the
intent persists as "the thing sergeant is trying to satisfy" across
however many run attempts it takes.

**Bullet lifecycle** (`BulletStatuses()`): `proposed → pending → red →
green → sealed → merged`, with `blocked`/`failed` as terminal alternatives
reachable from *any* state (they sort last in the list for exactly this
reason — they're not a seventh step, they're an exit ramp). Concretely:

- **`proposed`** — part of a plan awaiting human approval (decision
  D5a/D2); nothing has run yet.
- **`pending`** — approved/dispatched, no gate evidence recorded.
- **`red`** — a failing gate result has been recorded on purpose, before
  the fix — this is TDD evidence (decision D3), not an accident:
  "Red→green is evidence, produced by deterministic gates with no model
  judgment."
- **`green`** — gates pass. `BulletProgression()` (the subset used to
  render lifecycle order, deliberately excluding `failed`) stops meaning
  anything past here without a human.
- **`sealed`** — a human explicitly approved delivery (opened a PR);
  requires green.
- **`merged`** — sergeant *observed* the PR as merged. Sergeant itself
  never merges (decision D6), so this status is only ever set by watching
  real PR state, never by sergeant's own action.
- **`blocked`** — carries a `BlockedReason`; replaces `failed` as of a
  recent change, though `failed` remains a valid value on historical rows
  the migration doesn't rewrite.

**Intent lifecycle** is derived, not assigned: `DeriveIntentStatus(bullets)`
returns `satisfied` only when *every* bullet of the intent is `merged`,
otherwise `in_progress` (with an explicit empty-set guard so a zero-bullet
intent isn't vacuously "satisfied"). Since `merged` only ever comes from
observed external PR state, this is the same non-negotiable property
propagated up: no code path can mark an intent complete by fiat.
`RecomputeIntentStatus` re-derives and writes only on change, so a no-op
recompute publishes no transition event.

**Envelopes** are the durable, typed notification/handoff primitive
(decisions R5.1/R5.2). `RecordEnvelope` enforces at write time that
`Type`, `SchemaVersion`, `Producer`, and `CorrelationID` are non-empty, and
refuses re-insertion of an existing `ID` (`ErrDuplicateEnvelopeID`) —
envelopes are immutable once published. `CorrelationID` ties every
envelope in a run together (set to the run ID); `CausationID` chains one
envelope to the specific prior envelope that caused it, via
`CausationFromLatest`. Every `RecordPhase`/`RecordEnvelope` call also runs
through `redact.Text`/`redact.JSON` unconditionally — a deliberate choke
point ("rather than trusting each call site to remember to redact") after
several point-fixes at individual call sites kept leaking secrets that
were built the same way elsewhere.

**Correlation end-to-end**: from any `RunRecord` you have `IntentID`
(which intent) and `ChangeID` (which OpenSpec change authorized it,
resolved once and never re-derived — a recent fix specifically closed a
bug where re-resolving the change at a later step could silently pick a
different one). From `IntentID` you get every `BulletRecord` via
`ListBulletsForIntent` (ordered by `Position`, i.e. merge order), each of
which independently tracks its own `Branch`/`Worktree`/`CommitSHA`/`PRURL`/
`Status`. This is the full audit chain: given a run, you can always answer
"what intent, what change, what repos, what state" without a join table —
every link is a plain foreign-key-shaped string column, walkable in either
direction.

## Dispatch and Execution

Sergeant's execution engine is reachable two ways — decision **D1, "two
ways in, one set of records"**: an operator's own agent CLI can talk to
sergeant over MCP (`sergeant_get_brief`, `sergeant_run_gates`,
`sergeant_emit_envelope`), or the embedded dashboard can `POST
/api/dispatch` directly. Both converge on the exact same intents, bullets,
and evidence records — there is no separate "agent-driven" data model. An
agent following its own plan and an operator clicking dispatch produce
identically-shaped, identically-auditable history.

**Decision O3** requires every dispatch to resolve to an OpenSpec change
before anything else exists. `handleDispatch` enforces this by literal
code ordering: it resolves the change (an existing one by id, or a fresh
one scaffolded from the brief) *before* any run row, intent, or worktree
is written. The rationale is blunt: "a failure here would leave behind
dispatched work with no planning record — exactly what O3 forbids." If
change resolution fails, nothing else has happened yet to clean up.

Once a change is resolved, sergeant decides *how* the work gets
decomposed into repository-scoped bullets — and here **D2** ("trust the
workflow, review the inference") draws a hard line. If the caller names
its own target repositories explicitly, that decomposition is
*workflow-defined*: someone already decided which repos are in scope, so
sergeant treats it as pre-trusted and executes immediately. If the caller
names none, sergeant would otherwise have to guess (historically, it
silently defaulted to "every repo in the project"), and D2 refuses to let
that guess run unsupervised. Instead it's recorded as a `proposed` intent
with `proposed` bullets — no run, no worktree, no branch — and a human
must explicitly approve or reject it via a separate endpoint before any of
it executes. This is **D5(a)**, the first of D5's three legitimate human
interruptions: sergeant will notify and wait rather than act on a
decomposition nobody looked at. Critically, the change resolved at
proposal time (its id and owning repo) is persisted on the intent itself
and reused verbatim on approval — approval does not re-derive the change,
because re-resolving with different inputs could silently produce a
different change or pick a different repo than what the human actually
reviewed.

Whichever path a bullet takes, execution always lands in an isolated git
worktree. `prepareWorktree` refuses outright if the target isn't a real
git repository — "we cannot isolate. Refuse rather than silently mutating
the configured directory" — and otherwise creates a dedicated worktree and
branch (`sergeant/<run-id>`) under a per-run fleet directory, never the
operator's live checkout. Resuming an interrupted run reattaches to an
existing worktree/branch rather than recreating it: `git worktree add` is
called without `-B`, deliberately, because resetting the branch on resume
would discard whatever commits the earlier attempt already made. An
agent's dispatched work and an operator's own uncommitted state can never
collide, and a resumed run can never eat its own prior progress.

TDD is enforced structurally, not requested politely — **decision D3**. A
bullet must produce a *failing* gate result before implementation and a
*passing* one after; `RecordRedState` runs the repo's configured gates and
errors out if every one of them already passes, because that means "the
work was not test-first." `RecordGreenState` runs the same gates and
requires all of them to pass. Both go through `recordGateStage` →
`PhaseRunner.RunCodeGate`, the single code path that executes and records
a gate result, so there's exactly one way a "passed" or "failed" gate fact
gets created — no model ever judges whether a gate passed. A pure refactor
with no natural failing state can't just skip this: it requires an
explicit `RecordRedExemption` with a non-empty reason, durably recorded as
its own phase, so a skipped red state is a visible, deliberate operator
statement rather than something that quietly never happened.

When a run concludes, its outcome propagates to every bullet it covers. A
passed run advances its bullets to `green`. A failed run advances them to
`blocked` — not `failed` — carrying a human-readable reason: either
something the agent explicitly reported (via a `blocked_reason` in its own
envelope), or, failing that, a synthesized reason ("gates did not pass; no
further automatic attempt available"). This is **D5(b)**, the second
interruption: a bullet that can't get itself to green is a decision point
for a human, not a silent dead end, and the reason is what makes that
decision point actionable instead of just a status word.

The last interruption, **D5(c) / R3.5**, gates the one truly
irreversible-feeling step: opening a pull request. `POST /api/create-pr`
calls `SealBulletForRun` *before* it ever invokes `gh` — a bullet that
isn't `green` is refused outright, so approval is a real precondition on
the action, "not a status update tacked on after the fact." A successful
call durably seals the bullet, recording that a human took the explicit
delivery action. Sergeant stops there: **decision D6** says sergeant never
merges anything itself, ever — it only observes real PR state to know when
a bullet's upstream dependencies have actually landed before releasing the
next one in sequence. Sergeant can be the thing that opens a PR; it is
never the thing that makes the irreversible cross-repo change stick.

## Observability, Integration, and Redaction

**The dashboard renders a definition, not a history.** Decision D8 says
the embedded UI is a view of *intents*, not a log of runs. Concretely, `GET
/api/workflow?project=&repo=` (`internal/ui/workflow.go`) derives a repo's
entire workflow graph from configuration — `factory.pipeline` stages,
`factory.gates`, and the fixed bullet lifecycle (`store.BulletProgression()`)
— before a single phase has executed. Real execution state (from phase
records and, as of this session, real bullet status) is then overlaid onto
that pre-existing shape client-side (`buildGraphLayout`/`laneHTML`/
`nodeCardHTML` in `index.html`). This inversion matters: a matrix built
only from phases that already ran can only ever answer "what happened" —
an unstarted stage is simply absent, and an operator has no way to see
what a run is *going to do*. Deriving the skeleton from config first means
an unstarted gate still renders, greyed out, in its correct position — the
dashboard answers "where are we in the plan" the way a CI provider's job
graph does, not "what logs exist."

**No build step, and the cost of that.** The whole embedded UI is one
Go-embedded `index.html` (`//go:embed`) containing a large inline
`<script>` block — no bundler, no frontend framework, no separate build
pipeline. This is a deliberate simplicity choice consistent with the
project's "single binary, local-first" posture: `go build` produces the
entire product, dashboard included. The real cost showed up directly in
this codebase's history: `go build`/`go test` execute zero of that
JavaScript, so a duplicate top-level `const` declaration (a hard
`SyntaxError`) shipped silently and broke *every* dynamic part of the
dashboard — project list, run list, everything — for a full day before
anyone noticed, because nothing in CI could have caught it. The fix was
one line; the lesson was that this architecture needs its own verification
step (a plain `node --check` against the extracted script) that the Go
toolchain will never provide for free.

**Live updates ride one sequence-numbered SSE stream, not polling.**
`internal/ui/stream.go` exposes a `text/event-stream` endpoint backed by
`Store.SubscribeChanges()`: every state transition (phase, envelope,
bullet, delivery) is appended to an ordered `changes` table and broadcast
with a monotonic sequence number. A client connects, receives a snapshot
at its current sequence, and thereafter replays only events after the
last one it saw — reconnecting via the browser's native `Last-Event-ID`
mechanics rather than re-fetching the world. Decision D10 explicitly
borrows this "subscribe / snapshot / replay from last sequence" shape from
the Agent Host Protocol's already-settled design (AHP `runAutomation` +
sequence-numbered subscribe), without adopting AHP as an actual wire
protocol — the reasoning given is that AHP is five months old with a
pre-1.0 client and still reserves the right to break, so sergeant borrows
the *pattern* it got right rather than taking on that dependency.

**MCP is the agent-facing half of "two ways in, one set of records" (D1).**
Agent-driven work (an operator's own CLI agent talking to sergeant
directly) and coordinator-driven work (dispatch through the HTTP API) must
produce identical intents, bullets, and evidence — MCP is not a second,
parallel execution path. Its tool surface (`internal/mcp/server.go`):
`sergeant_status` and `sergeant_get_brief` for situational awareness;
`sergeant_run_gates`, which executes a repo's configured deterministic
checks and is explicitly the *zero-token* half of the factory model — no
model judgment, just pass/fail evidence a bullet's red→green history
depends on (D3); `sergeant_emit_envelope`, the durable, typed, versioned
handoff record between phases (R5); `sergeant_seal_pr`, the
human-approval-gated delivery action (R3.5); `sergeant_run_status`/
`sergeant_run_wait` for an agent to follow a run it dispatched without
polling the dashboard; and `sergeant_graph_query`/`sergeant_graph_explain`/
`sergeant_graph_affected` (D9), which let an agent navigate a codebase's
actual structure instead of grepping blind.

**graphify is orchestrated, not reimplemented.** D9's cross-repository
code graph is built by shelling out to a separately-installed `graphify`
CLI binary — extracting per-repo graphs, merging them, and answering
queries against the merged result — never by sergeant's own graph
algorithms. This boundary was tested directly when `exclude_patterns`
needed implementing: the real binary's `extract` subcommand has no exclude
flag at all, so filtering had to become a sergeant-side post-processing
pass over the binary's already-produced `graph.json` (dropping matching
nodes/edges, then anything left dangling) rather than a flag threaded
through to the tool. The binary does the extraction; sergeant only curates
what crosses the boundary.

**Redaction lives at chokepoints, not at every call site — the hard way.**
R4.4/R4.5 require captured output to be scrubbed of secret-shaped
substrings (provider API keys, `Authorization: Bearer` headers,
credential-shaped `NAME=value` lines) and size-bounded before it's
durably stored. The current architecture applies this inside
`Store.RecordPhase`/`Store.RecordEnvelope` themselves — the two functions
every phase or envelope record passes through regardless of which of a
dozen call sites built it — rather than trusting every individual writer
to remember to redact. This wasn't the first design: it replaced a
strategy of redacting at each call site individually, which repeatedly
missed one (an agent-authored envelope field here, a gate's raw command
there) every time a reviewer looked closely, because "did every caller
remember" doesn't scale as call sites multiply. Centralizing the guarantee
at the two write chokepoints made it structurally impossible for a new
caller to bypass, which is the difference between a policy and an
architecture.

## v1 vs v2

**v1** (branch `main` of `sergeant`) is a bash toolbelt: roughly 30
`bin/sgt-*` scripts (`sgt-dispatch`, `sgt-watch`, `sgt-respond`,
`sgt-cleanup`, `sgt-validate`, `sgt-review-findings`, `sgt-recover`, etc.)
sharing a 55KB common library, `bin/_sgt-lib.sh`. `sgt-dispatch` reads a
project YAML from `~/.config/sergeant/`, creates one Git worktree per
owning repository, and launches an agent by opening a **tmux window** in a
shared `sgt` session (`tmux new-session -d -s "$TMUX_SESSION"`, then `tmux
new-window` per repo). Per-task state lives in flat files under
`~/.local/share/sergeant/fleet/<task>/<repo>/`: a `tmux_session` file
records which tmux session owns the pane, plus diagnostic files written on
failure. `sgt-watch` supervises a dispatched task by polling in a `while
true; do ...; sleep "$POLL_INTERVAL"; done` loop, reading tmux pane output
and fleet files each cycle — there is no queryable store, only files and a
live terminal multiplexer. `sgt-status` is literally `git status
--porcelain` looped over each repo in the project YAML; it has no notion
of "work" beyond raw Git state. v1's own docs are explicit that "Fleet
state is operational evidence, not a replacement for Git, task, PR, or
validation state" and that "A live process is not proof of progress" —
i.e., v1 itself documents that a tmux pane existing tells you almost
nothing.

**v2** (branch `v2`) replaces the entire toolbelt with a single Go binary
(`cmd/sergeant`, plus an MCP server at `cmd/sergeant-mcp`) built from a
real internal package tree: `internal/store` (SQLite via the pure-Go
`modernc.org/sqlite` driver, opened with WAL journaling and a
busy-timeout pragma), `internal/dag` (the run engine), `internal/ui` (an
embedded HTTP dashboard served from `//go:embed static/*`), `internal/
handoff` (typed envelopes), `internal/config`, `internal/graphify`, and
`internal/mcp`. Process execution is native `os/exec` — `internal/dag/
engine.go` shells out to `git` directly (`exec.Command("git", "-C", dir,
"rev-parse", "--git-dir")`, `exec.CommandContext(ctx, "git", args...)` for
worktree add/commit) rather than opening a terminal pane. Isolation is a
per-run Git worktree and branch created by the engine itself, not a tmux
window. There is no terminal UI at all — operators watch a run through the
embedded dashboard (HTTP, backed by the same SQLite rows) or through MCP
tools.

The single most important structural difference is not "bash vs. Go" but
what each system treats as the unit of tracked work. In v1, "what work is
happening" is reconstructed at read time from tmux pane state plus
scattered fleet files plus live Git status — there is no row anywhere that
says "this piece of work exists, here is its state." v2 makes this
explicit via the `Project → Intent → Bullet` domain model. Decision **D4**
states this plainly: "Sergeant stores intents and bullets itself. Intents
and bullets are first-class rows in Sergeant's own store with referential
integrity to worktree, branch, commit and PR. Sergeant cannot enforce
rules about data it does not own." Decision **D8** extends this to the
dashboard itself: "The dashboard is a view of intents... The primary list
is intents, not runs... Runs and phases are drill-down evidence beneath a
bullet, never the top-level object." So where v1 has no durable object for
"the work" at all, v2 has one with defined lifecycle states that the
store, the dashboard, and the gates all read and write against the same
rows.

v2's `AGENTS.md` states decision **D7** verbatim: "**v1 is not a
dependency.** Sergeant must not shell out to `sgt-*`, adopt v1's fleet
file layout, or reuse its supervision plumbing. Where a v1 capability is
absent, that is unimplemented v2 scope." Concretely, `AGENTS.md` forbids
calling `sgt-dispatch`, `sgt-watch`, `sgt-respond`, `sgt-validate`,
`sgt-context`, or any other `bin/sgt-*` script; forbids using tmux to run
or supervise work; and forbids writing into `~/.local/share/sergeant/
fleet`. Where v2 is missing something v1 could do, the document is
explicit that this is a scope gap in v2, not a defect to be patched by
falling back to v1: "Where v1 has a capability v2 lacks (td tasks,
canonical intent files, independent review workers, the shipping gate),
that is **unimplemented v2 scope**. Do not close the gap by shelling out
to v1."

That same sentence names the capabilities v2 has not yet replicated:
**td task-tracker integration** (v1's `sgt-td-create`, `sgt-td-list`,
`sgt-td-memory` scripts write tasks into Marcus `td`; v2's PRD lists "task
adapter integration" as an unresolved implementation decision and "What
task-tracking integration is required in the Go-native model?" as an open
product question); **independent review workers** (v1 dispatches a
dedicated reviewer via `bin/sgt-review-findings`, routing structured
findings back into `td` and fleet supervision — v2 has no equivalent
standalone review-worker phase yet); and **the shipping/quality gate**,
v1's `bin/sgt-no-mistakes-finding`, which "validates one explicit final
shipping boundary" — v2 has deterministic code gates (D3, R2.5) but not
this specific v1 gate command. Whether v1 is retired outright once these
gaps close, or continues to exist indefinitely as its own separate tool,
is stated nowhere in either branch's docs — it is an explicitly open
question this project has not yet decided.

On why the rewrite happened: neither branch's docs state an explicit
"bash/tmux was broken because X" rationale. The closest the PRD comes is
describing v2 as replacing "interactive tmux workers and the shell
supervision plumbing built around them with Go-native coordination,
deterministic code gates, and durable records" — a stated direction, not a
stated failure. Reading v1's actual scripts, three structural weaknesses
are inferable rather than asserted: (1) state that exists only inside a
live tmux session — `sgt-dispatch` requires "an interactive coordinator
tmux pane" and fails loudly if no tmux server is reachable, meaning
supervision has a hard runtime dependency on a terminal multiplexer being
alive; (2) no durable, queryable evidence of what an agent actually did —
v1's fleet directory holds ad hoc files (a `tmux_session` marker,
diagnostic text) rather than structured records, and `sgt-watch`'s only
mechanism is a polling loop over that scattered state; (3) v1's own
documentation concedes the live-process-as-evidence problem directly ("A
live process is not proof of progress"), which v2 turns into an enforced,
tested product rule (R2.6, R3.4) rather than a documented caveat.
