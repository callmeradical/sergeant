#!/usr/bin/env bash
# Regression: sgt-respond never leaves a response indefinitely pending
# (td-79e20c / GH #156).
#
# Delivery to a live pane is bounded by SGT_NOTIFICATION_ACK_TIMEOUT.  When that
# bound elapsed, sgt-respond died with "Worker did not acknowledge its durable
# response notification; response remains pending" and every retry was refused
# with "A Sergeant response is already pending consumption", so the operator was
# dead-ended with no supported next action.
#
# Rerunning the same command must now be the documented bounded recovery path:
# exactly one worker relaunch, with the unresponsive pane retired only after the
# replacement is validated.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fleet="$TEST_ROOT/fleet"
source_repo="$TEST_ROOT/source"
fake_bin="$TEST_ROOT/fake-bin"
config_dir="$TEST_ROOT/config"
export SERGEANT_CONFIG="$config_dir"
export SGT_WIKI_DISABLED=1

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

# Fake tmux.  ACK_NEW_PANE controls whether a relaunched pane completes its
# delivery handshake; the original pane %42 never acknowledges.
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
    pane_identity="0|%42|4242|123456|stalled-pane"
    if [[ "$target" == "%99" ]]; then
      pane_identity="0|%99|9999|654321|relaunched"
      if [[ "${ACK_NEW_PANE:-1}" == 1 && -s "$REPO_STATE_DIR/notification_id" ]]; then
        notification_id="$(cat "$REPO_STATE_DIR/notification_id")"
        wt="$(cat "$REPO_STATE_DIR/worktree")"
        nonce="$(cat "$REPO_STATE_DIR/notification_target" 2>/dev/null || true)"
        if [[ "$nonce" =~ ^[a-f0-9]{32}$ ]]; then
          token="$notification_id|$nonce"
          target_dir="$REPO_STATE_DIR/notifications/$notification_id/targets/$nonce"
          mkdir -p "$wt/.sergeant-notification-acks" \
            "$wt/.sergeant-notification-accepts" "$target_dir"
          printf '%s\n' "$token" > "$wt/.sergeant-notification-acks/$nonce"
          printf '%s\n' "$token" > "$wt/.sergeant-notification-accepts/$nonce"
          printf '%s\n' "$token" > "$target_dir/accepted"
          printf '%s\n' "$token" > "$target_dir/delivered"
          printf '%s\n' "$pane_identity" \
            > "$REPO_STATE_DIR/notification_delivered_pane_identity"
          printf '%s\n' "$notification_id" > "$REPO_STATE_DIR/notification_delivered"
        fi
      fi
    fi
    printf '%s\n' "$pane_identity"
    ;;
  new-window)
    printf '%s\n' "$*" >> "${WINDOW_LOG:-/dev/null}"
    printf '%%99\n'
    ;;
  kill-pane)
    target_pane=""
    previous=""
    for arg in "$@"; do
      [[ "$previous" == -t ]] && target_pane="$arg"
      previous="$arg"
    done
    printf '%s\n' "$target_pane" >> "${KILL_LOG:-/dev/null}"
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

task=task-unacked
task_dir="$fleet/$task"
state="$task_dir/app"
wt="$TEST_ROOT/wt"
mkdir -p "$state"
git -C "$source_repo" worktree add -q -b unacked-test "$wt"
printf 'Project: test\nBrief: recovery test\nBranch: unacked-test\nRepos: app\n' \
  > "$task_dir/brief.md"
printf '%s\n' "$wt" > "$state/worktree"
pointer="$(cat "$wt/.git")"
printf '%s\n' "$pointer" > "$state/worktree_git_pointer"
git_dir="${pointer#gitdir: }"
[[ "$git_dir" == /* ]] || git_dir="$wt/$git_dir"
printf '%s\n' "$(cd "$git_dir" && pwd -P)" > "$state/worktree_git_dir"
cat > "$task_dir/.sergeant-intent.md" <<'INTENT'
## Objective

Exercise bounded response delivery recovery.
INTENT
revision="$(bash -c 'source "$1"; _sgt_intent_revision "$2"' _ \
  "$ROOT_DIR/bin/_sgt-intent.sh" "$task_dir/.sergeant-intent.md")"
printf '%s\n' "$revision" > "$task_dir/intent_revision"
cp "$task_dir/.sergeant-intent.md" "$state/.sergeant-intent.md"
cp "$task_dir/.sergeant-intent.md" "$wt/.sergeant-intent.md"
printf '%s\n' "$revision" > "$state/intent_revision"
printf '1\n' > "$wt/.sergeant-gate-generation"
printf 'needs_input\n' > "$state/status"
printf 'needs_input\n' > "$wt/.sergeant-status"
printf 'sgt\n' > "$state/tmux_session"
printf 'task/app\n' > "$state/window_name"
printf 'opencode\n' > "$state/agent"
printf '%%42\n' > "$state/pane"
printf '0|%%42|4242|123456|stalled-pane\n' > "$state/pane_identity"
chmod 600 "$state/pane_identity"

respond() {
  printf 'apply the decision' | env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" \
    "REPO_STATE_DIR=$state" SGT_NOTIFICATION_ACK_TIMEOUT=1 "$@" \
    "$ROOT_DIR/bin/sgt-respond" "$task" app 2>&1
}

# ── 1. Delivery to a live pane that never acknowledges is bounded ─────────────

set +e
first="$(respond TMUX_LOG="$TEST_ROOT/first.log" KILL_LOG="$TEST_ROOT/first-kill.log" \
  WINDOW_LOG="$TEST_ROOT/first-window.log")"
first_status=$?
set -e
[[ "$first_status" -ne 0 ]] || {
  printf 'delivery to a never-acknowledging pane reported success\n' >&2
  exit 1
}
[[ "$first" == *'did not acknowledge'* ]] || {
  printf 'the delivery bound was not reported:\n%s\n' "$first" >&2
  exit 1
}
# The error must name a supported next action, not just say "remains pending".
[[ "$first" == *"sgt-respond $task app"* ]] || {
  printf 'the delivery timeout dead-ended with no supported next command:\n%s\n' "$first" >&2
  exit 1
}
[[ "$first" == *'recoverable'* ]]
# The response is stored durably.
[[ "$(cat "$state/response")" == 'apply the decision' ]]
[[ "$(cat "$wt/.sergeant-response")" == 'apply the decision' ]]
# The escalation marker is bound to this response and gate generation.
[[ -f "$state/response_delivery_unacked" ]] || {
  printf 'no bounded recovery was armed after the delivery timeout\n' >&2
  exit 1
}
grep -Fxq "response_id=$(cat "$state/response_id")" "$state/response_delivery_unacked"
grep -Fxq 'gate_generation=1' "$state/response_delivery_unacked"
# No relaunch and no pane kill happened on the first attempt.
[[ ! -s "$TEST_ROOT/first-window.log" ]] || {
  printf 'the first delivery attempt relaunched the worker\n' >&2
  exit 1
}
[[ ! -s "$TEST_ROOT/first-kill.log" ]] || {
  printf 'the first delivery attempt killed a pane\n' >&2
  exit 1
}

# ── 2. Rerunning the command performs exactly one bounded relaunch ───────────

second="$(respond TMUX_LOG="$TEST_ROOT/second.log" KILL_LOG="$TEST_ROOT/second-kill.log" \
  WINDOW_LOG="$TEST_ROOT/second-window.log")"
[[ "$second" == *'escalating to one bounded worker relaunch'* ]] || {
  printf 'the retry did not announce the bounded recovery path:\n%s\n' "$second" >&2
  exit 1
}
[[ "$second" == *'relaunched worker in pane %99'* ]] || {
  printf 'the retry did not relaunch the worker:\n%s\n' "$second" >&2
  exit 1
}
[[ -s "$TEST_ROOT/second-window.log" ]]
[[ "$(cat "$state/pane")" == "%99" ]]
# The unresponsive pane is retired, and only after the replacement existed.
grep -Fxq '%42' "$TEST_ROOT/second-kill.log" || {
  printf 'the unresponsive pane was not retired:\n%s\n' \
    "$(cat "$TEST_ROOT/second-kill.log" 2>/dev/null || true)" >&2
  exit 1
}
new_window_line="$(grep -n '^new-window ' "$TEST_ROOT/second.log" | head -1 | cut -d: -f1)"
kill_line="$(grep -n '^kill-pane -t %42' "$TEST_ROOT/second.log" | head -1 | cut -d: -f1)"
[[ -n "$new_window_line" && -n "$kill_line" ]] || {
  printf 'expected both a relaunch and a kill in the tmux log\n' >&2
  exit 1
}
(( new_window_line < kill_line )) || {
  printf 'the unresponsive pane was killed before the replacement was launched\n' >&2
  exit 1
}
# The escalation is consumed, so it cannot repeat unboundedly.
[[ ! -e "$state/response_delivery_unacked" ]] || {
  printf 'the delivery escalation marker survived a successful relaunch\n' >&2
  exit 1
}

# ── 3. Without an escalation the operator is told what to do, not dead-ended ──
# A response still pending consumption by a live worker must not be redelivered,
# but the refusal has to name a supported next command.

set +e
third="$(respond TMUX_LOG="$TEST_ROOT/third.log")"
third_status=$?
set -e
[[ "$third_status" -ne 0 ]] || {
  printf 'a pending response was redelivered without an escalation\n' >&2
  exit 1
}
[[ "$third" == *'already pending consumption'* ]]
[[ "$third" == *"sgt-recover $task app"* ]] || {
  printf 'the pending-consumption refusal dead-ended with no supported command:\n%s\n' \
    "$third" >&2
  exit 1
}

# ── 4. An escalation for a different gate generation does not arm recovery ────
# The marker is generation-bound so a stale escalation cannot silently authorise
# a relaunch for a later gate.

{
  printf 'response_id=%s\n' "$(cat "$state/response_id")"
  printf 'gate_generation=99\n'
  printf 'reason=stale\n'
} > "$state/response_delivery_unacked"
set +e
fourth="$(respond TMUX_LOG="$TEST_ROOT/fourth.log" WINDOW_LOG="$TEST_ROOT/fourth-window.log")"
fourth_status=$?
set -e
[[ "$fourth_status" -ne 0 ]] || {
  printf 'a stale escalation marker authorised a relaunch\n' >&2
  exit 1
}
[[ ! -s "$TEST_ROOT/fourth-window.log" ]] || {
  printf 'a stale escalation marker relaunched the worker\n' >&2
  exit 1
}

# ── 5. An escalation for a different response id does not arm recovery ───────

{
  printf 'response_id=not-the-current-response\n'
  printf 'gate_generation=1\n'
  printf 'reason=stale\n'
} > "$state/response_delivery_unacked"
set +e
fifth="$(respond TMUX_LOG="$TEST_ROOT/fifth.log" WINDOW_LOG="$TEST_ROOT/fifth-window.log")"
fifth_status=$?
set -e
[[ "$fifth_status" -ne 0 ]] || {
  printf 'an escalation for another response authorised a relaunch\n' >&2
  exit 1
}
[[ ! -s "$TEST_ROOT/fifth-window.log" ]]

printf 'bounded sgt-respond delivery recovery: ok\n'
