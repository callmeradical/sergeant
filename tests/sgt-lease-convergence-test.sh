#!/usr/bin/env bash
# Regression: sgt-respond and sgt-recover converge an exact-matching completed
# turn BEFORE refusing the lease as prior-supervisor-owned (td-53541c / GH #168).
#
# A supervisor that accepted a notification and died between the agent publishing
# .sergeant-notification-complete/<nonce> and the supervisor recording
# targets/<nonce>/completed left the lease outstanding forever. sgt-respond died
# with "Pending notification action lease belongs to the prior supervisor" and
# sgt-recover escalated then died. Neither tried to converge, so the worker was
# permanently unrecoverable.
#
# Convergence must be idempotent, must never fabricate a completion the agent did
# not prove, and must still fail closed on an identity or nonce mismatch and on a
# turn that produced no proof at all.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fleet="$TEST_ROOT/fleet"
source_repo="$TEST_ROOT/source"
fake_bin="$TEST_ROOT/fake-bin"
config_dir="$TEST_ROOT/config"
export SERGEANT_CONFIG="$config_dir"

mkdir -p "$fleet" "$source_repo" "$fake_bin" "$config_dir"
git -C "$source_repo" init -q
git -C "$source_repo" config user.name Test
git -C "$source_repo" config user.email test@example.invalid
touch "$source_repo/README.md"
git -C "$source_repo" add README.md
git -C "$source_repo" commit -qm fixture

cat > "$config_dir/test.yaml" <<EOF
repos:
  - name: app
    path: $source_repo
EOF

cat > "$fake_bin/tmux" <<'TMUX'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TMUX_LOG:-/dev/null}"
case "$1" in
  display-message)
    target=""
    previous=""
    for arg in "$@"; do
      [[ "$previous" == -t ]] && target="$arg"
      previous="$arg"
    done
    # PANE_ALIVE=0 models a dead PRIOR supervisor; a relaunched pane is alive.
    if [[ "$target" != "${NEW_PANE:-%99}" ]]; then
      [[ "${PANE_ALIVE:-1}" == 1 ]] || exit 1
    fi
    pane_identity="${PANE_IDENTITY:-0|%42|4242|123456|stalled-pane}"
    if [[ "$target" == "${NEW_PANE:-%99}" ]]; then
      pane_identity="0|$target|9999|654321|relaunched"
    fi
    # Stand in for a relaunched worker completing its delivery handshake.
    if [[ "${AUTO_DELIVER:-1}" == 1 && "$target" == "${NEW_PANE:-%99}" &&
          -s "$REPO_STATE_DIR/notification_id" ]]; then
      notification_id="$(cat "$REPO_STATE_DIR/notification_id")"
      wt="$(cat "$REPO_STATE_DIR/worktree")"
      nonce="$(cat "$REPO_STATE_DIR/notification_target" 2>/dev/null || true)"
      if [[ "$nonce" =~ ^[a-f0-9]{32}$ ]]; then
        token="$notification_id|$nonce"
        target_dir="$REPO_STATE_DIR/notifications/$notification_id/targets/$nonce"
        mkdir -p "$wt/.sergeant-notification-acks" "$wt/.sergeant-notification-accepts" \
          "$target_dir"
        printf '%s\n' "$token" > "$wt/.sergeant-notification-acks/$nonce"
        printf '%s\n' "$token" > "$wt/.sergeant-notification-accepts/$nonce"
        printf '%s\n' "$token" > "$target_dir/accepted"
        printf '%s\n' "$token" > "$target_dir/delivered"
        printf '%s\n' "$pane_identity" \
          > "$REPO_STATE_DIR/notification_delivered_pane_identity"
        printf '%s\n' "$notification_id" > "$REPO_STATE_DIR/notification_delivered"
      fi
    fi
    printf '%s\n' "$pane_identity"
    ;;
  new-window)
    [[ "${FAIL_WINDOW:-0}" == 0 ]] || exit 7
    printf '%s\n' "${NEW_PANE:-%99}"
    ;;
  kill-pane)
    target_pane=""
    previous=""
    for arg in "$@"; do
      [[ "$previous" == -t ]] && target_pane="$arg"
      previous="$arg"
    done
    [[ -z "${KILL_LOG:-}" ]] || printf 'kill-pane -t %s\n' "$target_pane" >> "$KILL_LOG"
    ;;
  send-keys) ;;
  has-session) ;;
esac
TMUX
chmod +x "$fake_bin/tmux"

cat > "$fake_bin/td" <<'TD'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then printf 'td version v0.1.0\n'; exit 0; fi
if [[ "${1:-}" == "create" && "${2:-}" == "--help" ]]; then
  printf '%s\n' '--description --json --work-dir'; exit 0
fi
exit 0
TD
chmod +x "$fake_bin/td"

NONCE="aabbccddeeff00112233445566778899"
NOTIFY="deadbeef00112233445566778899aabb"

# make_worktree <name> — one fleet task named "task-<name>" owning repo "app",
# backed by a real git worktree.  Prints "<repo_state> <worktree>".
make_worktree() {
  local name="$1"
  local task_dir="$fleet/task-$name"
  local repo_state="$task_dir/app" wt="$TEST_ROOT/wt-$name"
  local pointer git_dir revision
  git -C "$source_repo" worktree add -q -b "converge-$name" "$wt"
  mkdir -p "$repo_state"
  printf 'Project: test\nBrief: convergence test\nBranch: converge-%s\nRepos: app\n' \
    "$name" > "$task_dir/brief.md"
  printf '%s\n' "$wt" > "$repo_state/worktree"
  pointer="$(cat "$wt/.git")"
  printf '%s\n' "$pointer" > "$repo_state/worktree_git_pointer"
  git_dir="${pointer#gitdir: }"
  [[ "$git_dir" == /* ]] || git_dir="$wt/$git_dir"
  git_dir="$(cd "$git_dir" && pwd -P)"
  printf '%s\n' "$git_dir" > "$repo_state/worktree_git_dir"
  cat > "$task_dir/.sergeant-intent.md" <<'INTENT'
## Objective

Exercise action-lease convergence.
INTENT
  revision="$(bash -c 'source "$1"; _sgt_intent_revision "$2"' _ \
    "$ROOT_DIR/bin/_sgt-intent.sh" "$task_dir/.sergeant-intent.md")"
  printf '%s\n' "$revision" > "$task_dir/intent_revision"
  cp "$task_dir/.sergeant-intent.md" "$repo_state/.sergeant-intent.md"
  cp "$task_dir/.sergeant-intent.md" "$wt/.sergeant-intent.md"
  printf '%s\n' "$revision" > "$repo_state/intent_revision"
  printf '1\n' > "$wt/.sergeant-gate-generation"
  printf 'sgt\n' > "$repo_state/tmux_session"
  printf 'task/app\n' > "$repo_state/window_name"
  printf 'opencode\n' > "$repo_state/agent"
  printf '%%42\n' > "$repo_state/pane"
  printf '0|%%42|4242|123456|stalled-pane\n' > "$repo_state/pane_identity"
  chmod 600 "$repo_state/pane_identity"
  printf '%s %s\n' "$repo_state" "$wt"
}

# install_accepted_turn <repo_state> <worktree> [<proof-token>]
# An accepted turn whose lease was never settled.  With a proof token, the agent
# published completion but the supervisor died before recording it.
install_accepted_turn() {
  local repo_state="$1" wt="$2" proof="${3:-}"
  local target_dir="$repo_state/notifications/$NOTIFY/targets/$NONCE"
  mkdir -p "$target_dir" "$wt/.sergeant-notification-complete"
  printf '%s\n' "$NOTIFY" > "$repo_state/notification_id"
  printf '%s\n' "$NONCE" > "$repo_state/notification_target"
  printf '%s\n' "$NONCE" > "$repo_state/notifications/$NOTIFY/action_lease"
  printf '0|%%42|4242|123456|stalled-pane\n' > "$target_dir/pane_identity"
  printf '%s|%s\n' "$NOTIFY" "$NONCE" > "$target_dir/acknowledged"
  printf '%s|%s\n' "$NOTIFY" "$NONCE" > "$target_dir/accepted"
  printf '%s|%s\n' "$NOTIFY" "$NONCE" > "$target_dir/delivered"
  rm -f "$target_dir/completed"
  if [[ -n "$proof" ]]; then
    printf '%s\n' "$proof" > "$wt/.sergeant-notification-complete/$NONCE"
  fi
}

setup_stall() {
  local repo_state="$1" wt="$2"
  printf 'in_progress\n' > "$repo_state/status"
  printf 'in_progress\n' > "$wt/.sergeant-status"
  printf 'live worker stalled: no progress for 401s (grace=300s); last event at epoch 1000\n' \
    > "$repo_state/diagnostic"
  rm -f "$repo_state/stall_recovery_attempted"
}

setup_orphan() {
  local repo_state="$1" wt="$2"
  printf 'orphaned\n' > "$repo_state/status"
  printf 'orphaned\n' > "$wt/.sergeant-status"
}

# ── 1. sgt-recover converges a provably completed turn ────────────────────────

read -r state wt <<<"$(make_worktree recover-converge)"
task=task-recover-converge
setup_stall "$state" "$wt"
install_accepted_turn "$state" "$wt" "$NOTIFY|$NONCE"

PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 REPO_STATE_DIR="$state" TMUX_LOG="$TEST_ROOT/rc.log" \
  KILL_LOG="$TEST_ROOT/rc-kill.log" \
  "$ROOT_DIR/bin/sgt-recover" "$task" app >/dev/null 2>&1 || {
  printf 'sgt-recover refused a provably completed turn instead of converging\n' >&2
  exit 1
}
[[ "$(cat "$state/notifications/$NOTIFY/targets/$NONCE/completed")" == "$NOTIFY|$NONCE" ]] || {
  printf 'sgt-recover did not converge the completed turn\n' >&2
  exit 1
}
grep -Fq 'recover_convergence' "$state/notifications/$NOTIFY/action_lease_finalized" || {
  printf 'convergence was not recorded by sgt-recover:\n%s\n' \
    "$(cat "$state/notifications/$NOTIFY/action_lease_finalized" 2>/dev/null || true)" >&2
  exit 1
}
# Recovery proceeded: the replacement pane is installed and the old one killed.
[[ "$(cat "$state/pane")" == "%99" ]]
grep -Fq 'kill-pane -t %42' "$TEST_ROOT/rc-kill.log"

# ── 2. sgt-recover still refuses a turn with no agent proof ───────────────────

read -r state wt <<<"$(make_worktree recover-refuse)"
task=task-recover-refuse
setup_stall "$state" "$wt"
install_accepted_turn "$state" "$wt"

set +e
refuse_output="$(PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 REPO_STATE_DIR="$state" \
  TMUX_LOG="$TEST_ROOT/rr.log" KILL_LOG="$TEST_ROOT/rr-kill.log" \
  "$ROOT_DIR/bin/sgt-recover" "$task" app 2>&1)"
refuse_status=$?
set -e
[[ "$refuse_status" -ne 0 ]] || {
  printf 'sgt-recover accepted a turn with no completion proof\n' >&2
  exit 1
}
[[ ! -e "$state/notifications/$NOTIFY/targets/$NONCE/completed" ]] || {
  printf 'sgt-recover fabricated completion without agent proof\n' >&2
  exit 1
}
# The refusal names the lease owner and a supported resolution command.
[[ "$refuse_output" == *"$NOTIFY"* && "$refuse_output" == *"$NONCE"* ]] || {
  printf 'refusal did not name the notification and lease target:\n%s\n' "$refuse_output" >&2
  exit 1
}
[[ "$refuse_output" == *"sgt-respond $task app"* ]] || {
  printf 'refusal did not name a supported resolution command:\n%s\n' "$refuse_output" >&2
  exit 1
}
[[ -z "$(cat "$TEST_ROOT/rr-kill.log" 2>/dev/null || true)" ]] || {
  printf 'sgt-recover killed a pane while refusing\n' >&2
  exit 1
}

# ── 3. An identity or nonce mismatch fails closed ────────────────────────────

read -r state wt <<<"$(make_worktree recover-mismatch)"
task=task-recover-mismatch
setup_stall "$state" "$wt"
install_accepted_turn "$state" "$wt" "some-other-notification|$NONCE"
set +e
PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 REPO_STATE_DIR="$state" TMUX_LOG="$TEST_ROOT/rm.log" \
  "$ROOT_DIR/bin/sgt-recover" "$task" app >/dev/null 2>&1
mismatch_status=$?
set -e
[[ "$mismatch_status" -ne 0 ]] || {
  printf 'a mismatched notification id was converged\n' >&2
  exit 1
}
[[ ! -e "$state/notifications/$NOTIFY/targets/$NONCE/completed" ]]
grep -Fq 'mismatch' "$state/notifications/$NOTIFY/action_lease_pending"

read -r state wt <<<"$(make_worktree recover-badnonce)"
task=task-recover-badnonce
setup_stall "$state" "$wt"
install_accepted_turn "$state" "$wt" "$NOTIFY|ffffffffffffffffffffffffffffffff"
set +e
PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 REPO_STATE_DIR="$state" TMUX_LOG="$TEST_ROOT/rb.log" \
  "$ROOT_DIR/bin/sgt-recover" "$task" app >/dev/null 2>&1
badnonce_status=$?
set -e
[[ "$badnonce_status" -ne 0 ]] || {
  printf 'a mismatched nonce was converged\n' >&2
  exit 1
}
[[ ! -e "$state/notifications/$NOTIFY/targets/$NONCE/completed" ]]

# ── 4. sgt-respond converges a provably completed turn before relaunching ─────

read -r state wt <<<"$(make_worktree respond-converge)"
task=task-respond-converge
setup_orphan "$state" "$wt"
install_accepted_turn "$state" "$wt" "$NOTIFY|$NONCE"

printf 'resume the mission' | PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 REPO_STATE_DIR="$state" \
  TMUX_LOG="$TEST_ROOT/sc.log" PANE_ALIVE=0 \
  "$ROOT_DIR/bin/sgt-respond" "$task" app >/dev/null 2>&1 || {
  printf 'sgt-respond refused a provably completed turn instead of converging\n' >&2
  exit 1
}
[[ "$(cat "$state/notifications/$NOTIFY/targets/$NONCE/completed")" == "$NOTIFY|$NONCE" ]] || {
  printf 'sgt-respond did not converge the completed turn\n' >&2
  exit 1
}
grep -Fq 'respond_relaunch_convergence' \
  "$state/notifications/$NOTIFY/action_lease_finalized"
[[ "$(cat "$state/pane")" == "%99" ]] || {
  printf 'sgt-respond did not relaunch after converging\n' >&2
  exit 1
}

# ── 5. Convergence is idempotent ─────────────────────────────────────────────
# Running the supported command again must reach the same state, not a second
# completion record or a different token.

completed_before="$(cat "$state/notifications/$NOTIFY/targets/$NONCE/completed")"
record_before="$(cat "$state/notifications/$NOTIFY/action_lease_finalized")"
setup_orphan "$state" "$wt"
rm -f "$wt/.sergeant-response" "$state/response"
printf 'resume the mission again' | PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 REPO_STATE_DIR="$state" \
  TMUX_LOG="$TEST_ROOT/sc2.log" PANE_ALIVE=0 \
  "$ROOT_DIR/bin/sgt-respond" "$task" app >/dev/null 2>&1 || true
[[ "$(cat "$state/notifications/$NOTIFY/targets/$NONCE/completed")" == "$completed_before" ]] || {
  printf 'a second convergence rewrote the completion token\n' >&2
  exit 1
}
[[ "$(cat "$state/notifications/$NOTIFY/action_lease_finalized")" == "$record_before" ]] || {
  printf 'a second convergence rewrote the finalization record\n' >&2
  exit 1
}

# ── 6. sgt-respond still refuses a turn with no agent proof ──────────────────

read -r state wt <<<"$(make_worktree respond-refuse)"
task=task-respond-refuse
setup_orphan "$state" "$wt"
install_accepted_turn "$state" "$wt"
set +e
respond_refuse="$(printf 'resume' | PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 REPO_STATE_DIR="$state" \
  TMUX_LOG="$TEST_ROOT/sr.log" PANE_ALIVE=0 \
  "$ROOT_DIR/bin/sgt-respond" "$task" app 2>&1)"
respond_refuse_status=$?
set -e
[[ "$respond_refuse_status" -ne 0 ]] || {
  printf 'sgt-respond relaunched over an unprovable lease\n' >&2
  exit 1
}
[[ "$respond_refuse" == *'belongs to the prior supervisor'* ]]
[[ "$respond_refuse" == *"$NOTIFY"* && "$respond_refuse" == *"$NONCE"* ]] || {
  printf 'sgt-respond refusal did not name the lease owner:\n%s\n' "$respond_refuse" >&2
  exit 1
}
[[ "$respond_refuse" == *"sgt-respond $task app"* ]]
[[ ! -e "$state/notifications/$NOTIFY/targets/$NONCE/completed" ]]

# ── 7. A live owning supervisor is never relaunched over ──────────────────────
# When the recorded pane is still the live worker supervisor, sgt-respond
# delivers to it instead of taking the relaunch-and-refuse path at all, so the
# lease is never contested by a second supervisor.

read -r state wt <<<"$(make_worktree respond-live)"
task=task-respond-live
setup_orphan "$state" "$wt"
install_accepted_turn "$state" "$wt"
set +e
printf 'resume' | PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 REPO_STATE_DIR="$state" \
  TMUX_LOG="$TEST_ROOT/sl.log" PANE_ALIVE=1 SGT_NOTIFICATION_ACK_TIMEOUT=1 \
  "$ROOT_DIR/bin/sgt-respond" "$task" app >/dev/null 2>&1
set -e
if [[ -e "$TEST_ROOT/sl.log" ]] && grep -q '^new-window ' "$TEST_ROOT/sl.log"; then
  printf 'sgt-respond relaunched a second supervisor over a live owner\n' >&2
  exit 1
fi
[[ "$(cat "$state/pane")" == "%42" ]] || {
  printf 'sgt-respond replaced the pane of a live owner\n' >&2
  exit 1
}

printf 'action-lease convergence before refusal: ok\n'
