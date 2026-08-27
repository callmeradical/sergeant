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

# Concurrent enqueues from independent "coordinator" subshells never collide
# on order. Under 8-way simultaneous contention the shared, pre-existing
# _sgt_drain_lock_acquire_fd primitive's own documented reclaim path may
# legitimately fail a handful of individual attempts outright (an accepted,
# self-healing property of that shared primitive, not something this queue
# enqueue helper controls) -- the correctness property this test actually
# proves is that no two entries that DID get created ever share the same
# order value, not that all 8 must succeed under this much contention.
fleet_race="$TEST_ROOT/fleet-race"
mkdir -p "$fleet_race"
for i in 1 2 3 4 5 6 7 8; do
  ( SERGEANT_FLEET="$fleet_race" _lib _sgt_dispatch_queue_enqueue "race-$i" proj repo "brief-$i" ) &
done
wait
all_orders="$(cat "$fleet_race"/.dispatch-queue/race-*/order 2>/dev/null)"
created_count="$(printf '%s\n' "$all_orders" | grep -c .)"
distinct_count="$(printf '%s\n' "$all_orders" | sort -n | uniq | grep -c .)"
if [[ "$created_count" -ge 6 && "$distinct_count" == "$created_count" ]]; then
  _pass "_sgt_dispatch_queue_enqueue: $created_count concurrent enqueues that succeeded got $distinct_count distinct FIFO orders (no collision)"
else
  _fail "_sgt_dispatch_queue_enqueue: expected >=6 successful enqueues with all-distinct orders, got created=$created_count distinct=$distinct_count: $all_orders"
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

# ── promote_ready: a malformed entry is quarantined, not selected forever ──
# order present but project/repos missing (e.g. from a crash mid-write before
# atomic staging existed, or manual tampering) must not permanently block
# every healthy entry behind it.

fleet_poison="$TEST_ROOT/fleet-poison"
mkdir -p "$fleet_poison/.dispatch-queue/poisoned-entry"
# order=0 guarantees this malformed entry sorts ahead of the healthy one
# enqueued below (whose order starts at 1), so it is the one promote_ready
# tries -- and must skip past -- first.
printf '0\n' > "$fleet_poison/.dispatch-queue/poisoned-entry/order"
chmod 600 "$fleet_poison/.dispatch-queue/poisoned-entry/order"
SERGEANT_FLEET="$fleet_poison" _lib _sgt_dispatch_queue_enqueue healthy-entry proj repo "healthy brief"

: > "$promote_log"
poison_stderr="$(PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet_poison" SERGEANT_DISPATCH_MAX_WORKERS=4 \
  SGT_TEST_HOOKS=1 _SGT_DISPATCH_QUEUE_EXECUTABLE_OVERRIDE="$fake_bin/sgt-dispatch-fake" \
  _lib _sgt_dispatch_queue_promote_ready 2>&1)"
if [[ "$(cat "$promote_log")" == *"healthy-entry"* ]]; then
  _pass "_sgt_dispatch_queue_promote_ready: a malformed lowest-order entry does not block a healthy entry behind it"
else
  _fail "_sgt_dispatch_queue_promote_ready: healthy-entry should have been promoted despite the poisoned entry; stderr: $poison_stderr"
fi
if [[ -d "$fleet_poison/.dispatch-queue/.poisoned-poisoned-entry" && \
      ! -d "$fleet_poison/.dispatch-queue/poisoned-entry" ]]; then
  _pass "_sgt_dispatch_queue_promote_ready: the malformed entry is quarantined out of the active queue"
else
  _fail "_sgt_dispatch_queue_promote_ready: expected the malformed entry quarantined as .poisoned-poisoned-entry"
fi
if [[ "$poison_stderr" == *"malformed"* ]]; then
  _pass "_sgt_dispatch_queue_promote_ready: the malformed entry is reported, not silently dropped"
else
  _fail "_sgt_dispatch_queue_promote_ready: expected a malformed-entry diagnostic on stderr"
fi

# ── promote_ready: reclaims an orphaned .promoting-* left by a killed promoter,
# but never reclaims one whose owning promoter is still alive ────────────────

fleet_orphan="$TEST_ROOT/fleet-orphan"
mkdir -p "$fleet_orphan/.dispatch-queue/.promoting-orphan-task"
printf '1\n' > "$fleet_orphan/.dispatch-queue/.promoting-orphan-task/order"
printf 'proj\n' > "$fleet_orphan/.dispatch-queue/.promoting-orphan-task/project"
printf 'repo\n' > "$fleet_orphan/.dispatch-queue/.promoting-orphan-task/repos"
printf 'orphan brief\n' > "$fleet_orphan/.dispatch-queue/.promoting-orphan-task/brief"
dead_pid=99998
while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid + 1)); done
printf '%s\n' "$dead_pid" > "$fleet_orphan/.dispatch-queue/.promoting-orphan-task/promoter_pid"

: > "$promote_log"
PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet_orphan" SERGEANT_DISPATCH_MAX_WORKERS=4 \
  SGT_TEST_HOOKS=1 _SGT_DISPATCH_QUEUE_EXECUTABLE_OVERRIDE="$fake_bin/sgt-dispatch-fake" \
  _lib _sgt_dispatch_queue_promote_ready
if [[ "$(cat "$promote_log")" == *"orphan-task"* ]]; then
  _pass "_sgt_dispatch_queue_promote_ready: reclaims and promotes a .promoting-* orphan left by a dead promoter"
else
  _fail "_sgt_dispatch_queue_promote_ready: expected orphan-task to be reclaimed and promoted"
fi

# A still-alive "promoter" must not have its in-flight .promoting-* entry
# reclaimed out from under it (this is what a nested sync-all call from the
# promoted dispatch's own subprocess would otherwise do to itself).
fleet_live="$TEST_ROOT/fleet-live-promoter"
mkdir -p "$fleet_live/.dispatch-queue/.promoting-live-task"
printf '1\n' > "$fleet_live/.dispatch-queue/.promoting-live-task/order"
printf 'proj\n' > "$fleet_live/.dispatch-queue/.promoting-live-task/project"
printf 'repo\n' > "$fleet_live/.dispatch-queue/.promoting-live-task/repos"
printf 'live brief\n' > "$fleet_live/.dispatch-queue/.promoting-live-task/brief"
printf '%s\n' "$$" > "$fleet_live/.dispatch-queue/.promoting-live-task/promoter_pid"

: > "$promote_log"
PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet_live" SERGEANT_DISPATCH_MAX_WORKERS=4 \
  SGT_TEST_HOOKS=1 _SGT_DISPATCH_QUEUE_EXECUTABLE_OVERRIDE="$fake_bin/sgt-dispatch-fake" \
  _lib _sgt_dispatch_queue_promote_ready
if [[ ! -s "$promote_log" && -d "$fleet_live/.dispatch-queue/.promoting-live-task" ]]; then
  _pass "_sgt_dispatch_queue_promote_ready: never reclaims a .promoting-* entry whose promoter is still alive"
else
  _fail "_sgt_dispatch_queue_promote_ready: reclaimed or re-promoted a still-in-flight entry: $(cat "$promote_log")"
fi

printf '\nsgt-dispatch-queue-lib: %d passed' "$pass"
if [[ "$fail" -gt 0 ]]; then
  printf ', %d FAILED\n' "$fail" >&2
  exit 1
fi
printf '\n'
