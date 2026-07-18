/**
 * oc-inject — out-of-band message injection into OpenCode sessions
 *
 * Allows external processes (agents, scripts, sgt-notify) to inject messages
 * into any OpenCode session without taking over the prompt bar. Messages are
 * queued when the session is busy and drained automatically on session.idle.
 *
 * Protocol:
 *   Write a .msg file to ~/.local/share/opencode/inbox/
 *   Format: JSON  { "text": "...", "sessionId": "<id>|null" }
 *           or plain text (injected into primary session)
 *
 *   Read ~/.local/share/opencode/inbox/.registry.json for session IDs and state.
 *
 * Companion CLI: bin/oc-inject in sergeant repo
 */
import { mkdirSync, writeFileSync, readdirSync, readFileSync, unlinkSync, existsSync } from "node:fs"
import { join } from "node:path"

const HOME     = process.env.HOME
const INBOX    = join(HOME, ".local/share/opencode/inbox")
const REGISTRY = join(INBOX, ".registry.json")

mkdirSync(INBOX, { recursive: true })

export const OcInjectPlugin = async ({ client }) => {
  const sessions = new Map()   // id → { busy: bool, queue: string[] }
  let primary    = null

  // ── Structured logging via client ──────────────────────────────────────
  const log = async (level, message) => {
    try {
      await client.app.log({ body: { service: "oc-inject", level, message } })
    } catch { /* never crash on log failure */ }
  }

  // ── Registry ───────────────────────────────────────────────────────────
  const writeRegistry = () => {
    try {
      writeFileSync(REGISTRY, JSON.stringify({
        primarySession: primary,
        pid: process.pid,
        updated: new Date().toISOString(),
        sessions: Object.fromEntries(
          [...sessions.entries()].map(([id, s]) => [id, { busy: s.busy, queued: s.queue.length }])
        ),
      }, null, 2))
    } catch { /* non-fatal */ }
  }

  const ensure = (id) => {
    if (!sessions.has(id)) sessions.set(id, { busy: false, queue: [] })
    return sessions.get(id)
  }

  // ── Inject ─────────────────────────────────────────────────────────────
  const inject = async (sessionId, text) => {
    await log("info", `injecting → session=${sessionId.slice(0,8)} text="${text.slice(0,60)}"`)
    try {
      await client.session.promptAsync({
        path: { id: sessionId },
        body: { parts: [{ type: "text", text }] },
      })
      await log("info", "inject OK")
    } catch (e) {
      await log("error", `inject failed: ${e.message}`)
    }
  }

  // ── Queue drain ────────────────────────────────────────────────────────
  const drain = async (id) => {
    const s = sessions.get(id)
    if (!s || s.busy || !s.queue.length) return
    const msg = s.queue.shift()
    s.busy = true
    writeRegistry()
    await inject(id, msg)
  }

  // ── Inbox poller (every 2s) ────────────────────────────────────────────
  setInterval(async () => {
    if (!existsSync(INBOX)) return
    try {
      const files = readdirSync(INBOX).filter(f => f.endsWith(".msg"))
      for (const fname of files) {
        const fpath = join(INBOX, fname)
        try {
          const raw = readFileSync(fpath, "utf-8").trim()

          let text, targetId
          try { const p = JSON.parse(raw); text = p.text; targetId = p.sessionId || primary }
          catch  { text = raw; targetId = primary }

          if (!text) { unlinkSync(fpath); continue }

          // No session yet — hold the file and retry next cycle
          if (!targetId) continue

          unlinkSync(fpath)

          const s = ensure(targetId)
          if (s.busy) {
            s.queue.push(text)
            await log("info", `session busy — queued (${s.queue.length} pending)`)
            writeRegistry()
          } else {
            s.busy = true
            writeRegistry()
            await inject(targetId, text)
          }
        } catch { /* skip unreadable file */ }
      }
    } catch { /* empty inbox */ }
  }, 2000)

  // ── Event hooks ────────────────────────────────────────────────────────
  return {
    event: async ({ event }) => {
      const type  = event?.type
      const props = event?.properties ?? {}

      if (type === "session.updated") {
        const id = props.sessionID
        if (!id) return
        if (!primary) primary = id
        ensure(id)
        writeRegistry()
      }

      if (type === "session.idle") {
        const id = props.sessionID
        if (!id) return
        if (!primary) primary = id
        const s = ensure(id)
        s.busy = false
        await drain(id)
        writeRegistry()
      }
    },
  }
}
