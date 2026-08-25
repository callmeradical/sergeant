# Product Requirements: Embedded Terminal

Status: Draft, awaiting explicit human PRD approval

Extends: `docs/prd-sergeant-v2.md` D8 ("The dashboard is a view of intents,
and it renders the workflow from a definition") — this PRD adds a
complementary, direct-control surface alongside that view; it does not
change what D8 governs (how intent/bullet/run state is displayed).

## Summary

Sergeant's dashboard today only shows state — an operator who needs to act
directly (inspect a blocked bullet's worktree, run a command by hand,
resolve a merge conflict) has to leave the browser and open their own
terminal. `skills/dispatch/SKILL.md`'s own Step 4 ("Resolve a blocked
bullet") instructs exactly this: "resolve the underlying cause directly —
in the bullet's worktree." This PRD adds a terminal embedded in the
dashboard itself, modeled on a working reference implementation
(`launchpad`'s Electron-based terminal drawer: `node-pty` bridged to
`xterm.js` over IPC, with a slide-up drawer and multiple named session
tabs), adapted to Sergeant's browser-based architecture — a PTY bridged
over WebSocket instead of Electron IPC. The goal stated by the requester:
make the dashboard the primary control surface, not just an observation
one.

## Problem

An operator resolving a blocked bullet, inspecting a worktree, or running
an ad hoc command today must find the worktree path (`GET
/api/run-details?id=`), then leave the browser for their own terminal. The
dashboard cannot answer "let me just look" without that context switch,
and nothing in the dashboard can act on the operator's behalf beyond the
specific write actions its existing endpoints expose
(`create-pr`, `run-resume`, and so on). A general-purpose terminal closes
that gap for anything those specific endpoints don't cover.

## Proposal

Add a terminal to the dashboard:

- **A shell session, opened from the browser, running on the same machine
  as the `sergeant ui` process.** Consistent with Sergeant's existing
  posture (single-operator, local-first, binds to `127.0.0.1` only) — this
  is not a remote-access or multi-tenant feature.
- **Multiple concurrent named sessions**, presented as tabs, matching the
  reference implementation's UX (a session per shell, closeable
  independently).
- **A session may optionally start already positioned in a specific
  bullet's worktree** — the dashboard already knows every bullet's worktree
  path; letting an operator jump from "this bullet is blocked" directly to
  "a shell open in that worktree" is the concrete case this PRD exists to
  serve, not a generic terminal for its own sake.
- **Full interactivity**: real PTY (not a command-output log), so
  interactive programs (an editor, `git rebase -i`-style flows, a REPL)
  work exactly as they would in any terminal emulator.

## Out of scope

- **Multi-user or remote access.** A terminal opened through the dashboard
  runs as the same local operator who is already running `sergeant ui`; no
  new authentication or authorization model is introduced. If Sergeant
  itself is ever exposed beyond `127.0.0.1`, that is a separate decision
  this PRD does not make.
- **Replacing or wrapping the existing dispatch/gate/review pipeline.**
  Nothing a human types into this terminal becomes a recorded phase,
  bullet, or intent — this is manual, out-of-band operator action, visible
  to Sergeant's truthfulness rule as exactly that (unrecorded), not
  something the dashboard should attribute to a bullet's evidence trail.
- **A file editor, browser, or any other IDE-like surface.** Terminal only.
- **Persisting terminal history or output as durable Sergeant state.** A
  closed session's scrollback is gone, the same as closing a normal
  terminal window.
- **Windows PTY support**, unless a maintainer specifically needs it —
  Sergeant's current development and deployment surface is macOS/Linux.

## Open questions

- Exact Go PTY and WebSocket library choices, and the exact route/message
  shape for the bridge — implementation decisions for OpenSpec's
  `design.md`, not product requirements.
- Whether opening a terminal should be gated behind any confirmation (given
  it grants full shell access, more than any existing dashboard action) or
  is unrestricted like every other local-only Sergeant capability today.
