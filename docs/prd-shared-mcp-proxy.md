# Product Requirements: MCP Server as a Proxy to the Running UI Server

Status: Draft, awaiting explicit human PRD approval

Extends: `docs/prd-sergeant-v2.md` R7.4 (the MCP surface exposes structured
run/status information for headless integrations) and §6 (MCP method
details are an implementation decision, not fixed by the PRD). Adapts the
same problem and design intent already implemented for Sergeant v1
(`cmd/sergeant-mcp`, see the v1/`main` branch's
`openspec/changes/shared-mcp-server/`) to v2's single-server architecture
— this is a re-implementation of the same product requirement, not a code
port.

## Summary

`sergeant mcp` (`cmd/sergeant/main.go`'s `startMCP()`) opens its own
`store.Open(dbPath)` fresh on every invocation — one full SQLite
connection per interactive-agent instance, the same one-process-per-client
shape that caused v1 to have 31 redundant `sergeant-mcp` processes on one
machine. This PRD requires `sergeant mcp` to become a thin proxy to the
one already-running `sergeant ui` server, instead of opening its own
database connection per instance.

## Problem

Confirmed this is the same usage pattern v1 had, not just an analogous
one: `AGENTS.md`'s "Two ways in" section names MCP as specifically the
**agent-driven** path — "the operator launches their own agent CLI
(opencode, codex, goose, pi, claude) in a terminal inside the project" —
so every terminal an operator opens with their own agent CLI loads
`mcp.json` and spawns `sergeant mcp` as its own `stdio` subprocess, and
each one independently opens the SQLite store.
`store.Open` already sets `_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)`
(`internal/store/store.go:225`), so concurrent access from many processes
is safe — this is not the correctness bug v1 had — but it is the same
redundant-process, redundant-connection waste v1 identified and fixed
(support #42), just smaller in magnitude because a direct Go+SQLite
connection is cheaper than v1's exec-a-bash-script-per-tool-call design.

Unlike v1, v2 does not need to solve the hard half of the problem v1
faced: v1 had no canonical always-running process, so it had to invent a
PID-recording lock file to decide which client becomes the shared server
and how late clients discover it. v2 already has exactly that canonical
process — `sergeant ui`, which the existing restart convention already
expects to be running independently of any MCP client — so the discovery
problem is already solved by the architecture, not something this PRD
needs to build.

## Proposal

`sergeant mcp` stops calling `store.Open` and stops holding its own
database connection. Instead, on each MCP tool call, it makes an HTTP
request to the already-running `sergeant ui` server (loopback-only, per
the existing `127.0.0.1` binding decision cited in
`docs/prd-native-desktop-app-packaging.md`) and relays the result back
over `stdio` to the calling harness — a thin protocol translator, not an
independent data-access layer.

- **`sergeant mcp` auto-starts `sergeant ui` if it isn't already
  running**, rather than failing closed and telling the operator to
  start it themselves — settled below.
- `sergeant mcp` becomes stateless with respect to the database: it
  holds no connection, so N concurrent instances cost N thin HTTP
  clients, not N SQLite handles.
- If, after attempting to start it, `sergeant ui` still isn't reachable,
  `sergeant mcp` fails closed with a clear, actionable error rather than
  silently falling back to opening its own database connection — a
  fallback would quietly reintroduce the exact problem this PRD closes.

### Every current MCP tool needs a real REST counterpart — most don't have one yet

This was flagged as needing validation rather than assumed, and the
validation shows the opposite of the optimistic read: `internal/mcp/server.go`'s
`executeTool` does **not** call any `internal/ui` HTTP handler today. It
calls `s.Store.*`/`config.LoadProject`/`runner.PhaseRunner` directly — a
fully separate code path from `internal/ui/server.go`'s REST handlers,
even though both ultimately touch the same `store.Store`. Per
`AGENTS.md`'s "Two ways in" split, this is structural, not an oversight:
MCP is explicitly the **agent-driven** path's interface (an operator's
own agent CLI, running interactively in a terminal), while `/api/*` is
the **coordinator-driven** path's interface (the dashboard dispatching
headless runs) — two different callers, so no REST endpoint was ever
built for several of these tools:

- **Have a reasonable existing/near-equivalent:** `sergeant_status` →
  `/api/runs`/`/api/projects` combined; `sergeant_run_status` →
  `/api/run-details`.
- **Have no REST equivalent at all today, confirmed by reading the
  handler:** `sergeant_get_brief` (renders an intent brief directly from
  the store — no `/api/brief`-shaped endpoint exists), `sergeant_run_gates`
  (actually *executes* test/lint gates via `runner.PhaseRunner` against
  a resolved worktree path — a real local side effect, not a query),
  `sergeant_emit_envelope` (a worker-side handoff write), `sergeant_seal_pr`
  (the agent-driven path's own PR-sealing action, distinct from the
  coordinator-driven `/api/create-pr`), and all three graph tools
  (`sergeant_graph_query`/`_explain`/`_affected` call `internal/graphify`
  directly; `/api/build-graph` only builds a graph, it doesn't query
  one).
- **Needs new semantics, not just a new route:** `sergeant_run_wait`
  blocks until a run reaches a terminal status — REST's other endpoints
  are all single-shot query/action calls; this needs either a genuine
  long-poll endpoint or a translation layer over the existing
  `/api/stream` SSE feed.

So this PRD's actual scope is larger than "point the existing surface at
a proxy": most of the interesting tools need a **new** `/api/*` endpoint
built first (a thin HTTP wrapper around the same underlying
Store/PhaseRunner/graphify calls `executeTool` already makes — the
business logic doesn't need to change, only which process it runs in),
and only then does `sergeant mcp` stop calling them directly.

## Non-Goals

- Porting v1's Unix-socket/PID-lock-file mechanism. v2 does not need it:
  the shared process already exists and is already expected to be
  running.
- Changing what `sergeant ui`'s existing `/api/*` endpoints do. This PRD
  is about which process answers an MCP tool call, not the endpoints'
  own behavior.
- Authentication beyond the existing loopback-only binding. No new
  multi-tenant or remote-access surface is introduced.

## Acceptance Criteria

- `sergeant mcp` makes zero calls to `store.Open` (or any other direct
  SQLite access) — grep-verifiable at implementation time.
- Every one of the 9 tools in `Tools()` is served by relaying to a
  `sergeant ui` HTTP endpoint, with identical tool-call results to
  today's direct-access behavior — including the 6 tools confirmed
  above to need a genuinely new endpoint, not just the 2-3 with a
  near-equivalent already.
- `sergeant mcp` starts `sergeant ui` itself if it finds it isn't
  already running, before falling back to a clear, actionable error.
- N concurrent interactive-agent instances produce N thin `sergeant mcp`
  client processes and zero additional database connections, measurably
  distinct from today's N-connections behavior.
- Regression coverage for at least one MCP tool call from each of the
  three categories above (near-equivalent, new-endpoint, new-semantics)
  succeeding via the proxy path end-to-end against a real running
  `sergeant ui` instance.

## Settled Decisions

1. **`sergeant mcp` auto-starts `sergeant ui`** if it isn't already
   running, rather than requiring the operator to start it manually
   first.
2. **The existing REST surface does not cover the current MCP tool
   set** — validated by reading `executeTool`, not assumed. 6 of 9
   tools need either a new endpoint or new semantics (see Proposal);
   only `sergeant_status`/`sergeant_run_status` have a reasonable
   existing near-equivalent. This PRD's scope includes building those
   new endpoints as thin wrappers around the same underlying calls
   `executeTool` already makes, not just rewiring `sergeant mcp`.

## Open Questions

1. Does this change anything about how `sergeant mcp` itself is
   packaged/distributed (e.g. relative to the desktop-app packaging in
   `docs/prd-native-desktop-app-packaging.md`), given it becomes a much
   thinner binary? Leaning toward "maybe" — worth a look once the
   desktop-packaging PRD is further along, not blocking this one.
2. For `sergeant_run_wait`'s blocking semantics: a genuine long-poll
   endpoint, or a client-side translation over `/api/stream`'s existing
   SSE feed? Either satisfies the tool's contract; which is less new
   surface to maintain is an implementation call.
3. For `sergeant_run_gates`/`sergeant_seal_pr`/`sergeant_emit_envelope`
   (agent-driven-path actions with real local side effects): does
   proxying them over loopback HTTP to `sergeant ui` change any
   trust/identity assumption `runner.PhaseRunner` currently makes about
   running in the same process as the caller? v2's single-machine,
   local-first model suggests no (both processes are still on the same
   host), but worth confirming against `runner.go`'s actual assumptions
   before implementation.
