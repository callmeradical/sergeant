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
  list-panes)
    [[ -n "${TMUX_PANE_STATE:-}" && -s "$TMUX_PANE_STATE" ]] || exit 0
    cat "$TMUX_PANE_STATE"
    ;;
  display-message)
    target=""
    previous=""
    for arg in "$@"; do
      [[ "$previous" == -t ]] && target="$arg"
      previous="$arg"
    done
    if [[ "$target" == "${FOREIGN_PANE:-%77}" && -n "${FOREIGN_PANE_IDENTITY:-}" ]]; then
      printf '%s\n' "$FOREIGN_PANE_IDENTITY"
      exit 0
    fi
    if [[ "$*" == *'@sergeant_replacement_token'* && "$target" == "${NEW_PANE:-%99}" ]]; then
      spawn_token="$(cat "${SPAWN_TOKEN_STATE:-$REPO_STATE_DIR/test_spawn_token}" 2>/dev/null || true)"
      spawn_role="$(cat "${SPAWN_ROLE_STATE:-$REPO_STATE_DIR/test_spawn_role}" 2>/dev/null || true)"
      printf '0|%s|9999|bash|%s|%s\n' "$target" "$spawn_token" "$spawn_role"
      exit 0
    fi
    # PANE_ALIVE=0 models a dead PRIOR supervisor; a relaunched pane is alive.
    if [[ "$target" != "${NEW_PANE:-%99}" ]]; then
      [[ "${PANE_ALIVE:-1}" == 1 ]] || exit 1
    fi
    pane_identity="${PANE_IDENTITY:-0|%42|4242|123456|stalled-pane}"
    if [[ "$target" == "${NEW_PANE:-%99}" ]]; then
      start_command="$(cat "${SPAWN_COMMAND_STATE:-$REPO_STATE_DIR/test_spawn_command}" 2>/dev/null || true)"
      pane_identity="0|$target|9999|654321|$start_command"
    fi
    # Stand in for a relaunched worker completing its delivery handshake.
    if [[ "${AUTO_DELIVER:-1}" == 1 &&
          ( -z "${ACK_GATE_FILE:-}" || -e "$ACK_GATE_FILE" ) &&
          "$target" == "${NEW_PANE:-%99}" &&
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
    window=""
    previous=""
    start_command=""
    for arg in "$@"; do
      [[ "$previous" == -n ]] && window="$arg"
      previous="$arg"
      start_command="$arg"
    done
    spawn_token="$(printf '%s\n' "$*" | sed -n 's/.*sgt-replacement-launch \([a-f0-9]\{32\}\) .*/\1/p')"
    spawn_role="$(printf '%s\n' "$*" | sed -n 's/.*sgt-replacement-launch [a-f0-9]\{32\} \(worker:[A-Za-z0-9._-]*\) .*/\1/p')"
    printf '%s\n' "$spawn_token" \
      > "${SPAWN_TOKEN_STATE:-$REPO_STATE_DIR/test_spawn_token}"
    printf '%s\n' "$spawn_role" \
      > "${SPAWN_ROLE_STATE:-$REPO_STATE_DIR/test_spawn_role}"
    printf '%s\n' "$start_command" \
      > "${SPAWN_COMMAND_STATE:-$REPO_STATE_DIR/test_spawn_command}"
    if [[ -n "${TMUX_PANE_STATE:-}" ]]; then
      printf '%s|%s\n' "${NEW_PANE:-%99}" "$window" > "$TMUX_PANE_STATE"
    fi
    if [[ -n "${NEW_WINDOW_COUNT:-}" ]]; then
      count="$(cat "$NEW_WINDOW_COUNT" 2>/dev/null || printf 0)"
      printf '%s\n' "$((count + 1))" > "$NEW_WINDOW_COUNT"
    fi
    if [[ "${KILL_RESPOND_AFTER_SPAWN:-0}" == 1 ]]; then
      kill -KILL "$PPID"
      sleep 1
    fi
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

read -r state wt <<<"$(make_worktree recover-dead-owner)"
task=task-recover-dead-owner
setup_stall "$state" "$wt"
install_accepted_turn "$state" "$wt"
PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 \
  REPO_STATE_DIR="$state" PANE_ALIVE=0 \
  "$ROOT_DIR/bin/sgt-recover" "$task" app >/dev/null 2>&1 || {
  printf 'sgt-recover did not fence an exactly proven dead owner\n' >&2
  exit 1
}
[[ ! -e "$state/notifications/$NOTIFY/targets/$NONCE/completed" ]]
grep -Fq "old_lease=$NONCE" \
  "$state/notifications/$NOTIFY/ownership_transition"
grep -Fq "new_notification=$(cat "$state/notification_id")" \
  "$state/notifications/$NOTIFY/ownership_transition"
[[ "$(cat "$state/pane")" == '%99' ]]

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

# 6. sgt-respond fences an exactly proven dead owner without inventing proof.

read -r state wt <<<"$(make_worktree respond-dead-owner)"
task=task-respond-dead-owner
setup_orphan "$state" "$wt"
install_accepted_turn "$state" "$wt"
printf 'preserved but uncommitted\n' > "$wt/preserved.txt"
set +e
orphan_recover_output="$(PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-recover" "$task" app 2>&1)"
orphan_recover_status=$?
set -e
[[ "$orphan_recover_status" -ne 0 &&
   "$orphan_recover_output" == *"sgt-respond $task app"* ]] || {
  printf 'sgt-recover did not direct orphan recovery to its supported CLI path\n' >&2
  exit 1
}
printf 'resume' | PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 REPO_STATE_DIR="$state" \
  TMUX_LOG="$TEST_ROOT/sr.log" PANE_ALIVE=0 \
  "$ROOT_DIR/bin/sgt-respond" "$task" app >/dev/null 2>&1 || {
  printf 'sgt-respond did not fence a provably dead prior owner\n' >&2
  exit 1
}
[[ "$(cat "$wt/preserved.txt")" == 'preserved but uncommitted' ]]
[[ ! -e "$state/notifications/$NOTIFY/targets/$NONCE/completed" ]] || {
  printf 'sgt-respond fabricated completion while fencing a dead owner\n' >&2
  exit 1
}
grep -Fq "lease=$NONCE" "$state/notifications/$NOTIFY/action_lease_abandoned"
grep -Fq 'old_owner_identity=0|%42|4242|123456|stalled-pane' \
  "$state/notifications/$NOTIFY/ownership_transition"
grep -Fq 'new_notification=' "$state/notifications/$NOTIFY/ownership_transition"
[[ "$(cat "$state/pane")" == '%99' ]]

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

# Missing relaunch metadata is not a lease-adjudication bypass. A dead old
# generation is fenced before the durable fallback is published; a live owner
# refuses without replacing the old notification.
read -r state wt <<<"$(make_worktree respond-incomplete-metadata-dead)"
task=task-respond-incomplete-metadata-dead
setup_orphan "$state" "$wt"
install_accepted_turn "$state" "$wt"
rm -f "$state/agent"
printf 'resume via durable fallback' | PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  SGT_WIKI_DISABLED=1 REPO_STATE_DIR="$state" PANE_ALIVE=0 \
  "$ROOT_DIR/bin/sgt-respond" "$task" app >/dev/null 2>&1
[[ -s "$state/notifications/$NOTIFY/action_lease_abandoned" ]]
[[ -s "$state/notifications/$NOTIFY/ownership_transition" ]]
[[ "$(cat "$state/notification_id")" != "$NOTIFY" ]]
[[ ! -e "$state/notifications/$NOTIFY/targets/$NONCE/completed" ]]

read -r state wt <<<"$(make_worktree respond-incomplete-metadata-live)"
task=task-respond-incomplete-metadata-live
setup_orphan "$state" "$wt"
install_accepted_turn "$state" "$wt"
rm -f "$state/agent"
if printf 'must fail closed' | PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
    SGT_WIKI_DISABLED=1 REPO_STATE_DIR="$state" PANE_ALIVE=1 \
    "$ROOT_DIR/bin/sgt-respond" "$task" app >/dev/null 2>&1; then
  printf 'incomplete metadata bypassed a live action lease owner\n' >&2
  exit 1
fi
[[ "$(cat "$state/notification_id")" == "$NOTIFY" ]]
[[ ! -e "$state/notifications/$NOTIFY/action_lease_abandoned" ]]
[[ ! -e "$state/notifications/$NOTIFY/ownership_transition" ]]

for collision_record in action_lease_abandoned ownership_transition; do
  read -r state wt <<<"$(make_worktree collision-$collision_record)"
  task="task-collision-$collision_record"
  setup_orphan "$state" "$wt"
  install_accepted_turn "$state" "$wt"
  printf 'foreign collision evidence\n' \
    > "$state/notifications/$NOTIFY/$collision_record"
  if printf 'must preserve collision' | PATH="$fake_bin:$PATH" \
      SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 REPO_STATE_DIR="$state" \
      PANE_ALIVE=0 "$ROOT_DIR/bin/sgt-respond" "$task" app >/dev/null 2>&1; then
    printf 'conflicting %s was accepted\n' "$collision_record" >&2
    exit 1
  fi
  [[ "$(cat "$state/notifications/$NOTIFY/$collision_record")" == \
     'foreign collision evidence' ]]
  [[ "$(cat "$state/notification_id")" == "$NOTIFY" ]]
done

# ── 8. Stale, reused, and process-ambiguous ownership fails closed ───────

read -r state wt <<<"$(make_worktree respond-stale-owner)"
task=task-respond-stale-owner
setup_orphan "$state" "$wt"
install_accepted_turn "$state" "$wt"
printf '0|%%43|4343|123457|different-owner\n' \
  > "$state/notifications/$NOTIFY/targets/$NONCE/pane_identity"
printf 'stale-generation|%s\n' "$NONCE" \
  > "$state/notifications/$NOTIFY/targets/$NONCE/accepted"
if printf 'resume' | PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 \
    REPO_STATE_DIR="$state" PANE_ALIVE=0 "$ROOT_DIR/bin/sgt-respond" "$task" app \
    >/dev/null 2>&1; then
  printf 'stale target ownership was fenced\n' >&2
  exit 1
fi
[[ ! -e "$state/notifications/$NOTIFY/action_lease_abandoned" ]]

read -r state wt <<<"$(make_worktree respond-reused-pane)"
task=task-respond-reused-pane
setup_orphan "$state" "$wt"
install_accepted_turn "$state" "$wt"
if printf 'resume' | PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 \
    REPO_STATE_DIR="$state" PANE_ALIVE=1 \
    PANE_IDENTITY='0|%42|7777|777777|reused-pane' \
    "$ROOT_DIR/bin/sgt-respond" "$task" app >/dev/null 2>&1; then
  printf 'reused pane identity was fenced\n' >&2
  exit 1
fi
[[ ! -e "$state/notifications/$NOTIFY/action_lease_abandoned" ]]

read -r state wt <<<"$(make_worktree respond-live-pid)"
task=task-respond-live-pid
setup_orphan "$state" "$wt"
install_accepted_turn "$state" "$wt"
live_pid_identity="0|%42|$$|123456|stale-pane-live-pid"
printf '%s\n' "$live_pid_identity" > "$state/pane_identity"
chmod 600 "$state/pane_identity"
printf '%s\n' "$live_pid_identity" \
  > "$state/notifications/$NOTIFY/targets/$NONCE/pane_identity"
if printf 'resume' | PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 \
    REPO_STATE_DIR="$state" PANE_ALIVE=0 "$ROOT_DIR/bin/sgt-respond" "$task" app \
    >/dev/null 2>&1; then
  printf 'live/reused process identity was fenced\n' >&2
  exit 1
fi
[[ ! -e "$state/notifications/$NOTIFY/action_lease_abandoned" ]]

# ── 9. Every durable transfer boundary converges on exact retry ──────────

for boundary in lease_archived successor_published replacement_spawned replacement_owned; do
  read -r state wt <<<"$(make_worktree interrupt-$boundary)"
  task="task-interrupt-$boundary"
  setup_orphan "$state" "$wt"
  install_accepted_turn "$state" "$wt"
  printf 'retry me exactly once' > "$TEST_ROOT/input-$boundary"
  set +e
  PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 \
    REPO_STATE_DIR="$state" PANE_ALIVE=0 NEW_PANE=%98 \
    KILL_LOG="$TEST_ROOT/interrupt-$boundary-kill.log" \
    SGT_TEST_HOOKS=1 SGT_TEST_INTERRUPT_TRANSFER_AT="$boundary" \
    "$ROOT_DIR/bin/sgt-respond" "$task" app \
    < "$TEST_ROOT/input-$boundary" >/dev/null 2>&1
  interrupted_status=$?
  set -e
  [[ "$interrupted_status" -ne 0 ]] || {
    printf 'boundary %s did not interrupt\n' "$boundary" >&2
    exit 1
  }
  PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 \
    REPO_STATE_DIR="$state" PANE_ALIVE=0 NEW_PANE=%99 \
    KILL_LOG="$TEST_ROOT/interrupt-$boundary-kill.log" \
    "$ROOT_DIR/bin/sgt-respond" "$task" app \
    < "$TEST_ROOT/input-$boundary" >/dev/null 2>&1 || {
    printf 'boundary %s did not converge on retry\n' "$boundary" >&2
    exit 1
  }
  successor="$(sed -n 's/^new_notification=//p' \
    "$state/notifications/$NOTIFY/ownership_transition")"
  [[ -n "$successor" && "$(cat "$state/notification_id")" == "$successor" ]]
  [[ "$(cat "$state/response")" == 'retry me exactly once' ]]
  [[ "$(cat "$state/pane")" == '%99' ]]
  [[ ! -e "$state/notifications/$NOTIFY/targets/$NONCE/completed" ]]
  if [[ "$boundary" == replacement_spawned || "$boundary" == replacement_owned ]]; then
    grep -Fq 'kill-pane -t %98' "$TEST_ROOT/interrupt-$boundary-kill.log"
  fi
done

worktree_content_hash() {
  find "$1" -type f ! -path '*/.git/*' ! -path '*/.sergeant-*/*' \
    ! -name '.git' ! -name '.sergeant-*' \
    -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}'
}

# Every atomic write/rename in the ownership-transfer journal is retryable. A
# failed publication leaves no partial final path and the exact same response
# resumes without changing user worktree content.
for io_target in response_successor_notification action_lease_abandoned \
    ownership_transition response_relaunch_transaction; do
  for io_stage in write rename; do
    read -r state wt <<<"$(make_worktree io-$io_target-$io_stage)"
    task="task-io-$io_target-$io_stage"
    setup_orphan "$state" "$wt"
    install_accepted_turn "$state" "$wt"
    printf 'uncommitted %s %s\n' "$io_target" "$io_stage" > "$wt/io-user.txt"
    io_before="$(worktree_content_hash "$wt")"
    printf 'same response across io retry' > "$TEST_ROOT/io-input"
    set +e
    PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 \
      REPO_STATE_DIR="$state" PANE_ALIVE=0 \
      SGT_TEST_HOOKS=1 SGT_TEST_FAIL_TRANSFER_IO_TARGET="$io_target" \
      SGT_TEST_FAIL_TRANSFER_IO_STAGE="$io_stage" \
      "$ROOT_DIR/bin/sgt-respond" "$task" app \
      < "$TEST_ROOT/io-input" >/dev/null 2>&1
    io_status=$?
    set -e
    [[ "$io_status" -ne 0 ]] || {
      printf 'I/O failpoint %s/%s did not fail\n' "$io_target" "$io_stage" >&2
      exit 1
    }
    [[ -z "$(find "$state" -name "${io_target}.tmp.*" -print -quit)" ]]
    PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 \
      REPO_STATE_DIR="$state" PANE_ALIVE=0 \
      "$ROOT_DIR/bin/sgt-respond" "$task" app \
      < "$TEST_ROOT/io-input" >/dev/null 2>&1 || {
      printf 'I/O failpoint %s/%s did not converge on retry\n' \
        "$io_target" "$io_stage" >&2
      exit 1
    }
    [[ "$(cat "$state/response")" == 'same response across io retry' ]]
    [[ "$(cat "$wt/io-user.txt")" == "uncommitted $io_target $io_stage" ]]
    [[ "$(worktree_content_hash "$wt")" == "$io_before" ]]
  done
done

# A same-name pane is never sufficient for adoption. Only the spawn token bound
# before fencing authenticates the replacement; a foreign collision is left
# untouched and no second pane is created.
read -r state wt <<<"$(make_worktree foreign-window)"
task=task-foreign-window
setup_orphan "$state" "$wt"
printf 'foreign collision retry' > "$TEST_ROOT/foreign-input"
set +e
PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 \
  REPO_STATE_DIR="$state" PANE_ALIVE=0 SGT_TEST_HOOKS=1 \
  SGT_TEST_INTERRUPT_TRANSFER_AT=successor_published \
  "$ROOT_DIR/bin/sgt-respond" "$task" app \
  < "$TEST_ROOT/foreign-input" >/dev/null 2>&1
set -e
successor="$(cut -d '|' -f2 "$state/response_successor_notification")"
foreign_token="$(cut -d '|' -f3 "$state/response_successor_notification")"
foreign_window="task/app-resume-${successor:0:12}"
printf '%%77|%s\n' "$foreign_window" > "$TEST_ROOT/foreign-pane-state"
set +e
foreign_output="$(PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 \
  REPO_STATE_DIR="$state" PANE_ALIVE=0 TMUX_PANE_STATE="$TEST_ROOT/foreign-pane-state" \
  NEW_WINDOW_COUNT="$TEST_ROOT/foreign-window-count" FOREIGN_PANE=%77 \
  FOREIGN_PANE_IDENTITY="0|%77|7777|777777|sh -c echo-SGT_REPLACEMENT_TOKEN=$foreign_token" \
  KILL_LOG="$TEST_ROOT/foreign-kill.log" \
  "$ROOT_DIR/bin/sgt-respond" "$task" app \
  < "$TEST_ROOT/foreign-input" 2>&1)"
foreign_status=$?
set -e
[[ "$foreign_status" -ne 0 && "$foreign_output" == *'foreign pane'* ]]
[[ ! -e "$TEST_ROOT/foreign-window-count" ]]
[[ -z "$(cat "$TEST_ROOT/foreign-kill.log" 2>/dev/null || true)" ]]

# Canonical journal parsing is fail-closed at the public CLI: unknown phases,
# missing fields, and extra fields are never repaired or overwritten on retry.
for malformed in extra missing bad_phase; do
  read -r state wt <<<"$(make_worktree malformed-$malformed)"
  task="task-malformed-$malformed"
  setup_orphan "$state" "$wt"
  install_accepted_turn "$state" "$wt"
  printf 'strict journal' > "$TEST_ROOT/malformed-input"
  set +e
  PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 \
    REPO_STATE_DIR="$state" PANE_ALIVE=0 NEW_PANE=%98 \
    NEW_WINDOW_COUNT="$TEST_ROOT/malformed-$malformed-count" \
    SGT_TEST_HOOKS=1 SGT_TEST_INTERRUPT_TRANSFER_AT=replacement_owned \
    "$ROOT_DIR/bin/sgt-respond" "$task" app < "$TEST_ROOT/malformed-input" \
    >/dev/null 2>&1
  set -e
  journal="$state/response_relaunch_transaction"
  case "$malformed" in
    extra) printf 'unexpected=value\n' >> "$journal" ;;
    missing) sed -i '$d' "$journal" ;;
    bad_phase) sed -i 's/^phase=.*/phase=unknown/' "$journal" ;;
  esac
  if PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 \
      REPO_STATE_DIR="$state" PANE_ALIVE=0 NEW_PANE=%99 \
      NEW_WINDOW_COUNT="$TEST_ROOT/malformed-$malformed-count" \
      "$ROOT_DIR/bin/sgt-respond" "$task" app < "$TEST_ROOT/malformed-input" \
      >/dev/null 2>&1; then
    printf 'malformed journal %s was accepted\n' "$malformed" >&2
    exit 1
  fi
  [[ "$(cat "$TEST_ROOT/malformed-$malformed-count")" == 1 ]]
done

# A real SIGKILL after tmux creates the replacement leaves the durable spawning
# intent behind. The exact pane is discovered by its nonce-derived window and
# adopted; retry must not execute new-window a second time.
read -r state wt <<<"$(make_worktree sigkill-spawn)"
task=task-sigkill-spawn
setup_orphan "$state" "$wt"
install_accepted_turn "$state" "$wt"
printf 'uncommitted payload survives abrupt transfer\n' > "$wt/uncommitted.txt"
content_before="$(worktree_content_hash "$wt")"
printf 'resume after abrupt death' > "$TEST_ROOT/sigkill-input"
set +e
PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 \
  REPO_STATE_DIR="$state" PANE_ALIVE=0 NEW_PANE=%98 \
  TMUX_PANE_STATE="$TEST_ROOT/sigkill-pane-state" \
  NEW_WINDOW_COUNT="$TEST_ROOT/sigkill-new-window-count" \
  KILL_RESPOND_AFTER_SPAWN=1 \
  "$ROOT_DIR/bin/sgt-respond" "$task" app \
  < "$TEST_ROOT/sigkill-input" >/dev/null 2>&1
sigkill_status=$?
set -e
[[ "$sigkill_status" -ne 0 && -s "$state/response_relaunch_transaction" ]]
PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 \
  REPO_STATE_DIR="$state" PANE_ALIVE=0 NEW_PANE=%98 \
  TMUX_PANE_STATE="$TEST_ROOT/sigkill-pane-state" \
  NEW_WINDOW_COUNT="$TEST_ROOT/sigkill-new-window-count" \
  "$ROOT_DIR/bin/sgt-respond" "$task" app \
  < "$TEST_ROOT/sigkill-input" >/dev/null 2>&1 || {
  printf 'SIGKILLed replacement was not adopted on exact retry\n' >&2
  exit 1
}
[[ "$(cat "$TEST_ROOT/sigkill-new-window-count")" == 1 ]]
[[ "$(cat "$state/pane")" == '%98' ]]
[[ "$(sed -n 's/^phase=//p' "$state/response_relaunch_transaction")" == acked ]]
[[ "$(worktree_content_hash "$wt")" == "$content_before" ]]
[[ "$(cat "$wt/uncommitted.txt")" == 'uncommitted payload survives abrupt transfer' ]]

# Concurrent exact retries serialize through acknowledgement and the follower
# joins the immutable acked journal instead of spawning or delivering twice.
read -r state wt <<<"$(make_worktree concurrent-retry)"
task=task-concurrent-retry
setup_orphan "$state" "$wt"
printf 'one concurrent response' > "$TEST_ROOT/concurrent-input"
PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 \
  REPO_STATE_DIR="$state" PANE_ALIVE=0 NEW_PANE=%98 \
  TMUX_PANE_STATE="$TEST_ROOT/concurrent-pane-state" \
  NEW_WINDOW_COUNT="$TEST_ROOT/concurrent-window-count" \
  ACK_GATE_FILE="$TEST_ROOT/concurrent-ack-gate" SGT_NOTIFICATION_ACK_TIMEOUT=10 \
  "$ROOT_DIR/bin/sgt-respond" "$task" app \
  < "$TEST_ROOT/concurrent-input" > "$TEST_ROOT/concurrent-first.out" 2>&1 &
first_pid=$!
for _ in $(seq 1 100); do
  [[ -s "$TEST_ROOT/concurrent-window-count" && -e "$state/response.lock" ]] && break
  sleep 0.05
done
[[ -s "$TEST_ROOT/concurrent-window-count" && -e "$state/response.lock" ]]
PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 \
  REPO_STATE_DIR="$state" PANE_ALIVE=0 NEW_PANE=%98 \
  TMUX_PANE_STATE="$TEST_ROOT/concurrent-pane-state" \
  NEW_WINDOW_COUNT="$TEST_ROOT/concurrent-window-count" \
  ACK_GATE_FILE="$TEST_ROOT/concurrent-ack-gate" SGT_NOTIFICATION_ACK_TIMEOUT=10 \
  "$ROOT_DIR/bin/sgt-respond" "$task" app \
  < "$TEST_ROOT/concurrent-input" > "$TEST_ROOT/concurrent-second.out" 2>&1 &
second_pid=$!
sleep 0.2
kill -0 "$first_pid"
kill -0 "$second_pid"
touch "$TEST_ROOT/concurrent-ack-gate"
wait "$first_pid"
wait "$second_pid"
[[ "$(cat "$TEST_ROOT/concurrent-window-count")" == 1 ]]
grep -Fq 'joined acknowledged worker relaunch' "$TEST_ROOT/concurrent-second.out"
[[ "$(sed -n 's/^phase=//p' "$state/response_relaunch_transaction")" == acked ]]

# The action-lease successor binding is shared across CLIs. A SIGKILLed recover
# after fencing can be reconciled orphaned and resumed by sgt-respond without
# minting a different successor generation.
read -r state wt <<<"$(make_worktree cross-cli)"
task=task-cross-cli
setup_stall "$state" "$wt"
install_accepted_turn "$state" "$wt"
set +e
PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 \
  REPO_STATE_DIR="$state" PANE_ALIVE=0 SGT_TEST_HOOKS=1 \
  SGT_TEST_INTERRUPT_RECOVER_AT=fenced \
  "$ROOT_DIR/bin/sgt-recover" "$task" app >/dev/null 2>&1
cross_recover_status=$?
set -e
[[ "$cross_recover_status" -ne 0 ]]
bound_successor="$(sed -n 's/^successor_notification=//p' \
  "$state/notifications/$NOTIFY/successor_binding")"
[[ "$bound_successor" =~ ^[a-f0-9]{32}$ ]]
PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 \
  REPO_STATE_DIR="$state" PANE_ALIVE=0 \
  "$ROOT_DIR/bin/sgt-recover" "$task" app >/dev/null 2>&1
[[ "$(cat "$state/notification_id")" == "$bound_successor" ]]
grep -Fq "new_notification=$bound_successor" \
  "$state/notifications/$NOTIFY/ownership_transition"

read -r state wt <<<"$(make_worktree cross-cli-spawn)"
task=task-cross-cli-spawn
setup_stall "$state" "$wt"
install_accepted_turn "$state" "$wt"
set +e
PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 \
  REPO_STATE_DIR="$state" PANE_ALIVE=0 NEW_PANE=%98 \
  TMUX_PANE_STATE="$TEST_ROOT/cross-spawn-pane-state" \
  NEW_WINDOW_COUNT="$TEST_ROOT/cross-spawn-window-count" \
  SGT_TEST_HOOKS=1 SGT_TEST_INTERRUPT_RECOVER_AT=spawned \
  "$ROOT_DIR/bin/sgt-recover" "$task" app >/dev/null 2>&1
cross_spawn_status=$?
set -e
[[ "$cross_spawn_status" -ne 0 ]]
spawn_successor="$(sed -n 's/^notification_id=//p' \
  "$state/response_relaunch_transaction")"
printf 'resume spawned pane across cli' | PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 REPO_STATE_DIR="$state" \
  PANE_ALIVE=0 NEW_PANE=%98 TMUX_PANE_STATE="$TEST_ROOT/cross-spawn-pane-state" \
  NEW_WINDOW_COUNT="$TEST_ROOT/cross-spawn-window-count" \
  "$ROOT_DIR/bin/sgt-respond" "$task" app >/dev/null 2>&1
[[ "$(cat "$TEST_ROOT/cross-spawn-window-count")" == 1 ]]
[[ "$(cat "$state/notification_id")" == "$spawn_successor" ]]
[[ "$(sed -n 's/^phase=//p' "$state/response_relaunch_transaction")" == acked ]]

# Real tmux 3.4+: the public CLIs create option-stamped panes and adopt them
# after an actual SIGKILL without relying on rendered pane_start_command.
if command -v /usr/bin/tmux >/dev/null 2>&1 &&
    [[ "$(/usr/bin/tmux -V)" == 'tmux 3.4'* ]]; then
  real_socket="sgt-lease-real-$$"
  real_bin="$TEST_ROOT/real-bin"
  mkdir -p "$real_bin"
  cat > "$real_bin/tmux" <<EOF
#!/usr/bin/env bash
exec /usr/bin/tmux -L $real_socket "\$@"
EOF
  cat > "$real_bin/opencode" <<'EOF'
#!/usr/bin/env bash
exec sleep 60
EOF
  chmod +x "$real_bin/tmux" "$real_bin/opencode"

  read -r state wt <<<"$(make_worktree real-respond)"
  task=task-real-respond
  setup_orphan "$state" "$wt"
  printf 'real-sgt\n' > "$state/tmux_session"
  printf 'real/respond\n' > "$state/window_name"
  printf '%%99999\n' > "$state/pane"
  printf '0|%%99999|99999|1|old-worker\n' > "$state/pane_identity"
  PATH="$real_bin:/usr/bin:$fake_bin" tmux new-session -d -s real-sgt -n base 'sleep 60'
  printf 'real tmux response' > "$TEST_ROOT/real-respond-input"
  set +e
  PATH="$real_bin:/usr/bin:$fake_bin" SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 \
    SGT_TEST_HOOKS=1 SGT_TEST_KILL_TRANSFER_AT=replacement_spawned \
    "$ROOT_DIR/bin/sgt-respond" "$task" app < "$TEST_ROOT/real-respond-input" \
    >/dev/null 2>&1
  real_respond_killed=$?
  set -e
  [[ "$real_respond_killed" -ne 0 ]]
  (
    for _ in $(seq 1 200); do
      notification_id="$(cat "$state/notification_id" 2>/dev/null || true)"
      nonce="$(cat "$state/notification_target" 2>/dev/null || true)"
      identity="$(cat "$state/pane_identity" 2>/dev/null || true)"
      if [[ "$notification_id" =~ ^[a-f0-9]{32}$ && "$nonce" =~ ^[a-f0-9]{32}$ &&
            "$identity" == 0\|%* ]]; then
        target_dir="$state/notifications/$notification_id/targets/$nonce"
        token="$notification_id|$nonce"
        mkdir -p "$wt/.sergeant-notification-acks" \
          "$wt/.sergeant-notification-accepts" "$target_dir"
        printf '%s\n' "$token" > "$wt/.sergeant-notification-acks/$nonce"
        printf '%s\n' "$token" > "$wt/.sergeant-notification-accepts/$nonce"
        printf '%s\n' "$token" > "$target_dir/accepted"
        printf '%s\n' "$token" > "$target_dir/delivered"
        printf '%s\n' "$identity" > "$state/notification_delivered_pane_identity"
        printf '%s\n' "$notification_id" > "$state/notification_delivered"
        exit 0
      fi
      sleep 0.05
    done
    exit 1
  ) &
  real_ack_pid=$!
  PATH="$real_bin:/usr/bin:$fake_bin" SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 \
    SGT_NOTIFICATION_ACK_TIMEOUT=10 \
    "$ROOT_DIR/bin/sgt-respond" "$task" app < "$TEST_ROOT/real-respond-input" \
    >/dev/null 2>&1
  wait "$real_ack_pid"
  real_pane="$(cat "$state/pane")"
  real_token="$(cut -d '|' -f3 "$state/response_successor_notification")"
  [[ "$(PATH="$real_bin:/usr/bin:$fake_bin" tmux display-message -p -t "$real_pane" \
    '#{@sergeant_replacement_token}|#{@sergeant_replacement_role}')" == \
    "$real_token|worker:opencode" ]]
  [[ "$(PATH="$real_bin:/usr/bin:$fake_bin" tmux list-panes -a -F '#{window_name}' | \
    grep -c '^real/respond-resume-')" == 1 ]]

  read -r state wt <<<"$(make_worktree real-recover)"
  task=task-real-recover
  setup_stall "$state" "$wt"
  printf 'real-sgt\n' > "$state/tmux_session"
  printf 'real/recover\n' > "$state/window_name"
  old_real_pane="$(PATH="$real_bin:/usr/bin:$fake_bin" tmux list-panes -t real-sgt:=base -F '#{pane_id}')"
  printf '%s\n' "$old_real_pane" > "$state/pane"
  PATH="$real_bin:/usr/bin:$fake_bin" tmux display-message -p -t "$old_real_pane" \
    '#{pane_dead}|#{pane_id}|#{pane_pid}|#{pane_created}|#{pane_start_command}' \
    > "$state/pane_identity"
  set +e
  PATH="$real_bin:/usr/bin:$fake_bin" SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 \
    SGT_TEST_HOOKS=1 SGT_TEST_INTERRUPT_RECOVER_AT=spawned \
    "$ROOT_DIR/bin/sgt-recover" "$task" app >/dev/null 2>&1
  real_recover_killed=$?
  set -e
  [[ "$real_recover_killed" -ne 0 ]]
  (
    for _ in $(seq 1 200); do
      notification_id="$(cat "$state/notification_id" 2>/dev/null || true)"
      nonce="$(cat "$state/notification_target" 2>/dev/null || true)"
      identity="$(cat "$state/pane_identity" 2>/dev/null || true)"
      if [[ "$notification_id" =~ ^[a-f0-9]{32}$ && "$nonce" =~ ^[a-f0-9]{32}$ &&
            "$identity" == 0\|%* && "$identity" != *"|$old_real_pane|"* ]]; then
        target_dir="$state/notifications/$notification_id/targets/$nonce"
        token="$notification_id|$nonce"
        mkdir -p "$wt/.sergeant-notification-acks" \
          "$wt/.sergeant-notification-accepts" "$target_dir"
        printf '%s\n' "$token" > "$wt/.sergeant-notification-acks/$nonce"
        printf '%s\n' "$token" > "$wt/.sergeant-notification-accepts/$nonce"
        printf '%s\n' "$token" > "$target_dir/accepted"
        printf '%s\n' "$token" > "$target_dir/delivered"
        printf '%s\n' "$identity" > "$state/notification_delivered_pane_identity"
        printf '%s\n' "$notification_id" > "$state/notification_delivered"
        exit 0
      fi
      sleep 0.05
    done
    exit 1
  ) &
  real_recover_ack_pid=$!
  PATH="$real_bin:/usr/bin:$fake_bin" SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 \
    SGT_NOTIFICATION_ACK_TIMEOUT=10 \
    "$ROOT_DIR/bin/sgt-recover" "$task" app >/dev/null 2>&1
  wait "$real_recover_ack_pid"
  recovered_real_pane="$(cat "$state/pane")"
  recovery_token="$(cut -d '|' -f2 "$state/recovery_successor_notification")"
  [[ "$(PATH="$real_bin:/usr/bin:$fake_bin" tmux display-message -p -t "$recovered_real_pane" \
    '#{@sergeant_replacement_token}|#{@sergeant_replacement_role}')" == \
    "$recovery_token|worker:opencode" ]]
  [[ "$(PATH="$real_bin:/usr/bin:$fake_bin" tmux list-panes -a -F '#{window_name}' | \
    grep -c '^real/recover-resume-')" == 1 ]]
  PATH="$real_bin:/usr/bin:$fake_bin" tmux kill-server
fi

printf 'action-lease convergence before refusal: ok\n'
