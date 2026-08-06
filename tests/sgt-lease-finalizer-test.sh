#!/usr/bin/env bash
# Regression for the single response-lock-protected action-lease finalizer
# (td-959be2 / GH #168).
#
# Notification delivery used to report success once the nudge was accepted and
# delivered, while action *completion* depended on a separate marker only the
# agent could write.  A worker that finished substantive work without that marker
# left its accepted lease pending forever; terminal recycling then stopped it and
# both sgt-respond and sgt-recover refused the lease as prior-supervisor-owned,
# so no supported command could converge it.
#
# There must be exactly ONE finalizer, it must hold the response lock, it must
# never fabricate completion, and it must leave an explicit record either way.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# shellcheck source=bin/_sgt-response-lock.sh
source "$ROOT_DIR/bin/_sgt-response-lock.sh"

NONCE_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
NONCE_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# fixture <name> — a repo state + worktree pair with an accepted turn.
# Prints "<state> <worktree>".
fixture() {
  local name="$1" notification_id="${2:-notify-$1}" nonce="${3:-$NONCE_A}"
  local state="$TEST_ROOT/$name/state" worktree="$TEST_ROOT/$name/worktree"
  local target_dir="$state/notifications/$notification_id/targets/$nonce"
  mkdir -p "$target_dir" "$worktree/.sergeant-notification-complete"
  printf '%s\n' "$notification_id" > "$state/notification_id"
  printf '%s\n' "$nonce" > "$state/notification_target"
  printf '%s\n' "$nonce" > "$state/notifications/$notification_id/action_lease"
  printf '%s|%s\n' "$notification_id" "$nonce" > "$target_dir/acknowledged"
  printf '%s|%s\n' "$notification_id" "$nonce" > "$target_dir/accepted"
  printf '%s|%s\n' "$notification_id" "$nonce" > "$target_dir/delivered"
  printf '%s %s\n' "$state" "$worktree"
}

_finalize() {
  _SGT_RESPONSE_LOCK_DIR=""
  _sgt_finalize_action_lease "$@"
}

# ── 1. Nothing to finalize is a success, and records nothing ──────────────────

mkdir -p "$TEST_ROOT/empty/state" "$TEST_ROOT/empty/worktree"
_finalize "$TEST_ROOT/empty/state" "$TEST_ROOT/empty/worktree" "worker_exit:done" || {
  printf 'finalizer failed when there was no notification at all\n' >&2
  exit 1
}
[[ -z "$(find "$TEST_ROOT/empty/state" -name 'action_lease_*' 2>/dev/null)" ]] || {
  printf 'finalizer recorded a lease outcome with no notification\n' >&2
  exit 1
}

mkdir -p "$TEST_ROOT/nolease/state/notifications/n1" "$TEST_ROOT/nolease/worktree"
printf 'n1\n' > "$TEST_ROOT/nolease/state/notification_id"
_finalize "$TEST_ROOT/nolease/state" "$TEST_ROOT/nolease/worktree" "worker_exit:done" || {
  printf 'finalizer failed when no action lease was taken\n' >&2
  exit 1
}
[[ -z "$(find "$TEST_ROOT/nolease/state" -name 'action_lease_*' 2>/dev/null)" ]] || {
  printf 'finalizer recorded a lease outcome with no lease\n' >&2
  exit 1
}

# ── 2. A completed turn finalizes its lease atomically ───────────────────────

read -r state worktree <<<"$(fixture completed)"
printf 'notify-completed|%s\n' "$NONCE_A" > \
  "$worktree/.sergeant-notification-complete/$NONCE_A"
_finalize "$state" "$worktree" "worker_exit:done" || {
  printf 'finalizer refused a provably completed turn\n' >&2
  exit 1
}
target="$state/notifications/notify-completed/targets/$NONCE_A"
[[ "$(cat "$target/completed")" == "notify-completed|$NONCE_A" ]] || {
  printf 'completion was not published for a completed turn: %s\n' \
    "$(cat "$target/completed" 2>/dev/null || true)" >&2
  exit 1
}
[[ -s "$state/notifications/notify-completed/action_lease_finalized" ]] || {
  printf 'no finalization record was written for a completed turn\n' >&2
  exit 1
}
grep -Fq "notify-completed|$NONCE_A" \
  "$state/notifications/notify-completed/action_lease_finalized"
grep -Fq 'worker_exit:done' \
  "$state/notifications/notify-completed/action_lease_finalized"
[[ ! -e "$state/notifications/notify-completed/action_lease_pending" ]]
# The lock must not be left behind.
[[ ! -e "$state/response.lock" && ! -L "$state/response.lock" ]] || {
  printf 'finalizer leaked the response lock\n' >&2
  exit 1
}

# ── 3. Finalization is idempotent ────────────────────────────────────────────

first_record="$(cat "$state/notifications/notify-completed/action_lease_finalized")"
_finalize "$state" "$worktree" "recycle" || {
  printf 'second finalization of an already finalized lease failed\n' >&2
  exit 1
}
[[ "$(cat "$target/completed")" == "notify-completed|$NONCE_A" ]]
[[ "$(cat "$state/notifications/notify-completed/action_lease_finalized")" == "$first_record" ]] || {
  printf 'idempotent finalization rewrote the finalization record\n' >&2
  exit 1
}

# ── 4. An unproven turn is preserved with a recorded reason, never completed ──

read -r state worktree <<<"$(fixture pending)"
if _finalize "$state" "$worktree" "worker_exit:orphaned"; then
  printf 'finalizer reported success for a turn with no completion proof\n' >&2
  exit 1
fi
target="$state/notifications/notify-pending/targets/$NONCE_A"
[[ ! -e "$target/completed" ]] || {
  printf 'finalizer fabricated completion without agent proof\n' >&2
  exit 1
}
[[ -s "$state/notifications/notify-pending/action_lease_pending" ]] || {
  printf 'an unfinalized lease was left with no recorded reason\n' >&2
  exit 1
}
grep -Fq "$NONCE_A" "$state/notifications/notify-pending/action_lease_pending"
grep -Fq 'worker_exit:orphaned' \
  "$state/notifications/notify-pending/action_lease_pending"
[[ ! -e "$state/notifications/notify-pending/action_lease_finalized" ]]
[[ ! -e "$state/response.lock" && ! -L "$state/response.lock" ]]

# ── 5. Identity and nonce mismatches fail closed ─────────────────────────────

read -r state worktree <<<"$(fixture wrongid)"
printf 'some-other-notification|%s\n' "$NONCE_A" > \
  "$worktree/.sergeant-notification-complete/$NONCE_A"
if _finalize "$state" "$worktree" "worker_exit:done"; then
  printf 'a mismatched notification id was accepted as completion proof\n' >&2
  exit 1
fi
[[ ! -e "$state/notifications/notify-wrongid/targets/$NONCE_A/completed" ]] || {
  printf 'a mismatched notification id fabricated completion\n' >&2
  exit 1
}
grep -Fq 'mismatch' "$state/notifications/notify-wrongid/action_lease_pending" || {
  printf 'identity mismatch was not recorded as such:\n%s\n' \
    "$(cat "$state/notifications/notify-wrongid/action_lease_pending")" >&2
  exit 1
}

read -r state worktree <<<"$(fixture wrongnonce)"
printf 'notify-wrongnonce|%s\n' "$NONCE_B" > \
  "$worktree/.sergeant-notification-complete/$NONCE_A"
if _finalize "$state" "$worktree" "worker_exit:done"; then
  printf 'a mismatched nonce was accepted as completion proof\n' >&2
  exit 1
fi
[[ ! -e "$state/notifications/notify-wrongnonce/targets/$NONCE_A/completed" ]]
grep -Fq 'mismatch' "$state/notifications/notify-wrongnonce/action_lease_pending"

# A completion proof filed under a DIFFERENT nonce must not finalize this lease.
read -r state worktree <<<"$(fixture othernonce)"
printf 'notify-othernonce|%s\n' "$NONCE_B" > \
  "$worktree/.sergeant-notification-complete/$NONCE_B"
if _finalize "$state" "$worktree" "worker_exit:done"; then
  printf 'a proof for another nonce finalized this lease\n' >&2
  exit 1
fi
[[ ! -e "$state/notifications/notify-othernonce/targets/$NONCE_A/completed" ]]

# ── 6. A malformed lease fails closed ────────────────────────────────────────

read -r state worktree <<<"$(fixture badlease)"
printf 'not-a-nonce\n' > "$state/notifications/notify-badlease/action_lease"
if _finalize "$state" "$worktree" "worker_exit:done"; then
  printf 'a malformed action lease was silently accepted\n' >&2
  exit 1
fi
grep -Fq 'invalid' "$state/notifications/notify-badlease/action_lease_pending" || {
  printf 'a malformed lease was not recorded as invalid:\n%s\n' \
    "$(cat "$state/notifications/notify-badlease/action_lease_pending" 2>/dev/null || true)" >&2
  exit 1
}

# A lease naming a target directory that does not exist fails closed.
read -r state worktree <<<"$(fixture ghostlease)"
printf '%s\n' "$NONCE_B" > "$state/notifications/notify-ghostlease/action_lease"
printf 'notify-ghostlease|%s\n' "$NONCE_B" > \
  "$worktree/.sergeant-notification-complete/$NONCE_B"
if _finalize "$state" "$worktree" "worker_exit:done"; then
  printf 'a lease with no target directory was finalized\n' >&2
  exit 1
fi
[[ -s "$state/notifications/notify-ghostlease/action_lease_pending" ]]

# ── 7. The finalizer is reentrant for a caller that already holds the lock ────

read -r state worktree <<<"$(fixture nested)"
printf 'notify-nested|%s\n' "$NONCE_A" > \
  "$worktree/.sergeant-notification-complete/$NONCE_A"
_SGT_RESPONSE_LOCK_DIR=""
_sgt_response_lock_acquire "$state"
[[ -e "$state/response.lock" ]]
_sgt_finalize_action_lease "$state" "$worktree" "held-by-caller" || {
  printf 'finalizer failed when the caller already held the response lock\n' >&2
  exit 1
}
[[ "$(cat "$state/notifications/notify-nested/targets/$NONCE_A/completed")" == \
   "notify-nested|$NONCE_A" ]]
# The caller still owns the lock: the finalizer must not have released it.
[[ -e "$state/response.lock" ]] || {
  printf 'finalizer released a lock it did not acquire\n' >&2
  exit 1
}
_sgt_response_lock_release
[[ ! -e "$state/response.lock" ]]

# ── 7b. A lock recorded against this same process never blocks the finalizer ──
# The lock records "$$", which is identical in every subshell of one process, so
# a background loop killed mid-critical-section leaves a record naming a PID that
# is still alive.  Waiting on it could never succeed.

read -r state worktree <<<"$(fixture samepid)"
printf 'notify-samepid|%s\n' "$NONCE_A" > \
  "$worktree/.sergeant-notification-complete/$NONCE_A"
printf '%s\n' "$$" > "$state/response.lock"
_SGT_RESPONSE_LOCK_DIR=""
_sgt_response_lock_held_by_this_process "$state" || {
  printf 'a lock naming this process was not detected as such\n' >&2
  exit 1
}
if _sgt_finalize_action_lease "$state" "$worktree" "delivery-loop-holds-lock"; then
  printf 'finalizer claimed success while another context held the lock\n' >&2
  exit 1
fi
[[ ! -e "$state/notifications/notify-samepid/targets/$NONCE_A/completed" ]] || {
  printf 'finalizer bypassed the response lock\n' >&2
  exit 1
}
grep -Fq 'held by another context in this process' \
  "$state/notifications/notify-samepid/action_lease_pending" || {
  printf 'the same-process lock contention was not recorded:\n%s\n' \
    "$(cat "$state/notifications/notify-samepid/action_lease_pending")" >&2
  exit 1
}

# Reclaiming our own lock — safe only once those contexts are gone — lets the
# exit boundary settle the lease.
_sgt_response_lock_reclaim "$state"
[[ ! -e "$state/response.lock" ]] || {
  printf 'reclaim did not drop a lock owned by this process\n' >&2
  exit 1
}
rm -f "$state/notifications/notify-samepid/action_lease_pending"
_finalize "$state" "$worktree" "worker_exit:done" || {
  printf 'finalizer failed after reclaiming this process own lock\n' >&2
  exit 1
}
[[ "$(cat "$state/notifications/notify-samepid/targets/$NONCE_A/completed")" == \
   "notify-samepid|$NONCE_A" ]]

# Reclaim must never remove a lock owned by a different, live process.
read -r state worktree <<<"$(fixture foreignlock)"
sleep 120 &
foreign_pid=$!
printf '%s\n' "$foreign_pid" > "$state/response.lock"
_SGT_RESPONSE_LOCK_DIR=""
if _sgt_response_lock_held_by_this_process "$state"; then
  printf 'a foreign lock was misreported as owned by this process\n' >&2
  kill "$foreign_pid" 2>/dev/null || true
  exit 1
fi
_sgt_response_lock_reclaim "$state"
[[ -e "$state/response.lock" ]] || {
  printf 'reclaim removed a lock owned by a live foreign process\n' >&2
  kill "$foreign_pid" 2>/dev/null || true
  exit 1
}
kill "$foreign_pid" 2>/dev/null || true
wait "$foreign_pid" 2>/dev/null || true
rm -f "$state/response.lock"

# ── 8. Delivery state and action completion are reported distinctly ───────────

read -r state worktree <<<"$(fixture distinct)"
# Delivered and accepted, but the action is not complete.
_sgt_notification_action_pending "$state" "notify-distinct" || {
  printf 'an accepted-but-incomplete turn was not reported as action-pending\n' >&2
  exit 1
}
if _sgt_notification_action_completed "$state" "notify-distinct"; then
  printf 'a delivered turn was reported as action-completed\n' >&2
  exit 1
fi
printf 'notify-distinct|%s\n' "$NONCE_A" > \
  "$worktree/.sergeant-notification-complete/$NONCE_A"
_finalize "$state" "$worktree" "worker_exit:done"
_sgt_notification_action_completed "$state" "notify-distinct" || {
  printf 'a completed turn was not reported as action-completed\n' >&2
  exit 1
}
if _sgt_notification_action_pending "$state" "notify-distinct"; then
  printf 'a completed turn was still reported as action-pending\n' >&2
  exit 1
fi

# ── 9. There is exactly one finalizer implementation ─────────────────────────
# Every writer of targets/<nonce>/completed must go through the shared helper.

writers="$(grep -rln 'completed\.tmp\.' "$ROOT_DIR/bin" 2>/dev/null || true)"
[[ "$writers" == "$ROOT_DIR/bin/_sgt-response-lock.sh" ]] || {
  printf 'action completion is published outside the shared finalizer:\n%s\n' \
    "$writers" >&2
  exit 1
}

printf 'action-lease finalizer: ok\n'
