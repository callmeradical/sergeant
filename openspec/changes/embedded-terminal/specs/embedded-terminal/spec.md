# Embedded terminal

## ADDED Requirements

### Requirement: Opening a terminal starts a real, interactive shell process

A terminal session SHALL be backed by a real PTY-attached shell process,
not a simulated or logged output stream, so interactive programs behave
exactly as they would in any terminal emulator.

#### Scenario: Starting a session spawns a real process and returns its identity

- **WHEN** `POST /api/terminal-start` is called with no body fields
- **THEN** the response contains a session id, a real process id, and the
  resolved shell path, and that process id is a live process on the host

#### Scenario: A client can send input and receive the shell's real output

- **WHEN** a WebSocket client connects to `/api/terminal-socket?id=<id>`
  for a started session and sends the bytes for `echo hello\n` as a binary
  frame
- **THEN** the client receives binary frames whose bytes contain `hello`

### Requirement: Concurrent sessions are independent

Multiple terminal sessions SHALL run as independent processes; input to one
session's PTY SHALL NOT be visible to, or affect, any other session.

#### Scenario: Input to one session does not appear in another

- **WHEN** two sessions are started and a command is sent to the first
  session's socket only
- **THEN** the second session's socket receives no output produced by that
  command

### Requirement: Killing a session terminates its process and frees its resources

An explicit kill request SHALL terminate the session's underlying process
and remove it from the set of known sessions, so it cannot be written to,
resized, or connected to afterward.

#### Scenario: An explicit kill request terminates the underlying process

- **WHEN** `POST /api/terminal-kill` is called with a started session's id
- **THEN** that session's process is no longer running, and a subsequent
  request naming the same id is treated as unknown

#### Scenario: Killing an unknown or already-dead session is not an error

- **WHEN** `POST /api/terminal-kill` is called with an id that was never
  started, or was already killed
- **THEN** the response reports success, not an error

#### Scenario: A process that exits on its own is reported before the socket closes

- **WHEN** a session's shell process exits without an explicit kill request
  (for example, the operator types `exit`)
- **THEN** the connected WebSocket receives a text frame naming the exit
  before the connection closes

### Requirement: A session may start in a specific bullet's worktree

Starting a session SHALL accept a bullet id in place of an explicit
working directory, and SHALL resolve it to that bullet's real worktree
path, so an operator can go directly from a bullet's blocked state to a
shell open in the exact worktree that produced it.

#### Scenario: Starting a session with a bullet id sets its working directory

- **WHEN** `POST /api/terminal-start` is called with a known bullet's id
  instead of an explicit `cwd`
- **THEN** the started session's working directory is that bullet's
  worktree path, and the response's `cwd` field names it

#### Scenario: An explicit cwd and a bullet id are mutually exclusive

- **WHEN** `POST /api/terminal-start` is called with both `cwd` and
  `bullet_id` set
- **THEN** the request is refused with an error, and no process is started

### Requirement: Resizing updates the PTY's real terminal dimensions

A resize control message SHALL update the PTY's actual window size, not
merely a client-side display value, so a program running inside the
session that queries its terminal dimensions observes the change.

#### Scenario: A resize control message changes the PTY's window size

- **WHEN** a connected session's socket sends a text frame
  `{"type":"resize","cols":100,"rows":40}`
- **THEN** a program in that session that queries its terminal size (for
  example, `stty size`) reports the new dimensions

### Requirement: The terminal endpoints are reachable only from the local machine

The server SHALL remain bound to `127.0.0.1` for the terminal routes, the
same as every other route, so shell access is never reachable from
another machine on the network. This is an inherited property of the
existing server, not new enforcement this proposal adds — the scenario
confirms it holds for these new routes too, since a regression here would
be a real security exposure.

#### Scenario: The server does not bind beyond loopback for the new routes

- **WHEN** the server that serves `/api/terminal-start`,
  `/api/terminal-socket`, and `/api/terminal-kill` starts listening
- **THEN** it is bound to `127.0.0.1`, the same address every other route
  is served from — not `0.0.0.0` or any other interface
