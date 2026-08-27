#!/usr/bin/env bash
# Tests for the durable dispatch queue helpers added for
# openspec/changes/dispatch-admission-control: _sgt_dispatch_queue_enqueue and
# _sgt_dispatch_queue_promote_ready.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

pass=0
fail=0
_pass() { printf '  ok: %s\n' "$*"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n' "$*" >&2; fail=$((fail + 1)); }

_lib() {
  bash -c 'source "$1"; shift; "$@"' _ "$ROOT_DIR/bin/_sgt-lib.sh" "$@"
}

fleet="$TEST_ROOT/fleet"
mkdir -p "$fleet"

# ── enqueue ────────────────────────────────────────────────────────────────────

SERGEANT_FLEET="$fleet" _lib _sgt_dispatch_queue_enqueue task-1 myproj app,svc "do the thing" || \
  _fail "enqueue task-1 failed"

entry="$fleet/.dispatch-queue/task-1"
if [[ -d "$entry" ]]; then
  _pass "_sgt_dispatch_queue_enqueue: creates a durable queue entry directory"
else
  _fail "_sgt_dispatch_queue_enqueue: no entry directory created"
fi
if [[ "$(cat "$entry/project" 2>/dev/null)" == "myproj" && \
      "$(cat "$entry/repos" 2>/dev/null)" == "app,svc" && \
      "$(cat "$entry/brief" 2>/dev/null)" == "do the thing" ]]; then
  _pass "_sgt_dispatch_queue_enqueue: persists project/repos/brief so the task is inspectable immediately"
else
  _fail "_sgt_dispatch_queue_enqueue: recorded fields wrong: $(cat "$entry/project" 2>/dev/null) / $(cat "$entry/repos" 2>/dev/null) / $(cat "$entry/brief" 2>/dev/null)"
fi
if [[ ! -f "$entry/td_task" ]]; then
  _pass "_sgt_dispatch_queue_enqueue: omits td_task file when none was given"
else
  _fail "_sgt_dispatch_queue_enqueue: td_task file should not exist when not given"
fi

SERGEANT_FLEET="$fleet" _lib _sgt_dispatch_queue_enqueue task-with-td myproj app "brief" td-abc123
if [[ "$(cat "$fleet/.dispatch-queue/task-with-td/td_task" 2>/dev/null)" == "td-abc123" ]]; then
  _pass "_sgt_dispatch_queue_enqueue: persists an explicit td task id when given"
else
  _fail "_sgt_dispatch_queue_enqueue: td_task not recorded"
fi

# FIFO ordering: task-1 enqueued before task-2, so task-1's order is lower.
SERGEANT_FLEET="$fleet" _lib _sgt_dispatch_queue_enqueue task-2 myproj app "second"
order1="$(cat "$fleet/.dispatch-queue/task-1/order")"
order2="$(cat "$fleet/.dispatch-queue/task-2/order")"
if [[ "$order1" -lt "$order2" ]]; then
  _pass "_sgt_dispatch_queue_enqueue: earlier enqueue gets a lower FIFO order ($order1 < $order2)"
else
  _fail "_sgt_dispatch_queue_enqueue: expected order1 < order2, got $order1 vs $order2"
fi

# Concurrent enqueues from independent "coordinator" subshells never collide on order.
fleet_race="$TEST_ROOT/fleet-race"
mkdir -p "$fleet_race"
for i in 1 2 3 4 5 6 7 8; do
  ( SERGEANT_FLEET="$fleet_race" _lib _sgt_dispatch_queue_enqueue "race-$i" proj repo "brief-$i" ) &
done
wait
orders="$(cat "$fleet_race"/.dispatch-queue/race-*/order | sort -n | uniq)"
order_count="$(printf '%s\n' "$orders" | wc -l | tr -d ' ')"
if [[ "$order_count" == "8" ]]; then
  _pass "_sgt_dispatch_queue_enqueue: 8 concurrent enqueues produce 8 distinct FIFO order values"
else
  _fail "_sgt_dispatch_queue_enqueue: expected 8 distinct order values, got $order_count: $orders"
fi

# ── promote_ready: no-op cases ────────────────────────────────────────────────

fake_bin="$TEST_ROOT/fake-bin"
mkdir -p "$fake_bin"
promote_log="$TEST_ROOT/promote.log"
cat > "$fake_bin/sgt-dispatch-fake" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$promote_log"
exit 0
EOF
chmod +x "$fake_bin/sgt-dispatch-fake"

# Over budget (SERGEANT_DISPATCH_MAX_WORKERS=0 forces budget=1 via the floor,
# but with one verified-live worker already recorded, live >= budget) -> no
# promotion attempt, task stays queued indefinitely (no expiry).
fleet_full="$TEST_ROOT/fleet-full"
mkdir -p "$fleet_full/busy-task/app"
printf 'in_progress\n' > "$fleet_full/busy-task/app/status"
printf '%%1\n' > "$fleet_full/busy-task/app/pane"
printf '0|%%1|100|10|cmd\n' > "$fleet_full/busy-task/app/pane_identity"
chmod 600 "$fleet_full/busy-task/app/pane_identity"
cat > "$fake_bin/tmux" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "display-message" ]]; then
  for a in "$@"; do [[ "$a" == "%1" ]] && { printf '0|%%1|100|10|cmd\n'; exit 0; }; done
  exit 1
fi
exit 1
EOF
chmod +x "$fake_bin/tmux"
SERGEANT_FLEET="$fleet_full" _lib _sgt_dispatch_queue_enqueue queued-1 proj repo "brief" >/dev/null

: > "$promote_log"
PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet_full" SERGEANT_DISPATCH_MAX_WORKERS=1 \
  SGT_TEST_HOOKS=1 _SGT_DISPATCH_QUEUE_EXECUTABLE_OVERRIDE="$fake_bin/sgt-dispatch-fake" \
  _lib _sgt_dispatch_queue_promote_ready || true
if [[ ! -s "$promote_log" && -d "$fleet_full/.dispatch-queue/queued-1" ]]; then
  _pass "_sgt_dispatch_queue_promote_ready: over budget -> no promotion attempt, entry remains queued (indefinite wait)"
else
  _fail "_sgt_dispatch_queue_promote_ready: should not have promoted while over budget: log='$(cat "$promote_log" 2>/dev/null)'"
fi

# ── promote_ready: capacity available -> promotes lowest-order entry ────────

fleet_idle="$TEST_ROOT/fleet-idle"
mkdir -p "$fleet_idle"
SERGEANT_FLEET="$fleet_idle" _lib _sgt_dispatch_queue_enqueue first-in proj repo "first brief"
SERGEANT_FLEET="$fleet_idle" _lib _sgt_dispatch_queue_enqueue second-in proj repo "second brief" td-xyz

: > "$promote_log"
PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet_idle" SERGEANT_DISPATCH_MAX_WORKERS=4 \
  SGT_TEST_HOOKS=1 _SGT_DISPATCH_QUEUE_EXECUTABLE_OVERRIDE="$fake_bin/sgt-dispatch-fake" \
  _lib _sgt_dispatch_queue_promote_ready
promoted_call="$(cat "$promote_log")"
if [[ "$promoted_call" == *"first-in"* && "$promoted_call" != *"second-in"* ]]; then
  _pass "_sgt_dispatch_queue_promote_ready: promotes the lowest-order (first-enqueued) entry, not a later one"
else
  _fail "_sgt_dispatch_queue_promote_ready: expected first-in promoted, got: $promoted_call"
fi
if [[ "$promoted_call" == *"proj"*"first brief"*"--repos"*"repo"*"--resume-task-id"*"first-in"* ]]; then
  _pass "_sgt_dispatch_queue_promote_ready: replays project/brief/repos and reuses the original task ID"
else
  _fail "_sgt_dispatch_queue_promote_ready: replay args wrong: $promoted_call"
fi
if [[ ! -d "$fleet_idle/.dispatch-queue/first-in" && ! -d "$fleet_idle/.dispatch-queue/.promoting-first-in" ]]; then
  _pass "_sgt_dispatch_queue_promote_ready: dequeues the promoted entry on success"
else
  _fail "_sgt_dispatch_queue_promote_ready: promoted entry should be removed from the queue"
fi
if [[ -d "$fleet_idle/.dispatch-queue/second-in" ]]; then
  _pass "_sgt_dispatch_queue_promote_ready: leaves the not-yet-promoted entry queued"
else
  _fail "_sgt_dispatch_queue_promote_ready: second-in should remain queued"
fi

# A queued entry that carried an explicit td task id replays --td too.
: > "$promote_log"
PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet_idle" SERGEANT_DISPATCH_MAX_WORKERS=4 \
  SGT_TEST_HOOKS=1 _SGT_DISPATCH_QUEUE_EXECUTABLE_OVERRIDE="$fake_bin/sgt-dispatch-fake" \
  _lib _sgt_dispatch_queue_promote_ready
second_call="$(cat "$promote_log")"
if [[ "$second_call" == *"--td"*"td-xyz"* ]]; then
  _pass "_sgt_dispatch_queue_promote_ready: replays the originally-recorded --td task id"
else
  _fail "_sgt_dispatch_queue_promote_ready: expected --td td-xyz in replay, got: $second_call"
fi

# ── promote_ready: failed promotion restores the entry (retry, not drop) ────

fleet_retry="$TEST_ROOT/fleet-retry"
mkdir -p "$fleet_retry"
SERGEANT_FLEET="$fleet_retry" _lib _sgt_dispatch_queue_enqueue flaky proj repo "brief"
cat > "$fake_bin/sgt-dispatch-fail" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$fake_bin/sgt-dispatch-fail"
set +e
PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet_retry" SERGEANT_DISPATCH_MAX_WORKERS=4 \
  SGT_TEST_HOOKS=1 _SGT_DISPATCH_QUEUE_EXECUTABLE_OVERRIDE="$fake_bin/sgt-dispatch-fail" \
  _lib _sgt_dispatch_queue_promote_ready
promote_status=$?
set -e
if [[ "$promote_status" -ne 0 && -f "$fleet_retry/.dispatch-queue/flaky/order" ]]; then
  _pass "_sgt_dispatch_queue_promote_ready: a failed promotion restores the entry to the queue for a later attempt"
else
  _fail "_sgt_dispatch_queue_promote_ready: failed promotion should requeue 'flaky' with its order intact"
fi

printf '\nsgt-dispatch-queue-lib: %d passed' "$pass"
if [[ "$fail" -gt 0 ]]; then
  printf ', %d FAILED\n' "$fail" >&2
  exit 1
fi
printf '\n'
