# Shared MCP server process

## ADDED Requirements

### Requirement: Multiple interactive-agent instances share one running server process

Multiple interactive-agent instances on one machine SHALL share a single
running MCP server backend process, with identical tool behavior to
today's one-process-per-instance model.

#### Scenario: A second instance connects to the first instance's already-running server

- **WHEN** one interactive-agent instance is already connected to a
  running shared server and a second instance starts
- **THEN** the second instance connects to the same already-running
  server rather than starting a new one, and both instances see identical
  tool behavior

#### Scenario: Two instances starting at the same moment do not both become the server

- **WHEN** two interactive-agent instances start at effectively the same
  moment with no shared server yet running
- **THEN** exactly one of them becomes the running server and the other
  connects to it as a client

### Requirement: The server auto-starts on first client demand via a PID-recording lock file

No separate, explicit setup step SHALL be required to start the shared
server. Discovery SHALL be via a lock file recording the owning server's
process ID, checked by each client at its own startup.

#### Scenario: The first client on a machine starts the server

- **WHEN** no lock file exists, or the lock file names a PID that is no
  longer live
- **THEN** the connecting client starts a new shared server and records
  its PID in the lock file

#### Scenario: A live lock is honored, not overwritten

- **WHEN** the lock file names a PID that is still live
- **THEN** a new client connects to that server rather than starting a
  second one

### Requirement: A client survives the shared server dying by buffering and replaying calls

If the shared server process dies, a connected client SHALL buffer
in-flight and new tool calls rather than failing them outright, and SHALL
replay them against a freshly (re)started server once reconnected.

#### Scenario: A call made while the server is down is not lost

- **WHEN** the shared server dies and a client sends a tool call before
  reconnecting to a replacement
- **THEN** that call is buffered and successfully delivered once the
  client reconnects, rather than returning an error to the caller

### Requirement: One client disconnecting or crashing does not affect other connected clients

The shared server SHALL continue serving every other connected client
without interruption when one client disconnects or crashes.

#### Scenario: One instance closing does not disrupt others

- **WHEN** one interactive-agent instance disconnects or crashes while
  connected to the shared server
- **THEN** every other connected instance's tool calls continue to
  succeed without interruption

### Requirement: Concurrent script-execution is bounded independently of connection count

The shared server SHALL bound how many script executions run concurrently,
independent of how many clients are merely connected.

#### Scenario: A burst of concurrent calls does not spawn unbounded processes

- **WHEN** more tool calls arrive concurrently than the configured
  execution bound
- **THEN** the excess calls wait for a free execution slot rather than all
  spawning processes simultaneously, and every call still eventually
  completes and returns its result

#### Scenario: Many connected-but-idle clients impose no execution cost

- **WHEN** many clients are connected but only a few are actively calling
  tools at a given moment
- **THEN** the number of connected clients alone does not reduce
  available execution slots for the active calls

### Requirement: Per-invocation model and tmux-session policy do not depend on inherited server environment

`SERGEANT_MODEL` and `SERGEANT_TMUX_SESSION`, confirmed to vary per
invocation, SHALL be passable as explicit arguments rather than relying on
whichever environment the shared server process happened to inherit.

#### Scenario: sgt-recover accepts an explicit model override

- **WHEN** an MCP caller invokes the `sgt-recover` tool with an explicit
  model/effort flag in its arguments
- **THEN** the relaunch honors that explicit value, taking precedence over
  any `SERGEANT_MODEL` the shared server process happens to have inherited

#### Scenario: sgt-dispatch accepts an explicit tmux-session override

- **WHEN** an MCP caller invokes the `sgt-dispatch` tool with an explicit
  tmux-session flag in its arguments
- **THEN** the dispatch uses that explicit session name, taking precedence
  over any `SERGEANT_TMUX_SESSION` the shared server process happens to
  have inherited

#### Scenario: Two instances with different intended policy do not collide via a shared server

- **WHEN** two interactive-agent instances, each wanting a different
  model/effort or tmux session for their own dispatch/recovery calls, are
  both connected to the one shared server
- **THEN** each instance's explicit per-call flag is honored independently
  of the other's, and independently of whichever environment the shared
  server process itself was started with
