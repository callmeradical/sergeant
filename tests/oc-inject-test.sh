#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
coordinator_pid=""
worker_pid=""

cleanup() {
  [[ -z "$coordinator_pid" ]] || kill "$coordinator_pid" 2>/dev/null || true
  [[ -z "$worker_pid" ]] || kill "$worker_pid" 2>/dev/null || true
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

home="$TEST_ROOT/home"
fleet="$TEST_ROOT/fleet"
mkdir -p "$home" "$fleet/task-1"

cat > "$TEST_ROOT/plugin-harness.mjs" <<'EOF'
import { appendFileSync, readFileSync } from "node:fs"
import { pathToFileURL } from "node:url"

const [pluginPath, sessionId, logPath, commandPath] = process.argv.slice(2)
const { OcInjectPlugin } = await import(pathToFileURL(pluginPath))
let failPrompt = false
let hangPrompt = false
const hooks = await OcInjectPlugin({
  client: {
    app: { log: async () => {} },
    session: {
      promptAsync: async ({ path, body }) => {
        if (failPrompt) throw new Error("injection failed")
        if (hangPrompt) await new Promise(() => {})
        appendFileSync(logPath, `${JSON.stringify({ sessionId: path.id, text: body.parts[0].text })}\n`)
      },
    },
  },
})

await hooks.event({ event: { type: "session.updated", properties: { sessionID: sessionId } } })

let consumed = 0
setInterval(async () => {
  let commands = ""
  try { commands = readFileSync(commandPath, "utf8") } catch {}
  const pending = commands.split("\n").filter(Boolean).slice(consumed)
  consumed += pending.length
  for (const command of pending) {
    if (command === "idle") {
      await hooks.event({ event: { type: "session.idle", properties: { sessionID: sessionId } } })
    }
    if (command === "busy") {
      await hooks.event({ event: { type: "session.status", properties: { sessionID: sessionId, status: { type: "busy" } } } })
    }
    if (command.startsWith("updated:")) {
      await hooks.event({ event: { type: "session.updated", properties: { sessionID: command.slice(8) } } })
    }
    if (command.startsWith("deleted:")) {
      await hooks.event({ event: { type: "session.deleted", properties: { sessionID: command.slice(8) } } })
    }
    if (command.startsWith("shell:")) {
      const output = { env: {} }
      await hooks["shell.env"]({ sessionID: command.slice(6) }, output)
      appendFileSync(`${commandPath}.env`, `${output.env.OPENCODE_SESSION_ID ?? ""}\n`)
    }
    if (command === "fail") failPrompt = true
    if (command === "recover") failPrompt = false
    if (command === "hang") {
      failPrompt = false
      hangPrompt = true
    }
  }
}, 10)
EOF

wait_for() {
  local description="$1"
  shift
  for _ in {1..100}; do
    if "$@"; then
      return 0
    fi
    sleep 0.05
  done
  printf 'timed out waiting for %s\n' "$description" >&2
  return 1
}

has_lines() {
  local expected="$1"
  local file="$2"
  [[ -f "$file" && "$(wc -l < "$file" | tr -d ' ')" -ge "$expected" ]]
}

registry_has_queue() {
  local registry="$1"
  local session="$2"
  local expected="$3"
  [[ -f "$registry" ]] && [[ "$(jq -r --arg s "$session" '.sessions[$s].queued' "$registry")" == "$expected" ]]
}

registry_is_busy() {
  local registry="$1"
  local session="$2"
  [[ -f "$registry" ]] && [[ "$(jq -r --arg s "$session" '.sessions[$s].busy' "$registry")" == "true" ]]
}

registry_is_idle() {
  local registry="$1"
  local session="$2"
  [[ -f "$registry" ]] && [[ "$(jq -r --arg s "$session" '.sessions[$s].busy' "$registry")" == "false" ]]
}

registry_has_primary() {
  local registry="$1"
  local expected="$2"
  [[ -f "$registry" ]] && [[ "$(jq -r '.primarySession' "$registry")" == "$expected" ]]
}

shell_env_has() {
  local file="$1"
  local expected="$2"
  [[ -f "$file" ]] && grep -Fqx "$expected" "$file"
}

: > "$TEST_ROOT/coordinator.commands"
: > "$TEST_ROOT/worker.commands"
HOME="$home" OC_INJECT_POLL_MS=20 node "$TEST_ROOT/plugin-harness.mjs" \
  "$ROOT_DIR/opencode/plugins/oc-inject.js" ses_coordinator "$TEST_ROOT/coordinator.log" \
  "$TEST_ROOT/coordinator.commands" &
coordinator_pid=$!
HOME="$home" OC_INJECT_POLL_MS=20 node "$TEST_ROOT/plugin-harness.mjs" \
  "$ROOT_DIR/opencode/plugins/oc-inject.js" ses_worker "$TEST_ROOT/worker.log" \
  "$TEST_ROOT/worker.commands" &
worker_pid=$!

coordinator_registry="$home/.local/share/opencode/inbox/processes/$coordinator_pid/registry.json"
worker_registry="$home/.local/share/opencode/inbox/processes/$worker_pid/registry.json"
wait_for "coordinator registry" test -f "$coordinator_registry"
wait_for "worker registry" test -f "$worker_registry"

printf 'updated:ses_other\n' >> "$TEST_ROOT/coordinator.commands"
wait_for "latest coordinator session" registry_has_primary "$coordinator_registry" ses_other
printf 'deleted:ses_other\nshell:ses_coordinator\n' >> "$TEST_ROOT/coordinator.commands"
wait_for "invoking coordinator session" registry_has_primary "$coordinator_registry" ses_coordinator
wait_for "invocation-scoped session environment" shell_env_has \
  "$TEST_ROOT/coordinator.commands.env" ses_coordinator

jq -nc --argjson pid "$coordinator_pid" --arg sessionId ses_coordinator \
  '{pid: $pid, sessionId: $sessionId}' > "$fleet/task-1/oc_target.json"
printf 'session:1.0\n' > "$fleet/task-1/primary_pane"

printf 'busy\n' >> "$TEST_ROOT/coordinator.commands"
wait_for "busy coordinator state" registry_is_busy "$coordinator_registry" ses_coordinator
HOME="$home" SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-notify" task-1 "worker complete" >/dev/null
[[ ! -s "$TEST_ROOT/worker.log" ]] || {
  printf 'worker plugin consumed the coordinator notification\n' >&2
  exit 1
}

HOME="$home" "$ROOT_DIR/bin/oc-inject" --pid "$coordinator_pid" "second" ses_coordinator >/dev/null
HOME="$home" "$ROOT_DIR/bin/oc-inject" --pid "$coordinator_pid" "third" ses_coordinator >/dev/null
wait_for "busy coordinator queue" registry_has_queue "$coordinator_registry" ses_coordinator 3

printf 'idle\n' >> "$TEST_ROOT/coordinator.commands"
wait_for "first ordered notification" has_lines 1 "$TEST_ROOT/coordinator.log"
printf 'idle\n' >> "$TEST_ROOT/coordinator.commands"
wait_for "second ordered notification" has_lines 2 "$TEST_ROOT/coordinator.log"
printf 'idle\n' >> "$TEST_ROOT/coordinator.commands"
wait_for "third ordered notification" has_lines 3 "$TEST_ROOT/coordinator.log"

jq -s -e '
  map(.text) == [
    "Agent task task-1 update: worker complete",
    "second",
    "third"
  ] and all(.[]; .sessionId == "ses_coordinator")
' "$TEST_ROOT/coordinator.log" >/dev/null

if HOME="$home" "$ROOT_DIR/bin/oc-inject" --pid "$coordinator_pid" \
  "missing session" ses_missing >/dev/null 2>&1; then
  printf 'unregistered coordinator session accepted delivery\n' >&2
  exit 1
fi

printf 'idle\nfail\n' >> "$TEST_ROOT/coordinator.commands"
wait_for "idle coordinator state" registry_is_idle "$coordinator_registry" ses_coordinator
if HOME="$home" "$ROOT_DIR/bin/oc-inject" --pid "$coordinator_pid" \
  "failed injection" ses_coordinator >/dev/null 2>&1; then
  printf 'failed coordinator injection reported success\n' >&2
  exit 1
fi

printf 'idle\nrecover\nhang\n' >> "$TEST_ROOT/coordinator.commands"
wait_for "idle coordinator before hanging injection" registry_is_idle "$coordinator_registry" ses_coordinator
set +e
HOME="$home" OC_INJECT_ACK_ATTEMPTS=10 "$ROOT_DIR/bin/oc-inject" --pid "$coordinator_pid" \
  "hanging injection" ses_coordinator >/dev/null 2>&1
hang_status=$?
set -e
[[ "$hang_status" -eq 2 ]] || {
  printf 'claimed hanging injection did not return uncertain status\n' >&2
  exit 1
}

kill "$coordinator_pid"
wait "$coordinator_pid" 2>/dev/null || true
coordinator_pid=""
dead_pid="$(jq -r .pid "$fleet/task-1/oc_target.json")"
if HOME="$home" "$ROOT_DIR/bin/oc-inject" --pid "$dead_pid" \
  "after death" ses_coordinator >/dev/null 2>&1; then
  printf 'dead coordinator registration reported successful delivery\n' >&2
  exit 1
fi

mkdir -p "$TEST_ROOT/fake-bin"
cat > "$TEST_ROOT/fake-bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  has-session) exit 0 ;;
  send-keys) printf '%s\n' "$*" >> "$TMUX_LOG" ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/tmux"
HOME="$home" PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-notify" task-1 "fallback" >/dev/null 2>&1
grep -Fq 'Agent task task-1 update: fallback' "$TEST_ROOT/tmux.log"

printf 'oc-inject coordinator routing: ok\n'
