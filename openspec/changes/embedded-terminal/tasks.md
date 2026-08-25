# Tasks — Embedded terminal

One repository, `sergeant-v2`, so one task list, no cross-repo merge order.

## Task 1 — PTY/WebSocket bridge and routes

Repository: `sergeant-v2`. Depends on: nothing.

Read first: this change's `design.md` in full; the current route
registration block in `internal/ui/server.go` (the `mux.HandleFunc(...)`
list, so the three new routes are added consistently with the existing
ones); `internal/ui/fleet.go` or `internal/ui/delivery.go` for the
extracted-type pattern (`newFleetCleaner`/`newDeliveryReporter`) this
change's `newTerminalManager` follows; `internal/store/store.go`'s
`GetBullet` (for resolving `bullet_id` to a worktree path).

Build:
- Add `github.com/creack/pty` and `github.com/gorilla/websocket` to
  `go.mod` (`go get` them; do not hand-edit `go.sum`).
- Add `internal/ui/terminal.go`: `terminalSession`, `terminalManager`, and
  its `Start`/`Write`/`Resize`/`Kill`/`Get` methods, exactly as named and
  behaved in design.md.
- Add the `terminal *terminalManager` field to `Server`, built in
  `NewServer` via `newTerminalManager()`.
- Add `handleTerminalStart`, `handleTerminalSocket`, `handleTerminalKill`
  to `internal/ui/server.go` (or a new file if that reads more like the
  existing decomposition's per-concern split — your call, but register all
  three routes in the existing mux block), implementing exactly the
  request/response/frame shapes design.md specifies.
- Do not implement the frontend drawer/tabs UI or vendor the xterm.js
  files in this task — that is Task 2, kept separate so a backend-only
  verification pass can run before any frontend change exists to obscure a
  backend regression.

Verification: `go build ./... && go vet ./internal/... && go test
./internal/... -count=1 -skip
'^(TestBuildProjectGraphAppliesExcludePatterns|TestBuildProjectGraphMergesEveryParticipatingRepo|TestIncludeGroupsExcludesNonMatchingRepos|TestBuildNeverLeavesOutputInAPartialState|TestPublishFailureRestoresPriorGraph|TestBuildNeverSpawnsSgtGraphify|TestQueryAgainstABuiltGraphReturnsAnAnswer|TestExplainAndAffectedAreDistinctFromQuery|TestMCPGraphQueryAgainstABuiltGraphReturnsAnswer|TestBuildGraphEndpointBuildsAndPublishes)$'`.

Scenarios needing direct, real-process test coverage (not a mocked PTY —
see design.md's "Rejected alternatives" on why spawning a real shell in
tests is both cheap and the stronger proof here):
- "Starting a session spawns a real process..." — assert the returned pid
  is a real, running process (e.g. `syscall.Kill(pid, 0)` succeeds).
- "A client can send input and receive the shell's real output" — a real
  `gorilla/websocket` client dialing the real HTTP test server, sending
  `echo hello\n`, asserting the byte stream contains `hello`. This is the
  one scenario that must exercise the actual WebSocket upgrade path
  end-to-end, not call `terminalManager` methods directly.
- "Input to one session does not appear in another" — two real sessions,
  two real sockets.
- "A process that exits on its own is reported..." — send the bytes for
  `exit\n` (or spawn `/bin/sh -c true` intentionally short-lived) and
  assert the exit text frame arrives before the socket closes.
- "A resize control message changes the PTY's real terminal dimensions" —
  send the resize frame, then run a real command that reports its
  terminal size and assert the reported value matches.
- "The server does not bind beyond loopback for the new routes" — this is
  a property of `Start()`'s existing `127.0.0.1` address string, already
  covered structurally; a scenario test can assert the test server's own
  listener address string, or simply cite the existing line — do not
  invent a new binding mechanism to test.

## Task 2 — Frontend drawer, tabs, and vendored assets

Repository: `sergeant-v2`. Depends on: Task 1 (the routes it calls must
exist).

Read first: `internal/ui/static/index.html`'s current structure (how
existing drawers/panels are toggled, to match the pattern); design.md's
"Frontend" section.

Build:
- Vendor `xterm.js`, `xterm.css`, `xterm-addon-fit.js` into
  `internal/ui/static/` (picked up automatically by the existing
  `//go:embed static/*`; no Go code change needed for embedding itself).
- Add the drawer/session-tabs UI and the WebSocket-based session wiring to
  `internal/ui/static/index.html`, replacing `launchpad`'s Electron IPC
  calls with `fetch`/`WebSocket` calls to Task 1's routes.
- Add the "open in this bullet's worktree" entry point on the existing
  blocked-bullet/run detail view.

Verification: same command as Task 1 (a rebuild is required for the
embedded dashboard to reflect the change, per `AGENTS.md`'s "changing
`internal/ui/static/index.html` requires a rebuild before it is served").
There is no scripted UI test in this repository's suite today; verify
manually by starting `sergeant ui`, opening a terminal, and confirming
input/output/resize/close all work, and note in the PR description that
this was checked manually.
