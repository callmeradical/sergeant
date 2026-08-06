#!/usr/bin/env bash
# Regression: EVERY worker-exit branch settles its accepted action lease, and
# terminal recycling invokes the same finalizer (td-959be2 / GH #168).
#
# _finish used to kill the background loops and write status/handoff without any
# reference to action_lease or completed.  The drained, needs_input, blocked,
# waiting and orphaned branches therefore all exited with the lease pending, and
# sgt-watch then recycled away the only process that could ever publish
# completion.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
TMUX_SESSION="sgt-lease-exit-test-$$"
# Run against a private tmux server.  Sharing the developer's server makes these
# tests contend with every other pane on it — including ones leaked by other
# suites — which turns pane operations slow enough to blow the per-test budget,
# and it leaks panes back the other way.  Child `tmux` calls inside the worker
# follow $TMUX, so they reach this same private server.
export TMUX_TMPDIR="$TEST_ROOT/tmux"
mkdir -p "$TMUX_TMPDIR"

trap 'tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true; rm -rf "$TEST_ROOT"' EXIT

command -v tmux >/dev/null 2>&1 || {
  printf 'tmux is required for the exit-branch lease regression\n' >&2
  exit 1
}

mkdir -p "$TEST_ROOT/fake-bin"

# A harness that completes the handshake, then exits in a requested terminal or
# nonterminal state.  PUBLISH_COMPLETION=0 makes it exit WITHOUT ever writing its
# completion proof — the pending case the finalizer must record rather than
# fabricate.
cat > "$TEST_ROOT/fake-bin/opencode" <<'HARNESS'
#!/usr/bin/env bash
set -uo pipefail
printf 'harness up\n'
IFS= read -r nudge || exit 90
token="$(printf '%s' "$nudge" | \
  sed -n 's/.*, write \([^ ][^ ]*\) to \([^ ][^ ]*\), and do not act.*/\1/p')"
ack_path="$(printf '%s' "$nudge" | \
  sed -n 's/.*, write \([^ ][^ ]*\) to \([^ ][^ ]*\), and do not act.*/\2/p')"
[[ -n "$token" && -n "$ack_path" ]] || exit 91
nonce="${token#*|}"
mkdir -p "$(dirname "$ack_path")"
printf '%s\n' "$token" > "$ack_path"
for _ in $(seq 1 2000); do
  [[ "$(cat ".sergeant-notification-accepts/$nonce" 2>/dev/null || true)" == "$token" ]] && break
  sleep 0.02
done
[[ "$(cat ".sergeant-notification-accepts/$nonce" 2>/dev/null || true)" == "$token" ]] || exit 92
for _ in $(seq 1 200); do
  IFS= read -r -t 1 candidate || break
  [[ "$candidate" == *"Sergeant accepted $token"* ]] && break
done
if [[ "${PUBLISH_COMPLETION:-1}" == 1 ]]; then
  mkdir -p .sergeant-notification-complete
  printf '%s\n' "$token" > ".sergeant-notification-complete/$nonce"
fi
touch "$HANDSHAKE_DONE_FILE"
case "${EXIT_AS:-done}" in
  done)
    printf 'https://example.invalid/pr/1\n' > .sergeant-result
    printf 'done\n' > .sergeant-status
    ;;
  orphaned) : ;;  # exit with .sergeant-status still in_progress
  failed) printf 'failed: deliberate test failure\n' > .sergeant-status ;;
  *)
    printf 'Awaiting a decision.\n' > .sergeant-message
    printf '%s\n' "${EXIT_AS}" > .sergeant-status
    ;;
esac
exit 0
HARNESS
chmod +x "$TEST_ROOT/fake-bin/opencode"

tmux new-session -d -s "$TMUX_SESSION" -n keepalive "while :; do sleep 1; done"

# run_branch <label> <exit_as> <publish_completion>
# Prints "<state> <worktree> <notification_id> <nonce>".
run_branch() {
  local label="$1" exit_as="$2" publish="$3"
  local state="$TEST_ROOT/$label/state" worktree="$TEST_ROOT/$label/worktree"
  local notification_id="notify-$label"
  local pane identity nonce target_dir

  mkdir -p "$state" "$worktree"
  printf 'in_progress\n' > "$worktree/.sergeant-status"
  printf '1\n' > "$worktree/.sergeant-gate-generation"
  printf '%s\n' "$notification_id" > "$state/notification_id"
  printf '%s\n' "$worktree" > "$state/worktree"
  cat > "$worktree/.sergeant-notification" <<EOF
notification_id=$notification_id
kind=initial
instruction=Read the .sergeant-brief.md file and execute the mission.
EOF

  tmux new-window -d -t "$TMUX_SESSION:" -n "$label" \
    "env EXIT_AS='$exit_as' PUBLISH_COMPLETION='$publish' \
    HANDSHAKE_DONE_FILE='$TEST_ROOT/$label.handshake' \
    SGT_NOTIFICATION_RETRY_INTERVAL=0.02 SGT_HARNESS_SETTLE_SECONDS=0 \
    SGT_PROGRESS_INTERVAL=600 SGT_DRAIN_CHECK_INTERVAL=600 \
    '$ROOT_DIR/bin/sgt-interactive-worker' '$state' '$worktree' \
    '$TEST_ROOT/fake-bin/opencode'"

  pane="$(tmux display-message -p -t "$TMUX_SESSION:$label" '#{pane_id}')"
  identity="$(tmux display-message -p -t "$pane" \
    '#{pane_dead}|#{pane_id}|#{pane_pid}|#{pane_created}|#{pane_start_command}')"
  printf '%s\n' "$pane" > "$state/pane"
  printf '%s\n' "$identity" > "$state/pane_identity"
  nonce="$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  target_dir="$state/notifications/$notification_id/targets/$nonce"
  mkdir -p "$target_dir"
  printf '%s\n' "$identity" > "$target_dir/pane_identity"
  printf '%s\n' "$nonce" > "$state/notification_target"

  for _ in $(seq 1 3000); do
    [[ -e "$TEST_ROOT/$label.handshake" ]] && break
    sleep 0.02
  done
  [[ -e "$TEST_ROOT/$label.handshake" ]] || {
    printf '%s: handshake never completed\n' "$label" >&2
    exit 1
  }
  # Wait for the supervisor pane to be gone so _finish has run.  `display-message
  # -t <gone>` silently falls back to the default target, so the returned pane id
  # must be compared rather than the exit status trusted.
  for _ in $(seq 1 3000); do
    [[ "$(tmux display-message -p -t "$pane" '#{pane_id}' 2>/dev/null || true)" == "$pane" ]] \
      || break
    sleep 0.02
  done
  printf '%s %s %s %s\n' "$state" "$worktree" "$notification_id" "$nonce"
}

# ── 1. Every exit branch finalizes a provably completed turn ──────────────────

for branch in done failed needs_input blocked waiting orphaned; do
  read -r state worktree notification_id nonce <<<"$(run_branch "$branch" "$branch" 1)"
  notification_dir="$state/notifications/$notification_id"
  for _ in $(seq 1 1000); do
    [[ -e "$notification_dir/action_lease_finalized" ]] && break
    sleep 0.02
  done
  [[ -f "$notification_dir/action_lease_finalized" ]] || {
    printf '_finish branch %s exited without finalizing a completed lease\n' "$branch" >&2
    printf 'notification dir:\n%s\n' "$(find "$notification_dir" | sed 's/^/  /')" >&2
    exit 1
  }
  [[ "$(cat "$notification_dir/targets/$nonce/completed")" == "$notification_id|$nonce" ]] || {
    printf '_finish branch %s left completion unpublished\n' "$branch" >&2
    exit 1
  }
  # Delivery and action completion are recorded as distinct artefacts.
  [[ -f "$notification_dir/targets/$nonce/delivered" ]]
  [[ -f "$notification_dir/targets/$nonce/completed" ]]
done

# ── 2. Every exit branch records an explicit reason when it cannot finalize ────
# Nothing may exit leaving the lease silently pending, and nothing may fabricate
# completion the agent never proved.

for branch in done needs_input blocked waiting orphaned; do
  label="pending-$branch"
  read -r state worktree notification_id nonce <<<"$(run_branch "$label" "$branch" 0)"
  notification_dir="$state/notifications/$notification_id"
  for _ in $(seq 1 1000); do
    [[ -e "$notification_dir/action_lease_pending" ]] && break
    sleep 0.02
  done
  [[ -f "$notification_dir/action_lease_pending" ]] || {
    printf '_finish branch %s exited leaving the lease silently pending\n' "$branch" >&2
    printf 'notification dir:\n%s\n' "$(find "$notification_dir" | sed 's/^/  /')" >&2
    exit 1
  }
  [[ ! -e "$notification_dir/targets/$nonce/completed" ]] || {
    printf '_finish branch %s fabricated completion without agent proof\n' "$branch" >&2
    exit 1
  }
  [[ ! -e "$notification_dir/action_lease_finalized" ]] || {
    printf '_finish branch %s claimed finalization without completion\n' "$branch" >&2
    exit 1
  }
  grep -Fq "$nonce" "$notification_dir/action_lease_pending"
  grep -Fq 'reason=' "$notification_dir/action_lease_pending"
done

# ── 3. Terminal recycling invokes the finalizer ───────────────────────────────
# A worker that completed its turn but died before its own delivery loop could
# publish completion must still be settled when sgt-watch recycles it.

recycle_fleet="$TEST_ROOT/recycle-fleet"
recycle_state="$recycle_fleet/task/app"
recycle_worktree="$TEST_ROOT/recycle/worktree"
mkdir -p "$recycle_state/notifications/notify-recycle/targets" \
  "$recycle_worktree/.sergeant-notification-complete"
recycle_nonce="cccccccccccccccccccccccccccccccc"
recycle_target="$recycle_state/notifications/notify-recycle/targets/$recycle_nonce"
mkdir -p "$recycle_target"
printf '%s\n' "$recycle_worktree" > "$recycle_state/worktree"
printf 'notify-recycle\n' > "$recycle_state/notification_id"
printf '%s\n' "$recycle_nonce" > "$recycle_state/notification_target"
printf '%s\n' "$recycle_nonce" > "$recycle_state/notifications/notify-recycle/action_lease"
printf 'notify-recycle|%s\n' "$recycle_nonce" > "$recycle_target/accepted"
printf 'notify-recycle|%s\n' "$recycle_nonce" > "$recycle_target/delivered"
printf 'notify-recycle|%s\n' "$recycle_nonce" > \
  "$recycle_worktree/.sergeant-notification-complete/$recycle_nonce"
printf 'done\n' > "$recycle_worktree/.sergeant-status"
printf 'https://example.invalid/pr/9\n' > "$recycle_worktree/.sergeant-result"
printf 'done\n' > "$recycle_state/status"
# No pane recorded: recycling has nothing to kill, but must still finalize.
printf 'Brief: recycle\n' > "$recycle_fleet/task/brief.md"

SERGEANT_FLEET="$recycle_fleet" "$ROOT_DIR/bin/sgt-watch" --sync task >/dev/null

[[ "$(cat "$recycle_target/completed")" == "notify-recycle|$recycle_nonce" ]] || {
  printf 'terminal recycling did not finalize the accepted lease\n' >&2
  exit 1
}
[[ -s "$recycle_state/notifications/notify-recycle/action_lease_finalized" ]]
grep -Fq 'terminal_recycle' \
  "$recycle_state/notifications/notify-recycle/action_lease_finalized"
[[ ! -e "$recycle_state/response.lock" && ! -L "$recycle_state/response.lock" ]]

# Recycling must not fabricate completion when the agent never proved it.
unproven_state="$recycle_fleet/task/unproven"
unproven_worktree="$TEST_ROOT/unproven/worktree"
unproven_nonce="dddddddddddddddddddddddddddddddd"
unproven_target="$unproven_state/notifications/notify-unproven/targets/$unproven_nonce"
mkdir -p "$unproven_target" "$unproven_worktree"
printf '%s\n' "$unproven_worktree" > "$unproven_state/worktree"
printf 'notify-unproven\n' > "$unproven_state/notification_id"
printf '%s\n' "$unproven_nonce" > "$unproven_state/notification_target"
printf '%s\n' "$unproven_nonce" > \
  "$unproven_state/notifications/notify-unproven/action_lease"
printf 'notify-unproven|%s\n' "$unproven_nonce" > "$unproven_target/accepted"
printf 'notify-unproven|%s\n' "$unproven_nonce" > "$unproven_target/delivered"
printf 'done\n' > "$unproven_worktree/.sergeant-status"
printf 'https://example.invalid/pr/10\n' > "$unproven_worktree/.sergeant-result"
printf 'done\n' > "$unproven_state/status"

SERGEANT_FLEET="$recycle_fleet" "$ROOT_DIR/bin/sgt-watch" --sync task >/dev/null

[[ ! -e "$unproven_target/completed" ]] || {
  printf 'terminal recycling fabricated completion without agent proof\n' >&2
  exit 1
}
[[ -s "$unproven_state/notifications/notify-unproven/action_lease_pending" ]] || {
  printf 'terminal recycling left an unprovable lease with no recorded reason\n' >&2
  exit 1
}

printf 'action-lease settlement at every exit boundary: ok\n'
