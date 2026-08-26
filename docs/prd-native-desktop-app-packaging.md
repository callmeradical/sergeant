# Product Requirements: Native Desktop App Packaging (Tauri)

Status: Draft, awaiting explicit human PRD approval

Extends: `docs/prd-sergeant-v2.md`'s operating model (§2: single-user,
local-first, each developer runs an independent installation) and the
existing decision that the dashboard server binds to `127.0.0.1` only
(`internal/ui/server.go:217`). This PRD does not change that trust
model — it changes how the same local-only server is launched and
presented, not what it's allowed to talk to.

## Summary

Sergeant v2 today is a single Go binary (`sergeant`, built by the existing
`.goreleaser.yaml` for darwin/linux, amd64/arm64) that a user runs from a
terminal (`sergeant ui`), which starts an HTTP server bound to
`127.0.0.1:8484` and serves an embedded dashboard the user then opens
manually in a browser tab. This PRD packages that same binary and
dashboard as a native desktop app, using Tauri: one installable app per
OS, launched like any other application, with no terminal step and no
manual "open this URL" step.

## Problem

"Ease of use" and "a complete package" are not properties of a binary you
have to know to run from a terminal and then separately remember a port
number to open in a browser. Today's install/first-run story is three
manual, terminal-literate steps (download or build the binary, run
`sergeant ui`, open `127.0.0.1:8484`) with no dock/app-icon presence and
no clean way to stop it short of finding and killing the process. That is
a real adoption barrier for anyone not already comfortable at a terminal,
and it does not match how every other desktop tool a non-technical
operator already uses behaves.

## Proposal

- **Tauri wraps the existing binary and dashboard unchanged, via its
  sidecar mechanism** (`tauri.conf.json`'s `bundle.externalBin`) — the
  compiled `sergeant` Go binary ships *inside* the Tauri app bundle as an
  external binary resource, not reimplemented in Rust or Node. The
  dashboard's HTML/JS (`internal/ui/static/index.html`) renders unchanged
  inside Tauri's native OS WebView.
- **The existing `.goreleaser.yaml` build matrix (darwin/linux ×
  amd64/arm64) is what produces the per-platform binaries Tauri's sidecar
  needs**, renamed to Tauri's expected target-triple convention (e.g.
  `sergeant-aarch64-apple-darwin`) as a packaging step — no new Go build
  configuration, no change to what `CGO_ENABLED=0` cross-compilation
  already produces.
- **Launching the app spawns the sidecar and opens a native window
  pointed at the same `127.0.0.1:<port>` address the server already binds
  to** — no change to the server's local-only trust model, no new network
  exposure. The window is Tauri's WebView loading that local address, not
  a browser tab.
- **Quitting the app (or closing its window, if that's defined as quit —
  see Open Questions) terminates the sidecar process explicitly.** No
  orphaned background server survives after the app appears closed.
- **Installation is the normal OS flow for the platform** — a `.dmg`/
  `.app` on macOS at minimum, matching goreleaser's current darwin target.
  Downloading and opening one file *is* the entire getting-started story;
  no separate binary, no terminal.
- **This is an additional distribution form, not a replacement.** The
  existing raw-binary distribution via goreleaser/GitHub releases keeps
  working unchanged for anyone who wants the terminal-first flow.

## Out of scope

- Any redesign of the dashboard UI itself — it renders exactly as it does
  in a browser today, inside a different window chrome.
- An auto-update mechanism. Tauri has one; adopting it is a separate,
  later decision.
- Windows support. Not in goreleaser's current build matrix; adding a
  Windows build target (and the sidecar/signing implications that come
  with it) is a separate decision this PRD does not make.
- System tray integration, native menu bar items, or multi-window
  support beyond the minimum needed to launch, show, and cleanly quit —
  possible future polish, not required for a first shippable version.
- Changing the server's port, binding address, or any part of its
  single-user/local-only trust model.
- Retiring the existing standalone-binary release artifacts.

## Open questions

- **Code-signing and notarization.** Shipping a macOS `.app` that isn't
  Gatekeeper-blocked requires an Apple Developer ID and a notarization
  step in the release pipeline. This is a real operational/credential
  decision (whose Developer ID, where the signing secret lives in CI),
  not something this PRD settles.
- **Whether the fixed port 8484 needs to become configurable.**
  `startUI()` hardcodes `ui.NewServer(st, 8484)` today. A single-user
  terminal flow tolerates a rare port conflict by just erroring visibly;
  a packaged app that's supposed to "just work" on launch may need to
  detect a conflict and pick another port, or fail with a clear message —
  worth deciding in `design.md`, not fixed here.
- **What closing the main window means.** Whether closing the window quits
  the app (and kills the sidecar) or leaves it running in the background
  (tray icon, menu bar) changes exactly when the "terminate the sidecar on
  quit" requirement fires. Not settled here.
- **Whether the Tauri build runs in the existing `release.yml`/goreleaser
  pipeline or a separate workflow triggered after it** — a CI-design
  decision for `design.md`.
