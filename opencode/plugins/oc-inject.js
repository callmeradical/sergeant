/**
 * oc-inject — out-of-band message injection into OpenCode sessions
 *
 * Allows external processes (agents, scripts, sgt-notify) to inject messages
 * into any OpenCode session without taking over the prompt bar. Messages are
 * queued when the session is busy and drained automatically on session.idle.
 *
 * Protocol:
 *   Write a .msg file to the target process's ordered inbox.
 *   Format: JSON  { "text": "...", "sessionId": "<id>", "messageId": "<id>" }
 *
 *   Each process owns its registry, inbox, and acknowledgements under
 *   ~/.local/share/opencode/inbox/processes/<pid>/.
 *
 * Companion CLI: bin/oc-inject in sergeant repo
 */
import { mkdirSync, writeFileSync, readdirSync, readFileSync, unlinkSync, existsSync, renameSync, rmSync } from "node:fs"
import { execFileSync } from "node:child_process"
import { join } from "node:path"

const HOME       = process.env.HOME
const ROOT       = process.env.OC_INJECT_ROOT || join(HOME, ".local/share/opencode/inbox")
const PROCESS_DIR = join(ROOT, "processes", String(process.pid))
const INBOX      = join(PROCESS_DIR, "inbox")
const ACKS       = join(PROCESS_DIR, "acks")
const REGISTRY   = join(PROCESS_DIR, "registry.json")
const POLL_MS    = Number(process.env.OC_INJECT_POLL_MS) || 2000
const PROCESS_START = execFileSync("ps", ["-o", "lstart=", "-p", String(process.pid)], { encoding: "utf8" }).trim()

mkdirSync(INBOX, { recursive: true })
mkdirSync(ACKS, { recursive: true })
process.once("exit", () => rmSync(PROCESS_DIR, { recursive: true, force: true }))

export const OcInjectPlugin = async ({ client }) => {
  const sessions = new Map()   // id → { busy: bool, queue: { text }[] }
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
      const pending = `${REGISTRY}.pending`
      writeFileSync(pending, JSON.stringify({
        primarySession: primary,
        pid: process.pid,
        processStart: PROCESS_START,
        updated: new Date().toISOString(),
        sessions: Object.fromEntries(
          [...sessions.entries()].map(([id, s]) => [id, { busy: s.busy, queued: s.queue.length }])
        ),
      }, null, 2))
      renameSync(pending, REGISTRY)
    } catch { /* non-fatal */ }
  }

  const ensure = (id) => {
    if (!sessions.has(id)) sessions.set(id, { busy: false, queue: [] })
    return sessions.get(id)
  }

  // ── Inject ─────────────────────────────────────────────────────────────
  const acknowledge = (messageId, accepted) => {
    if (!messageId) return
    const ack = join(ACKS, `${messageId}.json`)
    const pending = `${ack}.pending`
    writeFileSync(pending, JSON.stringify({ accepted }))
    renameSync(pending, ack)
  }

  const inject = async (sessionId, text) => {
    await log("info", `injecting → session=${sessionId.slice(0,8)} text="${text.slice(0,60)}"`)
    try {
      await client.session.promptAsync({
        path: { id: sessionId },
        body: { parts: [{ type: "text", text }] },
      })
      await log("info", "inject OK")
      return true
    } catch (e) {
      await log("error", `inject failed: ${e.message}`)
      return false
    }
  }

  // ── Queue drain ────────────────────────────────────────────────────────
  const drain = async (id) => {
    const s = sessions.get(id)
    if (!s || s.busy || !s.queue.length) return
    const msg = s.queue.shift()
    s.busy = true
    writeRegistry()
    await inject(id, msg.text)
  }

  // ── Process-owned inbox poller ─────────────────────────────────────────
  setInterval(async () => {
    if (!existsSync(INBOX)) return
    try {
      const files = readdirSync(INBOX).filter(f => f.endsWith(".msg")).sort()
      for (const fname of files) {
        const fpath = join(INBOX, fname)
        const processing = `${fpath}.processing`
        let messageId
        try {
          renameSync(fpath, processing)
          const raw = readFileSync(processing, "utf-8").trim()

          let text, targetId
          try {
            const p = JSON.parse(raw)
            text = p.text
            targetId = p.sessionId || primary
            messageId = p.messageId
          } catch  { text = raw; targetId = primary }

          if (!text) {
            acknowledge(messageId, false)
            unlinkSync(processing)
            continue
          }

          // No session yet — hold the file and retry next cycle
          if (!targetId) {
            renameSync(processing, fpath)
            continue
          }

          const s = sessions.get(targetId)
          if (!s) {
            acknowledge(messageId, false)
            unlinkSync(processing)
            continue
          }
          if (s.busy) {
            s.queue.push({ text })
            writeRegistry()
            acknowledge(messageId, true)
            unlinkSync(processing)
            await log("info", `session busy — queued (${s.queue.length} pending)`)
          } else {
            s.busy = true
            writeRegistry()
            acknowledge(messageId, await inject(targetId, text))
            unlinkSync(processing)
          }
        } catch {
          acknowledge(messageId, false)
          try { unlinkSync(processing) } catch { /* already cleaned up */ }
        }
      }
    } catch { /* empty inbox */ }
  }, POLL_MS)

  // ── Event hooks ────────────────────────────────────────────────────────
  return {
    "shell.env": async (input, output) => {
      const id = input?.sessionID
      if (!id) return
      primary = id
      ensure(id)
      output.env.OPENCODE_SESSION_ID = id
      writeRegistry()
    },
    event: async ({ event }) => {
      const type  = event?.type
      const props = event?.properties ?? {}

      if (type === "session.updated") {
        const id = props.sessionID
        if (!id) return
        primary = id
        ensure(id)
        writeRegistry()
      }

      if (type === "session.status") {
        const id = props.sessionID
        const status = props.status?.type
        if (!id || !status) return
        primary = id
        const s = ensure(id)
        if (status === "busy" || status === "retry") s.busy = true
        writeRegistry()
      }

      if (type === "session.idle") {
        const id = props.sessionID
        if (!id) return
        primary = id
        const s = ensure(id)
        s.busy = false
        await drain(id)
        writeRegistry()
      }

      if (type === "session.deleted") {
        const id = props.sessionID
        if (!id) return
        sessions.delete(id)
        if (primary === id) primary = null
        writeRegistry()
      }
    },
  }
}
