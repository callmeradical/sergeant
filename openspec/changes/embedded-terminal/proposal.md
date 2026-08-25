# Proposal — Embedded terminal

## Repository

One repository: `sergeant-v2`. Standalone.

## Requirements served

`docs/prd-embedded-terminal.md` (full text). Extends D8 ("The dashboard is
a view of intents, and it renders the workflow from a definition") with a
complementary, direct-control surface — this proposal does not change what
D8 governs (how intent/bullet/run state is displayed); it adds a second,
independent capability alongside that view.

## Problem

`internal/ui/server.go` today only ever *shows* state to an operator or
takes narrowly-scoped write actions (`POST /api/create-pr`, `POST
/api/run-resume`, and so on). An operator resolving a blocked bullet —
`skills/dispatch/SKILL.md` Step 4 says to "resolve the underlying cause
directly — in the bullet's worktree" — has no way to do that from the
dashboard itself; they must find the worktree path via `GET
/api/run-details?id=` and then open their own, separate terminal. Nothing
in the dashboard today spawns a process an operator can interact with.

## Proposal

Add a terminal to the dashboard, modeled on `launchpad`'s working
implementation (`node-pty` bridged to `xterm.js` over Electron IPC),
adapted to `sergeant-v2`'s plain browser/HTTP architecture:

- A Go-spawned PTY (real shell process, not a log) per session, bridged to
  the browser over a WebSocket connection scoped to that one session.
- Multiple concurrent, independently-addressable sessions, each closeable
  without affecting the others.
- A session may optionally be started with its working directory set to a
  specific bullet's worktree path (`Store.GetBullet(id).Worktree`), so an
  operator can go from "this bullet is blocked" to "a shell open in that
  worktree" in one action.
- The frontend gets a slide-up drawer with session tabs, an `xterm.js`
  instance per session, matching the reference implementation's UX.
- No new authentication: the dashboard already binds to `127.0.0.1` only
  (`server.go:204`), and a terminal opened through it runs as the same
  local operator already running `sergeant ui`.

## Out of scope

- Multi-user or remote access, or any new auth/authz model.
- Recording, replaying, or attributing anything typed into a terminal to
  an intent, bullet, or phase — this is unrecorded, manual operator action,
  and Sergeant's truthfulness rule means the dashboard must not imply
  otherwise.
- A file editor, browser, or other IDE-like surface — terminal only.
- Persisting terminal scrollback as durable state.
- Windows PTY support.
