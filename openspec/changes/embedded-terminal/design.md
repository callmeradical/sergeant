# Design — Embedded terminal

## Ownership

One repository, `sergeant-v2`. Touches `go.mod` (two new direct
dependencies), `internal/ui/server.go` (three new routes, one new `Server`
field), a new `internal/ui/terminal.go`, and `internal/ui/static/index.html`
plus three new vendored static files.

## New dependencies

- **`github.com/creack/pty`** for the PTY itself. It is the de facto
  standard Go PTY library (minimal API surface: `pty.Start(cmd)` returns an
  `*os.File` wrapping the master side; `pty.Setsize` handles resize), used
  by most Go terminal-emulator/dev-tool projects, and requires no cgo.
- **`github.com/gorilla/websocket`** for the WebSocket upgrade. Chosen over
  `nhooyr.io/websocket` (recently renamed to `github.com/coder/websocket`,
  which is exactly the kind of import-path churn this project's already
  lean `go.mod` — three direct deps today — has no reason to risk) and over
  `golang.org/x/net/websocket` (its own docs recommend `gorilla/websocket`
  or `nhooyr.io/websocket` instead, calling its own API "low-level and
  provides a rough interface"). `gorilla/websocket` is old enough to be
  "in maintenance mode" but that means a stable, unambiguous import path,
  which matters more here than active feature development — this project
  needs an upgrade-and-frame primitive, nothing more.

## `internal/ui/terminal.go` — session state and PTY lifecycle

Mirrors the existing extracted-type pattern (`fleetCleaner`, `deliveryReporter`)
rather than putting PTY state directly on `Server`:

```go
type terminalSession struct {
	id   string
	pty  *os.File
	cmd  *exec.Cmd
	pid  int
	shell string
	cwd  string
}

type terminalManager struct {
	mu       sync.Mutex
	sessions map[string]*terminalSession
	nextID   int
}

func newTerminalManager() *terminalManager {
	return &terminalManager{sessions: map[string]*terminalSession{}}
}

// Start spawns a real shell PTY with the given size and working directory
// (cwd empty means the sergeant process's own cwd — os/exec's existing
// default when Cmd.Dir is unset). Mirrors launchpad's pty:start exactly:
// shell is $SHELL or /bin/zsh (POSIX only — Windows PTY support is out of
// scope per the PRD), TERM=xterm-256color, COLORTERM=truecolor.
func (m *terminalManager) Start(cwd string, cols, rows int) (*terminalSession, error)

// Write forwards raw bytes to the session's PTY (the operator's keystrokes).
func (m *terminalManager) Write(id string, data []byte) error

// Resize updates the PTY's window size (pty.Setsize).
func (m *terminalManager) Resize(id string, cols, rows int) error

// Kill terminates the session's process and removes it from the map. Safe
// to call on an already-exited session (no-op, not an error) — mirrors
// launchpad's ptySessions.delete-then-kill ordering tolerance.
func (m *terminalManager) Kill(id string) error

// Get returns the session for id, or (nil, false).
func (m *terminalManager) Get(id string) (*terminalSession, bool)
```

`Server` gains one new field, built in `NewServer` exactly like `fleet`/`delivery`:

```go
terminal *terminalManager
```

## Routes

Three new routes on `internal/ui/server.go`'s existing mux, named in the
same style as `run-resume`/`run-delete`/`clean-worktrees`:

- **`POST /api/terminal-start`** — body `{"cwd": "<path>", "cols": 80,
  "rows": 24}`, all fields optional (`cwd` empty means the process's own
  working directory; `cols`/`rows` default to 80/24, matching a full-size
  fallback if the frontend's own size computation fails before its first
  resize). Optionally `{"bullet_id": "<id>"}` instead of `cwd`: the handler
  resolves it via `Store.GetBullet(id)` and uses `.Worktree` as `cwd` — the
  concrete "open a shell in this bullet's worktree" case the PRD names.
  `cwd` and `bullet_id` are mutually exclusive; both present is a 400.
  Response: `{"id": "<session-id>", "pid": 1234, "shell": "/bin/zsh",
  "cwd": "/resolved/path"}`, or a 500 with an error body if the PTY failed
  to start (e.g. `cwd` does not exist).
- **`GET /api/terminal-socket?id=<session-id>`** — upgrades to a WebSocket
  scoped to exactly that one session (one socket per session, not one
  multiplexed socket for all of an operator's open tabs — this keeps the
  protocol a plain byte pipe with a small control-frame side channel,
  instead of needing a session-id envelope on every data frame). 404 if the
  id is unknown (already killed, or never existed). Frame protocol:
  - **Binary frames, client→server**: raw bytes, written directly to the
    PTY (keystrokes/paste).
  - **Binary frames, server→client**: raw bytes read from the PTY
    (terminal output).
  - **Text frames, client→server**: a JSON control message,
    `{"type":"resize","cols":N,"rows":N}`. No other client-sent text
    message type exists in this proposal.
  - **Text frames, server→client**: `{"type":"exit","code":N}` sent once,
    immediately before the server closes the socket, when the underlying
    process exits on its own (not via an explicit kill request) — the
    frontend's equivalent of launchpad's `pty:exit` IPC event.
- **`POST /api/terminal-kill`** — body `{"id": "<session-id>"}`. Kills the
  process and removes the session. Idempotent: killing an already-dead or
  unknown id returns `{"ok": true}`, not an error — matches
  `terminalManager.Kill`'s no-op-on-missing behavior and this project's
  existing "deleting an unknown run is not an error" precedent
  (`TestDeletingAnUnknownRunIsNotAnError`).

## Frontend

`internal/ui/static/index.html` (embedded via the existing `//go:embed
static/*`, so no code change is needed to serve new files placed
alongside it) gains:

- Three vendored files: `static/xterm.js`, `static/xterm.css`,
  `static/xterm-addon-fit.js` — fetched from the `xterm`/`xterm-addon-fit`
  npm packages' published `lib`/`css` files (the same files `launchpad`
  serves directly, no bundler), and three new routes to serve them
  (mirroring how `index.html` itself is already served, with the same
  long-cache-header treatment `launchpad`'s `server.js` gives its own
  `xterm.*` assets, since these files are versioned by filename choice, not
  auto-fingerprinted).
- A drawer + session-tabs UI, structurally the same as `launchpad`'s
  `termInit`/`termNewSession`/`toggleTerminal` (a `Terminal` + `FitAddon`
  instance per session, one DOM pane per session, a tab bar), with the
  Electron IPC calls (`window.electronAPI.terminal.*`) replaced by: `fetch
  POST /api/terminal-start` to create a session, `new WebSocket(...
  /api/terminal-socket?id=...)` to open its pipe, `ws.send(bytes)` /
  `ws.onmessage` for data, a JSON text frame for resize, `fetch POST
  /api/terminal-kill` for explicit close.
- A "resolve in worktree" entry point: the existing blocked-bullet/run
  detail view gains a button that calls `POST /api/terminal-start` with
  `{"bullet_id": "<id>"}` instead of the bare "new shell" call, then opens
  the drawer with that session active.

Implementing the exact frontend markup/script changes is this proposal's
task 1; this design section states the shape, not the literal diff.

## Rejected alternatives

**Reusing the existing SSE stream (`/api/stream`, `internal/ui/stream.go`)
instead of a new WebSocket.** `handleStream` is one-directional
(server→client) by construction — it serves `text/event-stream`, which has
no client→server message channel at all; a client can only reconnect to a
new URL, never push data mid-stream. A terminal needs the operator's
keystrokes to reach the server continuously, which SSE structurally cannot
carry. This is not a close call.

**A confirmation dialog before opening a terminal.** Rejected: every other
capability this dashboard already exposes to the local operator — dispatch,
resume, PR creation, DAG save — is unrestricted, because the operator
*is* the same person who started `sergeant ui`. A terminal is more
powerful than any single one of those actions, but the trust boundary
(same local user, same machine) is identical to all of them. Gating this
one action behind a dialog the others don't have would be an inconsistent,
false sense of extra safety rather than a real one.

**Making PTY spawning a swappable `Server` field, mirroring `GHPRCreate`/
`RunShippingGate`.** Those are swapped in tests because the real thing they
call is expensive, networked, or has side effects a test must not trigger
(a real GitHub PR, a real shipping-gate command). Spawning a local shell
via `creack/pty` has none of those properties — it is fast, has no network
dependency, and is exactly the real mechanism this feature needs verified.
Tests in this proposal spawn real PTYs (e.g. running `echo hello` or `cat`)
rather than mocking the spawn call, which is a stronger, more meaningful
proof than a mock could give for this specific feature.

**Multiplexing every session over one WebSocket connection with a
session-id envelope on each frame.** Rejected for needless complexity: one
socket per session keeps the wire protocol a plain byte pipe (the common
case) with one small control-message exception (resize), rather than every
data frame needing a session id parsed out first. Browsers have no
meaningful limit on concurrent WebSocket connections to the same origin
that this feature's realistic session counts (a handful of open tabs)
would ever approach.
