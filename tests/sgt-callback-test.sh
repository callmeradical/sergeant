#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

home="$TEST_ROOT/home"
fleet="$TEST_ROOT/fleet"
callbacks="$TEST_ROOT/callbacks"
mkdir -p "$home" "$fleet" "$callbacks"
chmod 700 "$fleet" "$callbacks"

callback_env=(
  HOME="$home"
  SERGEANT_FLEET="$fleet"
  SERGEANT_CALLBACKS="$callbacks"
  SGT_CALLBACK_RETRY_BASE_SECONDS=0
  SGT_CALLBACK_CLAIM_TIMEOUT_SECONDS=0
  SGT_CALLBACK_TIMEOUT_SECONDS=2
)

callback() {
  env "${callback_env[@]}" "$ROOT/bin/sgt-callback" "$@"
}

write_ack_callback() {
  local profile="$1"
  local log="$2"
  cat > "$callbacks/$profile" <<EOF
#!/usr/bin/env python3
import json
import sys

event = json.load(sys.stdin)
with open("$log", "a", encoding="utf-8") as handle:
    handle.write(event["idempotency_key"] + "\n")
json.dump({
    "version": "sergeant.callback-ack/v1",
    "idempotency_key": event["idempotency_key"],
    "status": "ack",
}, sys.stdout, separators=(",", ":"))
EOF
  chmod 700 "$callbacks/$profile"
}

event_count() {
  local task="$1"
  python3 - "$fleet/$task/.callbacks/events" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
print(sum(1 for path in root.glob("*/event.json")) if root.exists() else 0)
PY
}

assert_all_event_types() {
  local task="$1"
  python3 - "$fleet/$task/.callbacks/events" <<'PY'
import json
from pathlib import Path
import sys

types = {
    json.loads(path.read_text(encoding="utf-8"))["type"]
    for path in Path(sys.argv[1]).glob("*/event.json")
}
expected = {"needs_input", "blocked", "failed", "done"}
if types != expected:
    raise SystemExit(f"event classes mismatch: {types!r}")
PY
}

# Registration writes only the versioned, strict origin contract.
mkdir -p "$fleet/task-schema"
write_ack_callback hermes-discord "$TEST_ROOT/schema-deliveries"
CALLBACK_LOG="$TEST_ROOT/schema-deliveries" callback register \
  task-schema hermes-discord req-schema-001
python3 - "$fleet/task-schema/.callbacks/origin.json" <<'PY'
import json
from pathlib import Path
import stat
import sys

path = Path(sys.argv[1])
origin = json.loads(path.read_text(encoding="utf-8"))
assert origin == {
    "version": "sergeant.callback-origin/v1",
    "profile": "hermes-discord",
    "correlation_id": "req-schema-001",
}
assert stat.S_IMODE(path.stat().st_mode) == 0o600
PY

# Enqueue, delivery, acknowledgement, and duplicate suppression are durable.
CALLBACK_LOG="$TEST_ROOT/schema-deliveries" callback enqueue \
  task-schema needs_input coordinator-followup-1 <<< "Choose option A or B."
[[ "$(event_count task-schema)" == "1" ]]
if CALLBACK_LOG="$TEST_ROOT/schema-deliveries" callback check-acked \
  task-schema >/dev/null 2>&1; then
  printf 'pending callback was reported as acknowledged\n' >&2
  exit 1
fi
CALLBACK_LOG="$TEST_ROOT/schema-deliveries" callback drain task-schema
CALLBACK_LOG="$TEST_ROOT/schema-deliveries" callback check-acked task-schema
python3 - "$fleet/task-schema/.callbacks/events" <<'PY'
import json
from pathlib import Path
import sys

events = list(Path(sys.argv[1]).glob("*/event.json"))
assert len(events) == 1
event = json.loads(events[0].read_text(encoding="utf-8"))
assert event["version"] == "sergeant.callback-event/v1"
assert event["type"] == "needs_input"
assert event["correlation_id"] == "req-schema-001"
assert event["generation"] == 1
assert event["idempotency_key"] == "sgt-callback-v1:req-schema-001:1"
state = json.loads((events[0].parent / "state.json").read_text(encoding="utf-8"))
assert state["version"] == "sergeant.callback-state/v1"
assert state["status"] == "acknowledged"
assert state["attempts"] == 1
assert state["acknowledged_at"]
PY
CALLBACK_LOG="$TEST_ROOT/schema-deliveries" callback enqueue \
  task-schema needs_input coordinator-followup-1 <<< "Choose option A or B."
CALLBACK_LOG="$TEST_ROOT/schema-deliveries" callback drain task-schema
[[ "$(event_count task-schema)" == "1" ]]
[[ "$(wc -l < "$TEST_ROOT/schema-deliveries")" == "1" ]]

# A fleet with no origin remains a no-op and never resolves a callback profile.
mkdir -p "$fleet/task-no-origin/app" "$TEST_ROOT/no-origin-worktree"
printf '%s\n' "$TEST_ROOT/no-origin-worktree" > "$fleet/task-no-origin/app/worktree"
printf 'done\n' > "$TEST_ROOT/no-origin-worktree/.sergeant-status"
printf 'https://example.invalid/no-origin\n' > "$TEST_ROOT/no-origin-worktree/.sergeant-result"
CALLBACK_LOG="$TEST_ROOT/no-origin-deliveries" callback sync task-no-origin
[[ ! -e "$fleet/task-no-origin/.callbacks" ]]
[[ ! -e "$TEST_ROOT/no-origin-deliveries" ]]

# Authoritative worktree states produce each callback class without pane state.
mkdir -p "$fleet/task-auto/app" "$TEST_ROOT/auto-worktree"
printf '%s\n' "$TEST_ROOT/auto-worktree" > "$fleet/task-auto/app/worktree"
write_ack_callback hermes-discord "$TEST_ROOT/auto-deliveries"
CALLBACK_LOG="$TEST_ROOT/auto-deliveries" callback register \
  task-auto hermes-discord req-auto-001
printf '1\n' > "$TEST_ROOT/auto-worktree/.sergeant-gate-generation"
printf 'needs_input\n' > "$TEST_ROOT/auto-worktree/.sergeant-status"
printf 'Choose the safe deployment window.\n' > "$TEST_ROOT/auto-worktree/.sergeant-message"
CALLBACK_LOG="$TEST_ROOT/auto-deliveries" callback sync task-auto
printf '2\n' > "$TEST_ROOT/auto-worktree/.sergeant-gate-generation"
printf 'blocked\n' > "$TEST_ROOT/auto-worktree/.sergeant-status"
printf 'Approved dependency is unavailable.\n' > "$TEST_ROOT/auto-worktree/.sergeant-message"
CALLBACK_LOG="$TEST_ROOT/auto-deliveries" callback sync task-auto
printf 'failed: repository validation failed\n' > "$TEST_ROOT/auto-worktree/.sergeant-status"
CALLBACK_LOG="$TEST_ROOT/auto-deliveries" callback sync task-auto
printf 'done\n' > "$TEST_ROOT/auto-worktree/.sergeant-status"
printf 'https://github.com/example/sergeant/pull/1\n' > "$TEST_ROOT/auto-worktree/.sergeant-result"
CALLBACK_LOG="$TEST_ROOT/auto-deliveries" callback sync task-auto
[[ "$(event_count task-auto)" == "4" ]]
[[ "$(wc -l < "$TEST_ROOT/auto-deliveries")" == "4" ]]
assert_all_event_types task-auto

# sgt-notify queues from durable status even when no coordinator pane/API target exists.
mkdir -p "$fleet/task-notify/app" "$TEST_ROOT/notify-worktree"
printf '%s\n' "$TEST_ROOT/notify-worktree" > "$fleet/task-notify/app/worktree"
write_ack_callback hermes-discord "$TEST_ROOT/notify-deliveries"
callback register task-notify hermes-discord req-notify-001
printf '1\n' > "$TEST_ROOT/notify-worktree/.sergeant-gate-generation"
printf 'needs_input\n' > "$TEST_ROOT/notify-worktree/.sergeant-status"
printf 'Choose the approved notification route.\n' > "$TEST_ROOT/notify-worktree/.sergeant-message"
env "${callback_env[@]}" SGT_WIKI_DISABLED=1 "$ROOT/bin/sgt-notify" \
  task-notify "needs_input [app]: choose notification route" >/dev/null 2>&1
[[ "$(event_count task-notify)" == "1" ]]
[[ "$(wc -l < "$TEST_ROOT/notify-deliveries")" == "1" ]]

# A bounded watcher sync is also an automatic producer and delivery trigger.
mkdir -p "$fleet/task-watch/app" "$TEST_ROOT/watch-worktree"
printf '%s\n' "$TEST_ROOT/watch-worktree" > "$fleet/task-watch/app/worktree"
printf 'needs_input\n' > "$fleet/task-watch/app/status"
write_ack_callback hermes-discord "$TEST_ROOT/watch-deliveries"
callback register task-watch hermes-discord req-watch-001
printf '2\n' > "$TEST_ROOT/watch-worktree/.sergeant-gate-generation"
printf 'blocked\n' > "$TEST_ROOT/watch-worktree/.sergeant-status"
printf 'Approved callback service is unavailable.\n' > "$TEST_ROOT/watch-worktree/.sergeant-message"
env "${callback_env[@]}" "$ROOT/bin/sgt-watch" --sync task-watch
[[ "$(event_count task-watch)" == "1" ]]
[[ "$(wc -l < "$TEST_ROOT/watch-deliveries")" == "1" ]]

# A crashing callback remains pending and retries successfully after a new process starts.
cat > "$callbacks/crash-once" <<EOF
#!/usr/bin/env python3
import json
from pathlib import Path
import sys

event = json.load(sys.stdin)
marker = Path("$TEST_ROOT/crashed")
if not marker.exists():
    marker.touch()
    raise SystemExit(19)
with open("$TEST_ROOT/retry-deliveries", "a", encoding="utf-8") as handle:
    handle.write(event["idempotency_key"] + "\n")
json.dump({
    "version": "sergeant.callback-ack/v1",
    "idempotency_key": event["idempotency_key"],
    "status": "ack",
}, sys.stdout, separators=(",", ":"))
EOF
chmod 700 "$callbacks/crash-once"
mkdir -p "$fleet/task-retry"
CALLBACK_LOG="$TEST_ROOT/retry-deliveries" CRASH_MARKER="$TEST_ROOT/crashed" \
  callback register task-retry crash-once req-retry-001
CALLBACK_LOG="$TEST_ROOT/retry-deliveries" CRASH_MARKER="$TEST_ROOT/crashed" \
  callback enqueue task-retry blocked retry-source-1 <<< "Delivery dependency unavailable."
CALLBACK_LOG="$TEST_ROOT/retry-deliveries" CRASH_MARKER="$TEST_ROOT/crashed" \
  callback drain task-retry
python3 - "$fleet/task-retry/.callbacks/events" <<'PY'
import json
from pathlib import Path
import sys

state_path = next(Path(sys.argv[1]).glob("*/state.json"))
state = json.loads(state_path.read_text(encoding="utf-8"))
assert state["status"] == "pending"
assert state["attempts"] == 1
assert state["last_result"] == "callback_error"
PY
CALLBACK_LOG="$TEST_ROOT/retry-deliveries" CRASH_MARKER="$TEST_ROOT/crashed" \
  callback drain task-retry
CALLBACK_LOG="$TEST_ROOT/retry-deliveries" CRASH_MARKER="$TEST_ROOT/crashed" \
  callback drain task-retry
[[ "$(wc -l < "$TEST_ROOT/retry-deliveries")" == "1" ]]
grep -Fq '"status":"acknowledged"' "$fleet/task-retry/.callbacks/events"/*/state.json

# A permanent consumer rejection is retained until an explicit operator retry.
cat > "$callbacks/reject-once" <<'EOF'
#!/usr/bin/env python3
import json
import sys

event = json.load(sys.stdin)
json.dump({
    "version": "sergeant.callback-ack/v1",
    "idempotency_key": event["idempotency_key"],
    "status": "reject",
}, sys.stdout, separators=(",", ":"))
EOF
chmod 700 "$callbacks/reject-once"
mkdir -p "$fleet/task-rejected"
callback register task-rejected reject-once req-rejected-001
rejected_key="$(callback enqueue task-rejected failed rejected-source-1 <<< \
  "Callback policy rejected the event.")"
callback drain task-rejected
grep -Fq '"status":"rejected"' "$fleet/task-rejected/.callbacks/events"/*/state.json
if callback check-acked task-rejected >/dev/null 2>&1; then
  printf 'rejected callback was reported as acknowledged\n' >&2
  exit 1
fi
write_ack_callback reject-once "$TEST_ROOT/rejected-deliveries"
callback retry task-rejected "$rejected_key"
callback drain task-rejected
callback check-acked task-rejected
[[ "$(wc -l < "$TEST_ROOT/rejected-deliveries")" == "1" ]]

# Every supported direct class is represented exactly once.
mkdir -p "$fleet/task-classes"
write_ack_callback hermes-discord "$TEST_ROOT/class-deliveries"
CALLBACK_LOG="$TEST_ROOT/class-deliveries" callback register \
  task-classes hermes-discord req-classes-001
for event_type in needs_input blocked failed "done"; do
  CALLBACK_LOG="$TEST_ROOT/class-deliveries" callback enqueue \
    task-classes "$event_type" "direct-$event_type-1" <<< "Safe $event_type status."
done
[[ "$(event_count task-classes)" == "4" ]]
assert_all_event_types task-classes

# A cleanup seal closes the acknowledged-check/enqueue deletion race.
mkdir -p "$fleet/task-sealed"
write_ack_callback hermes-discord "$TEST_ROOT/sealed-deliveries"
callback register task-sealed hermes-discord req-sealed-001
callback enqueue task-sealed "done" sealed-done-1 <<< "Safe terminal result."
callback drain task-sealed
callback seal task-sealed
if callback enqueue task-sealed blocked sealed-late-1 <<< \
  "Late callback must be retained." >/dev/null 2>&1; then
  printf 'cleanup-sealed task accepted a new event\n' >&2
  exit 1
fi
callback unseal task-sealed
callback enqueue task-sealed blocked sealed-late-1 <<< "Late callback is retained."
[[ "$(event_count task-sealed)" == "2" ]]

# Strict identifiers, profile resolution, ownership, and payload validation fail closed.
mkdir -p "$fleet/task-malicious"
for profile in '../outside' '/tmp/outside' 'bad profile' 'UPPERCASE' 'missing-profile'; do
  if CALLBACK_LOG="$TEST_ROOT/malicious" callback register \
    task-malicious "$profile" req-malicious-001 >/dev/null 2>&1; then
    printf 'accepted malicious profile: %s\n' "$profile" >&2
    exit 1
  fi
done
for correlation in '../outside' '123456789012345678' 'discord:123' 'short' 'req bad'; do
  if CALLBACK_LOG="$TEST_ROOT/malicious" callback register \
    task-malicious hermes-discord "$correlation" >/dev/null 2>&1; then
    printf 'accepted malicious correlation: %s\n' "$correlation" >&2
    exit 1
  fi
done

outside="$TEST_ROOT/outside-callback"
cat > "$outside" <<EOF
#!/usr/bin/env bash
touch "$TEST_ROOT/arbitrary-command-ran"
EOF
chmod 700 "$outside"
ln -s "$outside" "$callbacks/symlinked"
if CALLBACK_LOG="$TEST_ROOT/malicious" callback register \
  task-malicious symlinked req-malicious-001 >/dev/null 2>&1; then
  printf 'accepted symlink callback profile\n' >&2
  exit 1
fi
[[ ! -e "$TEST_ROOT/arbitrary-command-ran" ]]

cp "$outside" "$callbacks/unsafe-mode"
chmod 722 "$callbacks/unsafe-mode"
if CALLBACK_LOG="$TEST_ROOT/malicious" callback register \
  task-malicious unsafe-mode req-malicious-001 >/dev/null 2>&1; then
  printf 'accepted writable callback profile\n' >&2
  exit 1
fi
[[ ! -e "$TEST_ROOT/arbitrary-command-ran" ]]

CALLBACK_LOG="$TEST_ROOT/malicious" callback register \
  task-malicious hermes-discord req-malicious-001
if printf 'Question follows.\nrm -rf /tmp/owned\n' | CALLBACK_LOG="$TEST_ROOT/malicious" \
  callback enqueue task-malicious failed malicious-multiline >/dev/null 2>&1; then
  printf 'accepted multiline command injection\n' >&2
  exit 1
fi
if printf 'run; touch /tmp/owned\n' | CALLBACK_LOG="$TEST_ROOT/malicious" \
  callback enqueue task-malicious failed malicious-shell >/dev/null 2>&1; then
  printf 'accepted shell metacharacters\n' >&2
  exit 1
fi
if printf 'DISCORD_BOT_TOKEN=not-a-real-token\n' | CALLBACK_LOG="$TEST_ROOT/malicious" \
  callback enqueue task-malicious failed malicious-secret >/dev/null 2>&1; then
  printf 'accepted secret-shaped payload\n' >&2
  exit 1
fi
if python3 - <<'PY' | CALLBACK_LOG="$TEST_ROOT/malicious" \
  callback enqueue task-malicious failed malicious-size >/dev/null 2>&1
print("x" * 4097, end="")
PY
then
  printf 'accepted oversized payload\n' >&2
  exit 1
fi
if printf '\377' | CALLBACK_LOG="$TEST_ROOT/malicious" \
  callback enqueue task-malicious failed malicious-utf8 >/dev/null 2>&1; then
  printf 'accepted invalid UTF-8 payload\n' >&2
  exit 1
fi
[[ "$(event_count task-malicious)" == "0" ]]
[[ ! -e "$TEST_ROOT/arbitrary-command-ran" ]]

chmod 722 "$callbacks"
if callback validate-origin hermes-discord req-malicious-001 >/dev/null 2>&1; then
  printf 'accepted group/world-writable callbacks directory\n' >&2
  exit 1
fi
chmod 700 "$callbacks"

printf 'sgt-callback durable contract: ok\n'
