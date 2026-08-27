#!/usr/bin/env bash
# Tests for bin/sgt-dispatch-queue --reorder (openspec/changes/dispatch-admission-control).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

pass=0
fail=0
_pass() { printf '  ok: %s\n' "$*"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n' "$*" >&2; fail=$((fail + 1)); }

fleet="$TEST_ROOT/fleet"
mkdir -p "$fleet"

_lib() {
  bash -c 'source "$1"; shift; "$@"' _ "$ROOT_DIR/bin/_sgt-lib.sh" "$@"
}

SERGEANT_FLEET="$fleet" _lib _sgt_dispatch_queue_enqueue task-a proj repo "a"
SERGEANT_FLEET="$fleet" _lib _sgt_dispatch_queue_enqueue task-b proj repo "b"
SERGEANT_FLEET="$fleet" _lib _sgt_dispatch_queue_enqueue task-c proj repo "c"

_queue() {
  SERGEANT_FLEET="$fleet" "$ROOT_DIR/bin/sgt-dispatch-queue" "$@"
}

# Sanity: initial FIFO order is a, b, c.
if [[ "$(cat "$fleet/.dispatch-queue/task-a/order")" -lt "$(cat "$fleet/.dispatch-queue/task-b/order")" && \
      "$(cat "$fleet/.dispatch-queue/task-b/order")" -lt "$(cat "$fleet/.dispatch-queue/task-c/order")" ]]; then
  _pass "initial FIFO order is a < b < c"
else
  _fail "initial FIFO order not established correctly"
fi

# Reorder task-c to position 1 (front of the line).
_queue --reorder task-c 1 >/dev/null

order_a="$(cat "$fleet/.dispatch-queue/task-a/order")"
order_b="$(cat "$fleet/.dispatch-queue/task-b/order")"
order_c="$(cat "$fleet/.dispatch-queue/task-c/order")"
if [[ "$order_c" -lt "$order_a" && "$order_a" -lt "$order_b" ]]; then
  _pass "sgt-dispatch-queue --reorder: task-c moved to position 1, ahead of a and b"
else
  _fail "sgt-dispatch-queue --reorder: expected order c < a < b, got a=$order_a b=$order_b c=$order_c"
fi

# The next promotion honors the new order: task-c (not task-a) is picked as
# the lowest-order entry now.
fake_bin="$TEST_ROOT/fake-bin"
mkdir -p "$fake_bin"
promote_log="$TEST_ROOT/promote.log"
cat > "$fake_bin/sgt-dispatch-fake" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$promote_log"
exit 0
EOF
chmod +x "$fake_bin/sgt-dispatch-fake"
: > "$promote_log"
SERGEANT_FLEET="$fleet" SERGEANT_DISPATCH_MAX_WORKERS=4 SGT_TEST_HOOKS=1 \
  _SGT_DISPATCH_QUEUE_EXECUTABLE_OVERRIDE="$fake_bin/sgt-dispatch-fake" \
  _lib _sgt_dispatch_queue_promote_ready
if [[ "$(cat "$promote_log")" == *"task-c"* ]]; then
  _pass "reordered position is honored by the next promotion (task-c promoted first)"
else
  _fail "expected task-c to be promoted first after reorder, got: $(cat "$promote_log")"
fi

# Reordering a task to a position beyond the queue length clamps to the back.
SERGEANT_FLEET="$fleet" _lib _sgt_dispatch_queue_enqueue task-d proj repo "d"
_queue --reorder task-a 999 >/dev/null
order_a2="$(cat "$fleet/.dispatch-queue/task-a/order")"
order_b2="$(cat "$fleet/.dispatch-queue/task-b/order")"
order_d2="$(cat "$fleet/.dispatch-queue/task-d/order")"
if [[ "$order_a2" -gt "$order_b2" && "$order_a2" -gt "$order_d2" ]]; then
  _pass "sgt-dispatch-queue --reorder: an out-of-range position clamps to the back of the queue"
else
  _fail "expected task-a pushed to the back, got a=$order_a2 b=$order_b2 d=$order_d2"
fi

# Reordering an unknown task ID fails loudly rather than silently no-op'ing.
set +e
_queue --reorder no-such-task 1 >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -ne 0 ]]; then
  _pass "sgt-dispatch-queue --reorder: unknown task ID is rejected"
else
  _fail "sgt-dispatch-queue --reorder: unknown task ID should fail"
fi

# A single-entry queue reorders without tripping bash 3.2's empty-array
# expansion behavior under `set -u` (this repo's scripts run under
# /usr/bin/env bash, which resolves to macOS's system bash 3.2).
solo_fleet="$TEST_ROOT/solo-fleet"
mkdir -p "$solo_fleet"
SERGEANT_FLEET="$solo_fleet" _lib _sgt_dispatch_queue_enqueue solo-task proj repo "solo brief"
solo_out="$(SERGEANT_FLEET="$solo_fleet" "$ROOT_DIR/bin/sgt-dispatch-queue" --reorder solo-task 1 2>&1)"
solo_status=$?
if [[ "$solo_status" -eq 0 && "$(cat "$solo_fleet/.dispatch-queue/solo-task/order")" == "1" ]]; then
  _pass "sgt-dispatch-queue --reorder: a single-entry queue reorders cleanly"
else
  _fail "sgt-dispatch-queue --reorder: single-entry reorder failed: $solo_out"
fi

printf '\nsgt-dispatch-queue-reorder: %d passed' "$pass"
if [[ "$fail" -gt 0 ]]; then
  printf ', %d FAILED\n' "$fail" >&2
  exit 1
fi
printf '\n'
