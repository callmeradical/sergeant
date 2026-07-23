# oc-inject — Out-of-Band Message Injection

Allows external processes (dispatched agents, scripts, `sgt-notify`) to inject
messages into any active OpenCode session without taking over the prompt bar.
Messages are queued when the session is busy and drained automatically when it
goes idle.

---

## How it works

```
sgt-notify / agent script
  └─ bin/oc-inject "message"
       └─ writes ~/.local/share/opencode/inbox/processes/<pid>/inbox/<message-id>.msg
            └─ opencode/plugins/oc-inject.js (2s poller)
                 ├─ session idle   → inject immediately via session.promptAsync
                 └─ session busy   → queue in-memory, drain on session.idle event
```

The plugin is loaded globally by each OpenCode process at startup. Every process
owns a registry and ordered inbox under its PID, so a worker plugin cannot claim
or consume a coordinator's messages. Dispatch records the coordinator PID and
session in the task's `oc_target.json`; `sgt-notify` uses that explicit target.
A 2-second interval polls only the owning process's inbox. Registries include
the operating-system process start identity so a stale directory cannot become
valid after PID reuse. The CLI waits for the owning plugin to acknowledge each
message before reporting success; otherwise `sgt-notify` falls back to tmux.
If a plugin claims a message but its API call does not acknowledge within the
bounded wait, the CLI returns status 2 and `sgt-notify` reports uncertainty
without using tmux, avoiding duplicate delivery.
The plugin's `shell.env` hook exports the invoking session ID to that shell
invocation, so dispatch captures its own coordinator conversation rather than
guessing from whichever session emitted the latest background event.

---

## Files

| File | Purpose |
|---|---|
| `opencode/plugins/oc-inject.js` | OpenCode plugin — source of truth, tracked in this repo |
| `~/.config/opencode/plugins/oc-inject.js` | Live copy loaded by OpenCode (symlinked or copied on install) |
| `bin/oc-inject` | CLI — drop a message into the inbox |
| `bin/sgt-notify` | Updated to prefer `oc-inject` over `tmux send-keys` |
| `~/.local/share/opencode/inbox/processes/<pid>/inbox/` | Process-owned ordered message queue |
| `~/.local/share/opencode/inbox/processes/<pid>/registry.json` | Process/session state written by its plugin |
| `~/.local/share/sergeant/fleet/<task>/oc_target.json` | Coordinator PID/session captured by dispatch |

---

## Message format

Messages are JSON and target a session in the queue's owning process:
```json
{ "text": "my message", "sessionId": "ses_abc123...", "messageId": "..." }
```

---

## CLI

```bash
oc-inject --pid 12345 "message"                  # inject into its primary session
oc-inject --pid 12345 "message" ses_abc123       # inject into a specific session
oc-inject --pid 12345 --status                    # show process registry state
```

---

## Install

`mise run install` symlinks `bin/oc-inject` to `~/.local/bin/oc-inject` and
symlinks the tracked plugin to
`~/.config/opencode/plugins/oc-inject.js`.

Verify both links:

```bash
command -v oc-inject
readlink ~/.config/opencode/plugins/oc-inject.js
```

If `mise` is unavailable, create the links manually:
```bash
mkdir -p ~/.local/bin ~/.config/opencode/plugins
ln -sf "$(pwd)/bin/oc-inject" ~/.local/bin/oc-inject
ln -sf "$(pwd)/opencode/plugins/oc-inject.js" ~/.config/opencode/plugins/oc-inject.js
```

OpenCode must be restarted to pick up the plugin.

---

## Findings from prototype (2026-07-17)

**What was validated:**
- Plugin loads cleanly via `~/.config/opencode/plugins/` auto-discovery
- `session.idle` and `session.updated` events fire correctly via the generic
  `event` handler with payloads at `event.properties` (not directly on `event`)
- `client.session.promptAsync({ path: { id }, body: { parts } })` injects a
  message as a new conversation turn without touching the prompt bar
- Queue drains correctly on `session.idle` — messages sent while agent is busy
  appear in order when it goes idle
- The 2s poller correctly holds files when `primary` is null (no session yet)
  rather than dropping them

**Key gotchas discovered:**
- Session event data is at `event.properties.sessionID`, not `event.sessionID`
- Direct hook keys like `"session.idle": async (input) => {}` do NOT work for
  session events — must use the generic `event` handler with type dispatch
- `client.session.promptAsync` SDK signature: `{ path: { id }, body: { parts } }`
  not `({ id }, { parts })`
- Top-level module code runs on load but the exported plugin function may not
  be called if it throws during init — test with a top-level side-effect write
- OpenCode plugins load at process startup — "new session" inside an existing
  OpenCode instance does NOT reload plugins; need a full process restart

---

## Registry schema

```json
{
  "primarySession": "ses_abc123...",
  "pid": 12345,
  "processStart": "Tue Jul 21 10:00:00 2026",
  "updated": "2026-07-18T02:59:20Z",
  "sessions": {
    "ses_abc123...": { "busy": false, "queued": 0 }
  }
}
```
