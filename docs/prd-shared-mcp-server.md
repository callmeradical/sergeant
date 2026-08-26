# Product Requirements: Shared MCP Server Process

Status: Draft, awaiting explicit human PRD approval

Pinned source baseline: `9d9fb612bdb356964bf250904117ece0b3935af8`

Source: Deloitte support [#42](https://github.com/Deloitte-US-Ascend/ascend-pm-sergeant-support/issues/42)

## Summary

Every interactive-agent instance that loads the Sergeant MCP plugin today
spawns its own private `sergeant-mcp` process over `stdio`, with no option to
share an already-running instance. One developer machine with 31 concurrent
interactive-agent instances open had 31 separate `sergeant-mcp` processes —
confirmed to be redundant, not independent: the server holds no meaningful
per-process state (every tool call simply execs an existing shell script and
returns its output; all real state already lives externally in per-project
fleet/task directories and a SQLite-backed store). This PRD requires Sergeant
to support multiple local interactive-agent instances sharing one running MCP
server process, with no loss of functionality and no change to the tool-call
surface each instance sees.

## Problem

Baseline memory and process-table cost scales linearly with however many
interactive-agent instances a developer keeps open (~5.8 MB average per
process observed, unbounded by design), purely as a byproduct of how many
editor/terminal windows happen to be open — not anything about the work being
done. Worse, every one of those processes is a redundant, uncoordinated caller
against the same shared, sometimes lock-contended, on-disk state, and that
contention gets worse under exactly the kind of concurrent-dispatch load
covered by the companion admission-control proposal (support #41 /
`docs/prd-dispatch-admission-control.md`), since process count and dispatch
load tend to rise together.

There is also currently no single place that could hold a live, authoritative,
in-memory view of "what is this machine doing right now" across every client
— a prerequisite for the kind of shared, machine-wide resource accounting
support #41 proposes. A shared server is materially easier to get right for
that purpose than N independent processes each trying to infer the same
machine-wide picture by polling the same shared files.

## Users

- **Developer running multiple interactive-agent instances:** editor windows,
  terminal tabs, or separate projects, each currently paying a redundant
  server-process cost with no ceiling.
- **Operator relying on machine-wide accounting** (support #41): needs one
  authoritative process that can hold a live view of activity across every
  connected client, rather than reconstructing it from N independent pollers.

## Outcomes

1. Multiple interactive-agent instances on one machine can share a single
   running `sergeant-mcp` server process end to end, with identical tool
   behavior to today's one-process-per-instance model.
2. The server auto-starts on first client demand: a lock file records the
   owning PID, and each client checks that recorded PID's live status on its
   own launch to decide whether to start a new shared server or connect to
   the one already running. No separate, explicit machine-setup step is
   required.
3. The shared server survives one connected instance disconnecting or
   crashing without affecting the others.
4. If the shared server process itself dies, in-flight and new tool calls
   from other clients are buffered/queued across the restart and replayed
   against the freshly started replacement, rather than failing outright or
   silently losing MCP tool access with no explanation.
5. No tool call depends on the server's inherited working directory or
   environment in a way that would silently break once one process serves
   callers with different working directories or environments. Confirmed by
   direct audit (see Settled Decisions): `SERGEANT_MODEL` and
   `SERGEANT_TMUX_SESSION` are designed to vary per invocation and must
   become explicit tool-call parameters rather than relying on
   process-environment inheritance; every other environment read is
   machine/user-wide by design (config/fleet roots, API credentials, tuning
   knobs) or test-only, and is safe to leave as inherited environment.
6. A measurable before/after: N interactive-agent instances on one machine
   produce one server process instead of N, with no increase in per-call
   latency under realistic concurrent tool-call load.
7. Every interactive-agent harness/plugin that currently speaks `stdio` gets
   an explicit client-side change to speak the shared-server transport,
   rather than relying solely on a compatibility shim to paper over the
   difference.
8. The shared server bounds concurrent script-execution concurrency
   (independent of how many clients are merely connected) so that many
   simultaneously connected clients firing tool calls at once cannot grow
   process/CPU usage unboundedly; there is no separate cap on the number of
   connected client sessions themselves, since a session alone is cheap.

## Non-Goals

- Cross-machine or remote MCP serving. This is scoped to multiple local
  clients on one developer machine.
- Choosing or vetting a specific transport implementation. The vendored MCP
  server library already offers a persistent, multi-session transport as an
  alternative to today's one-to-one `stdio` transport; which exact transport
  and discovery mechanism to use is OpenSpec's job, not this PRD's.
- Any change to what a tool call does or returns. This PRD is about how many
  server processes exist and how clients find one, not about the tool
  surface itself.
- Authentication/authorization beyond loopback-only binding for a
  single-developer-machine threat model. Multi-tenant or multi-user access
  control is out of scope.
- Implementing the machine-wide resource accounting described in support
  #41. That PRD is complementary and depends on this one being easier to
  build correctly on top of, not the reverse; this PRD does not itself
  implement admission control.

## Acceptance Criteria

- Multiple interactive-agent instances on one machine can share a single
  running server process end to end, with identical tool behavior to today's
  one-process-per-instance model.
- The shared server survives a single instance disconnecting or crashing
  without affecting the others, and if the shared process itself dies,
  in-flight and new calls from other clients are buffered/queued and replayed
  against the freshly restarted replacement rather than failing outright.
- Discovery uses a lock file recording the owning server's PID; each client
  checks that PID's live status on its own launch to decide whether to start
  a new shared server or connect to the existing one, and this resolves
  cleanly when two clients race to start at the same time.
- Every currently-`stdio` interactive-agent harness/plugin has an explicit
  client-side change to speak the shared-server transport.
- No behavior depends on the server process's inherited working directory or
  environment in a way that silently breaks once serving multiple callers
  with different working directories/environments. In particular,
  `SERGEANT_MODEL` and `SERGEANT_TMUX_SESSION` are threaded through as
  explicit per-call parameters rather than left as inherited environment.
- A measurable before/after: N interactive-agent instances on one machine
  produce one server process instead of N, with no increase in per-call
  latency under realistic concurrent tool-call load.
- Regression coverage for concurrent tool calls from multiple simulated
  clients against the shared server, including at least one call that shells
  out to the same SQLite-backed store from two overlapping calls.
- Concurrent script-execution is bounded independently of connected-client
  count; there is no separate cap on connected sessions themselves.

## Settled Decisions

1. **Discovery is a lock file recording the owning PID.** Each client checks
   that PID's live status on its own launch to decide whether to start a new
   shared server or connect to the one already running.
2. **Auto-start on first client demand.** No separate, explicit machine-setup
   step is required.
3. **Client-side change, not a compatibility shim.** Every currently-`stdio`
   interactive-agent harness/plugin gets an explicit change to speak the
   shared-server transport, rather than leaning on a shim to paper over the
   difference invisibly.
4. **Buffer/queue across a restart.** If the shared process dies mid-session,
   in-flight and new calls from other clients are buffered/queued and
   replayed against the freshly restarted replacement, rather than failing
   outright.
5. **Environment-variable audit (resolved by direct inspection of
   `cmd/sergeant-mcp/main.go` and every `sgt-*` script it execs).** The MCP
   server itself reads zero environment variables directly — it forwards its
   own inherited environment wholesale (`cmd.Env = os.Environ()`) to every
   exec'd script, and depends on neither the caller's working directory
   (confirmed unused, matching the existing PRD assumption) nor any env var
   of its own. The risk is entirely in what the exec'd scripts read from that
   forwarded environment, which is fixed at whichever instance's environment
   the shared server happened to inherit at first start:
   - **Must become an explicit per-call parameter, not inherited env:**
     `SERGEANT_MODEL` (read by `sgt-dispatch`, `sgt-recover`,
     `sgt-session-resume` — all three exposed as MCP tools — to pin a
     per-invocation model/effort override) and `SERGEANT_TMUX_SESSION` (read
     by `sgt-dispatch`; its own comment invites task-scoped overrides
     per-call: `"Override with SERGEANT_TMUX_SESSION=<name> if you want
     task-scoped sessions"`). Both are designed to vary per invocation, so a
     shared process silently freezing either one at whichever value the
     first-starting instance happened to have set would give every other
     connected instance the wrong model/effort or the wrong tmux session with
     no error.
   - **Lower-priority, plausible but not confirmed as actually varied
     per-instance in practice:** `SERGEANT_NOTIFY_TRANSPORT` (a
     durable-vs-tmux delivery mode toggle in `sgt-notify`) and
     `WIKI_DIGEST_MODEL` (which model `wiki-daily-digest` uses to summarize —
     cosmetic, not correctness-affecting). Worth threading through
     explicitly if implementation finds real usage that varies them
     per-instance; not required to ship the first version of this PRD.
   - **Machine/user-wide by design, safe to keep as inherited environment:**
     `SERGEANT_CONFIG`, `SERGEANT_FLEET` (both default to `$HOME`-rooted
     paths and exist so every instance on one machine agrees on the same
     durable config/fleet root — the opposite of per-instance variance is the
     whole point), the LLM API key variables read by `sgt-graphify`
     (`ANTHROPIC_API_KEY`/`OPENAI_API_KEY`/etc. — a developer's credentials,
     not a per-window setting), and the various `SGT_*_TIMEOUT`/`*_INTERVAL`
     tuning knobs (machine-wide operational tuning, not per-instance intent).
   - **Test-only, out of scope for real usage:** every `SGT_TEST_*` variable
     is gated behind `SGT_TEST_HOOKS=1` and used only by this repo's own test
     fixtures; no normal interactive-agent instance sets these.

6. **Connection ceiling: bound concurrent execution, not connection count.**
   A connected client session itself is cheap — bookkeeping only, no
   persistent per-client OS resource — so there is no need for a hard cap on
   the number of simultaneously connected clients, and "connection pooling"
   in the traditional sense (reusing a limited set of persistent downstream
   connections) does not map cleanly onto this server: nothing today holds a
   persistent downstream connection to pool. The actual scarce resource is
   concurrent *script execution* — every tool call execs a real OS process —
   which today is implicitly bounded to one at a time per client only
   because each client has its own private server. Once shared, N clients
   could fire tool calls concurrently against the one shared process, so the
   shared server must bound concurrent script-execution concurrency
   (independent of how many clients are merely connected), sized to the
   machine's own capacity rather than growing unbounded with client count.
   The SQLite-backed store already has its own busy-timeout for concurrent
   access and needs no additional pooling layer on top. The exact bound
   (a fixed concurrency limit, one scaled to CPU count, or something else)
   is OpenSpec's job, not this PRD's.

## Open Questions

None outstanding for this PRD; remaining implementation choices (exact
discovery socket/lock format, transport library wiring, concurrency-limit
formula) are OpenSpec's job.
