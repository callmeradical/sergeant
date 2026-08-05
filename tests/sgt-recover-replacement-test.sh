#!/usr/bin/env bash
# Regression: sgt-recover validates the replacement supervisor BEFORE retiring the
# stalled one, and on any validation failure restores fleet state and refuses
# recovery (td-520486).
#
# The dangerous shape is killing the current supervisor and only then discovering
# that the replacement cannot be launched or cannot be identified — that loses the
# supervisor entirely with nothing to investigate. The kill must therefore be
# strictly ordered after the replacement is live, its identity published, and its
# notification target created; and every abort path must leave the recorded pane
# pointing at the surviving original.

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

# Fake tmux with failure knobs for each replacement-validation step:
#   FAIL_WINDOW=1              new-window fails outright
#   EMPTY_WINDOW=1             new-window succeeds but returns no pane id
#   FAIL_NEW_PANE_IDENTITY=1   the replacement pane cannot be identified
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
    if [[ "$target" == "%99" ]]; then
      [[ "${FAIL_NEW_PANE_IDENTITY:-0}" == 0 ]] || exit 1
      pane_identity="0|%99|9999|654321|relaunched"
      if [[ "${ACK_NEW_PANE:-1}" == 1 && -s "$REPO_STATE_DIR/notification_id" ]]; then
        notification_id="$(cat "$REPO_STATE_DIR/notification_id")"
        wt="$(cat "$REPO_STATE_DIR/worktree")"
        nonce="$(cat "$REPO_STATE_DIR/notification_target" 2>/dev/null || true)"
        if [[ "$nonce" =~ ^[a-f0-9]{32}$ ]]; then
          token="$notification_id|$nonce"
          target_dir="$REPO_STATE_DIR/notifications/$notification_id/targets/$nonce"
          mkdir -p "$target_dir"
          printf '%s\n' "$token" > "$target_dir/accepted"
          printf '%s\n' "$token" > "$target_dir/delivered"
        fi
      fi
      printf '%s\n' "$pane_identity"
    else
      printf '0|%%42|4242|123456|stalled-pane\n'
    fi
    ;;
  new-window)
    [[ "${FAIL_WINDOW:-0}" == 0 ]] || exit 7
    [[ "${EMPTY_WINDOW:-0}" == 0 ]] || exit 0
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

# make_stalled <name> — a stalled in_progress worker owning pane %42.
# Prints "<repo_state> <worktree>".
make_stalled() {
  local name="$1"
  local task_dir state wt pointer git_dir revision
  task_dir="$fleet/task-$name"
  state="$task_dir/app"
  wt="$TEST_ROOT/wt-$name"
  git -C "$source_repo" worktree add -q -b "replace-$name" "$wt"
  mkdir -p "$state"
  printf 'Project: test\nBrief: replacement test\nBranch: replace-%s\nRepos: app\n' \
    "$name" > "$task_dir/brief.md"
  printf '%s\n' "$wt" > "$state/worktree"
  pointer="$(cat "$wt/.git")"
  printf '%s\n' "$pointer" > "$state/worktree_git_pointer"
  git_dir="${pointer#gitdir: }"
  [[ "$git_dir" == /* ]] || git_dir="$wt/$git_dir"
  printf '%s\n' "$(cd "$git_dir" && pwd -P)" > "$state/worktree_git_dir"
  cat > "$task_dir/.sergeant-intent.md" <<'INTENT'
## Objective

Exercise replacement validation ordering.
INTENT
  revision="$(bash -c 'source "$1"; _sgt_intent_revision "$2"' _ \
    "$ROOT_DIR/bin/_sgt-intent.sh" "$task_dir/.sergeant-intent.md")"
  printf '%s\n' "$revision" > "$task_dir/intent_revision"
  cp "$task_dir/.sergeant-intent.md" "$state/.sergeant-intent.md"
  cp "$task_dir/.sergeant-intent.md" "$wt/.sergeant-intent.md"
  printf '%s\n' "$revision" > "$state/intent_revision"
  printf '1\n' > "$wt/.sergeant-gate-generation"
  printf 'in_progress\n' > "$state/status"
  printf 'in_progress\n' > "$wt/.sergeant-status"
  printf 'live worker stalled: no progress for 401s (grace=300s); last event at epoch 1000\n' \
    > "$state/diagnostic"
  printf 'sgt\n' > "$state/tmux_session"
  printf 'task/app\n' > "$state/window_name"
  printf 'opencode\n' > "$state/agent"
  printf '%%42\n' > "$state/pane"
  printf '0|%%42|4242|123456|stalled-pane\n' > "$state/pane_identity"
  chmod 600 "$state/pane_identity"
  printf '%s %s\n' "$state" "$wt"
}

recover() {
  local state="$1"
  shift
  env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" "REPO_STATE_DIR=$state" "$@" \
    "$ROOT_DIR/bin/sgt-recover" "$task" app 2>&1
}

# ── 1. The kill is strictly ordered after the validated replacement ────────────

read -r state wt <<<"$(make_stalled ordering)"
task=task-ordering
recover "$state" "TMUX_LOG=$TEST_ROOT/order.log" "KILL_LOG=$TEST_ROOT/order-kill.log" \
  >/dev/null || {
  printf 'happy-path recovery failed\n' >&2
  exit 1
}
new_window_line="$(grep -n '^new-window ' "$TEST_ROOT/order.log" | head -1 | cut -d: -f1)"
identity_line="$(grep -n '^display-message -p -t %99 ' "$TEST_ROOT/order.log" | head -1 | cut -d: -f1)"
kill_line="$(grep -n '^kill-pane -t %42' "$TEST_ROOT/order.log" | head -1 | cut -d: -f1)"
[[ -n "$new_window_line" && -n "$identity_line" && -n "$kill_line" ]] || {
  printf 'expected launch, identity capture and kill in the tmux log:\n%s\n' \
    "$(cat "$TEST_ROOT/order.log")" >&2
  exit 1
}
(( new_window_line < kill_line )) || {
  printf 'the stalled pane was killed before the replacement was launched\n' >&2
  exit 1
}
(( identity_line < kill_line )) || {
  printf 'the stalled pane was killed before the replacement identity was validated\n' >&2
  exit 1
}
[[ "$(cat "$state/pane")" == "%99" ]]
grep -Fxq '%42' "$TEST_ROOT/order-kill.log"
# Only the recorded pane was killed — never the replacement.
while IFS= read -r killed; do
  [[ -z "$killed" ]] && continue
  [[ "$killed" == "%42" ]] || {
    printf 'an unexpected pane was killed: %s\n' "$killed" >&2
    exit 1
  }
done < "$TEST_ROOT/order-kill.log"

# ── 2. A replacement that returns no pane id refuses and preserves the original ─

read -r state wt <<<"$(make_stalled emptypane)"
task=task-emptypane
set +e
empty_output="$(recover "$state" "TMUX_LOG=$TEST_ROOT/empty.log" \
  "KILL_LOG=$TEST_ROOT/empty-kill.log" EMPTY_WINDOW=1)"
empty_status=$?
set -e
[[ "$empty_status" -ne 0 ]] || {
  printf 'recovery succeeded although the replacement returned no pane\n' >&2
  exit 1
}
[[ "$empty_output" == *'returned no pane'* ]]
[[ -z "$(cat "$TEST_ROOT/empty-kill.log" 2>/dev/null || true)" ]] || {
  printf 'the stalled pane was killed although the replacement had no pane id\n' >&2
  exit 1
}
[[ "$(cat "$state/pane")" == "%42" ]] || {
  printf 'fleet state was not restored to the surviving pane: %s\n' \
    "$(cat "$state/pane")" >&2
  exit 1
}
# The worker is escalated for investigation rather than silently lost.
[[ "$(cat "$state/status")" == "needs_input" ]]

# ── 3. A replacement whose identity cannot be captured refuses and restores ────

read -r state wt <<<"$(make_stalled noidentity)"
task=task-noidentity
set +e
identity_output="$(recover "$state" "TMUX_LOG=$TEST_ROOT/noid.log" \
  "KILL_LOG=$TEST_ROOT/noid-kill.log" FAIL_NEW_PANE_IDENTITY=1)"
identity_status=$?
set -e
[[ "$identity_status" -ne 0 ]] || {
  printf 'recovery succeeded although the replacement could not be identified\n' >&2
  exit 1
}
[[ "$identity_output" == *'capture'* ]] || {
  printf 'the identity-capture failure was not reported:\n%s\n' "$identity_output" >&2
  exit 1
}
# The unvalidated replacement is discarded; the stalled supervisor survives.
grep -Fxq '%99' "$TEST_ROOT/noid-kill.log" || {
  printf 'the unvalidated replacement pane was not discarded:\n%s\n' \
    "$(cat "$TEST_ROOT/noid-kill.log" 2>/dev/null || true)" >&2
  exit 1
}
if grep -Fxq '%42' "$TEST_ROOT/noid-kill.log"; then
  printf 'the stalled pane was killed although the replacement was never validated\n' >&2
  exit 1
fi
[[ "$(cat "$state/pane")" == "%42" ]] || {
  printf 'fleet state was not restored to the surviving pane: %s\n' \
    "$(cat "$state/pane")" >&2
  exit 1
}
[[ "$(cat "$state/status")" == "needs_input" ]]

# ── 4. A replacement that cannot be launched refuses and touches nothing ──────

read -r state wt <<<"$(make_stalled nolaunch)"
task=task-nolaunch
set +e
launch_output="$(recover "$state" "TMUX_LOG=$TEST_ROOT/nolaunch.log" \
  "KILL_LOG=$TEST_ROOT/nolaunch-kill.log" FAIL_WINDOW=1)"
launch_status=$?
set -e
[[ "$launch_status" -ne 0 ]] || {
  printf 'recovery succeeded although the replacement could not be launched\n' >&2
  exit 1
}
[[ -z "$(cat "$TEST_ROOT/nolaunch-kill.log" 2>/dev/null || true)" ]] || {
  printf 'a pane was killed although no replacement was launched\n' >&2
  exit 1
}
[[ "$(cat "$state/pane")" == "%42" ]]

printf 'sgt-recover replacement validation before retirement: ok\n'
