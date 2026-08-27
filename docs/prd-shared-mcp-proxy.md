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

Every interactive-agent instance that loads the Sergeant MCP plugin
spawns `sergeant mcp` as its own `stdio` subprocess (`mcp.json` points at
`./bin/sergeant mcp`), and each one independently opens the SQLite store.
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

Concretely:

- The MCP tool surface `sergeant mcp` exposes today (status/run
  information, per R7.4) maps onto existing or lightly-extended
  `/api/*` endpoints on `sergeant ui` (`/api/runs`, `/api/run-details`,
  `/api/dispatch`, etc.) rather than querying `store.Store` directly.
- `sergeant mcp` becomes stateless with respect to the database: it
  holds no connection, so N concurrent instances cost N thin HTTP
  clients, not N SQLite handles.
- If `sergeant ui` is not running, `sergeant mcp` fails closed with a
  clear, actionable error (start the server first) rather than silently
  falling back to opening its own database connection — a fallback
  would quietly reintroduce the exact problem this PRD closes.

## Non-Goals

- Porting v1's Unix-socket/PID-lock-file mechanism. v2 does not need it:
  the shared process already exists and is already expected to be
  running.
- Changing what `sergeant ui`'s existing `/api/*` endpoints do. This PRD
  is about which process answers an MCP tool call, not the endpoints'
  own behavior.
- Auto-starting `sergeant ui` from `sergeant mcp`. Whether that's
  desirable is an open question below, not assumed here.
- Authentication beyond the existing loopback-only binding. No new
  multi-tenant or remote-access surface is introduced.

## Acceptance Criteria

- `sergeant mcp` makes zero calls to `store.Open` (or any other direct
  SQLite access) — grep-verifiable at implementation time.
- Every MCP tool call is served by relaying to `sergeant ui`'s HTTP API,
  with identical tool-call results to today's direct-database-access
  behavior.
- N concurrent interactive-agent instances produce N thin `sergeant mcp`
  client processes and zero additional database connections, measurably
  distinct from today's N-connections behavior.
- `sergeant mcp` reports a clear, actionable error when `sergeant ui` is
  not reachable, rather than falling back to a direct database
  connection.
- Regression coverage for at least one MCP tool call succeeding via the
  proxy path end-to-end against a real running `sergeant ui` instance.

## Open Questions

1. Should `sergeant mcp` auto-start `sergeant ui` if it isn't already
   running, or is "fail closed, tell the operator to start it" the
   right behavior given v2's existing single-long-running-server
   operating model?
2. Do any of `sergeant mcp`'s current tool calls need a new `/api/*`
   endpoint that doesn't exist yet, or does the existing REST surface
   already cover the full MCP tool set?
3. Does this change anything about how `sergeant mcp` itself is
   packaged/distributed (e.g. relative to the desktop-app packaging in
   `docs/prd-native-desktop-app-packaging.md`), given it becomes a much
   thinner binary?
