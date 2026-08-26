# Proposal — Shared MCP Server Process

## Repository

One repository: `sergeant` (v1). Touches `cmd/sergeant-mcp` (becomes the
shared backend), a new `cmd/sergeant-mcp-client` (the thin per-instance
proxy every harness now spawns), `mcp.json`, and two existing scripts
(`bin/sgt-recover`, `bin/sgt-dispatch`) that gain explicit flags so this
change does not have to invent a new MCP-level parameter-passing
mechanism.

## Requirements served

PRD: `docs/prd-shared-mcp-server.md`. Source: Deloitte support
[#42](https://github.com/Deloitte-US-Ascend/ascend-pm-sergeant-support/issues/42).

All open questions in that PRD are already settled in its "Settled
Decisions" section, including the direct environment-variable audit; this
proposal implements those decisions, it does not re-litigate them.

## Problem

`cmd/sergeant-mcp/main.go` is registered in `mcp.json` as a `stdio`
server: every interactive-agent instance that loads the plugin spawns its
own private process. One developer machine with 31 concurrent instances
had 31 separate `sergeant-mcp` processes. The server itself holds no
meaningful per-process state — every tool call (`runScript`,
`main.go:78`) just execs one of the `bin/sgt-*` scripts and returns its
output; all real state already lives externally in `$FLEET_DIR` and a
SQLite-backed message store. The 31 processes are redundant readers, not
independent views of anything.

The one thing that does vary per process today is environment: `runScript`
sets `cmd.Env = os.Environ()` (`main.go:87`), forwarding whichever
environment the spawning harness instance happened to have. A direct audit
(recorded in the PRD) found two variables that are *designed* to vary per
invocation and are read only from environment today: `SERGEANT_MODEL`
(`bin/sgt-dispatch`, `bin/sgt-recover`, `bin/sgt-session-resume`) and
`SERGEANT_TMUX_SESSION` (`bin/sgt-dispatch`). A shared process would freeze
whichever value the first-starting instance's environment happened to
carry, silently giving every other connected instance the wrong
model/effort or the wrong tmux session with no error — this proposal must
close that gap as part of sharing the process, not as an afterthought.

## Proposal

1. **Split server and client.** `cmd/sergeant-mcp` becomes the shared
   backend: it registers the existing tool set exactly as today, but
   serves over a Unix domain socket (via the already-vendored
   `mark3labs/mcp-go` Streamable HTTP transport, `NewStreamableHTTPServer`,
   served on a `net.Listen("unix", ...)` listener rather than the default
   `stdio`/TCP paths) instead of `stdio`. A new, small
   `cmd/sergeant-mcp-client` binary is what `mcp.json` now points
   at — a real, visible client-side change, not an invisible compatibility
   shim.
2. **Discovery via a PID-recording lock file, checked on each client's own
   launch.** `$HOME/.local/share/sergeant/mcp-server.lock` records the
   owning server's PID and socket path. Each client checks that PID's live
   status at its own startup: if live, it connects to the recorded socket;
   if not (or the lock is absent), it starts the shared server itself,
   records the new lock, and connects — auto-starting on first client
   demand with no separate setup step, and resolving a startup race
   between two clients via the lock file's own atomicity (matching this
   codebase's existing `_sgt_replace_owned_file`/atomic-rename convention
   for every other durable single-value record).
3. **Buffer and replay across a restart.** If the shared server dies, a
   connected client detects the broken socket, buffers in-flight and new
   tool calls in memory, re-runs the same discovery/start dance, and
   replays the buffered calls against the (possibly freshly started)
   replacement — rather than failing those calls outright.
4. **Bound concurrent script execution, not connection count.** The shared
   server gates concurrent `runScript` executions behind a bounded
   semaphore sized to detected CPU count, independent of how many clients
   are merely connected (connections themselves are cheap bookkeeping, per
   the PRD's settled decision).
5. **Close the two confirmed per-instance environment gaps with explicit
   flags, not a new MCP mechanism.** `bin/sgt-dispatch` and
   `bin/sgt-session-resume` already accept `--model <tuple>` as a
   documented CLI flag with higher precedence than the `SERGEANT_MODEL`
   env var — an MCP caller can already pass it explicitly today.
   `bin/sgt-recover` has no such flag (only the `#29` fix's env-only
   resolution); this proposal adds one, at the same precedence position
   (`flag > env > fleet record > unpinned`). `bin/sgt-dispatch` has no
   flag for tmux session name at all (`SERGEANT_TMUX_SESSION` env-only);
   this proposal adds `--tmux-session <name>` (`flag > env > "sgt"
   default`). Both scripts' MCP tool descriptions in
   `cmd/sergeant-mcp/main.go` are updated to document the new flags, the
   same way `--model` is already documented for `sgt-dispatch`/
   `sgt-session-resume`.

## Out of scope

- Any change to what a tool call does or returns.
- Multi-tenant/multi-user authentication. The Unix socket is owner-only
  (mode `0600`, matching this codebase's existing owned-file convention)
  — a single-developer-machine threat model, same as the PRD's
  loopback-only assumption.
- The machine-wide resource accounting in the companion
  `dispatch-admission-control` change. Complementary, not a dependency of
  this one.
- Auditing or changing any environment variable beyond the two confirmed
  in the PRD's audit (`SERGEANT_MODEL`, `SERGEANT_TMUX_SESSION`).
  `SERGEANT_NOTIFY_TRANSPORT`/`WIKI_DIGEST_MODEL` were flagged
  lower-priority and are not addressed by this proposal.
