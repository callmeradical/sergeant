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
       └─ writes ~/.local/share/opencode/inbox/<timestamp>.msg
            └─ opencode/plugins/oc-inject.js (2s poller)
                 ├─ session idle   → inject immediately via session.promptAsync
                 └─ session busy   → queue in-memory, drain on session.idle event
```

The plugin is loaded globally by OpenCode at startup. It registers a session
event handler that tracks which session is primary and whether it is busy. A
2-second interval polls the inbox directory for new `.msg` files.

---

## Files

| File | Purpose |
|---|---|
| `opencode/plugins/oc-inject.js` | OpenCode plugin — source of truth, tracked in this repo |
| `~/.config/opencode/plugins/oc-inject.js` | Live copy loaded by OpenCode (symlinked or copied on install) |
| `bin/oc-inject` | CLI — drop a message into the inbox |
| `bin/sgt-notify` | Updated to prefer `oc-inject` over `tmux send-keys` |
| `~/.local/share/opencode/inbox/` | Message drop directory (watched by plugin) |
| `~/.local/share/opencode/inbox/.registry.json` | Session state written by plugin; read by CLI |

---

## Message format

Plain text (injected into primary session):
```
echo "my message" > ~/.local/share/opencode/inbox/$(date +%s).msg
```

JSON (target a specific session):
```json
{ "text": "my message", "sessionId": "ses_abc123..." }
```

---

## CLI

```bash
oc-inject "message"                  # inject into primary session
oc-inject "message" <session-id>     # inject into specific session
oc-inject --status                   # show registry (sessions, busy state, queue depth)
```

---

## Install

`mise run install` symlinks `bin/oc-inject` to `~/.local/bin/oc-inject`.

The plugin must be present at `~/.config/opencode/plugins/oc-inject.js`.
Copy it on first install:

```bash
cp opencode/plugins/oc-inject.js ~/.config/opencode/plugins/
```

Or add a symlink:
```bash
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
  "updated": "2026-07-18T02:59:20Z",
  "sessions": {
    "ses_abc123...": { "busy": false, "queued": 0 }
  }
}
```
