#!/usr/bin/env bash
# Tests for sgt-respond drain admission — response stored but relaunch held
# when a global or project drain is active.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fleet="$TEST_ROOT/fleet"
task_dir="$fleet/task-1"
repo_state="$task_dir/app"
worktree="$TEST_ROOT/worktree"
source_repo="$TEST_ROOT/source"
fake_bin="$TEST_ROOT/fake-bin"
config_dir="$TEST_ROOT/config"

mkdir -p "$repo_state" "$source_repo" "$fake_bin" "$config_dir"
export SERGEANT_CONFIG="$config_dir"
export SERGEANT_FLEET="$fleet"

# Build a real git worktree (required by sgt-respond ownership checks)
git -C "$source_repo" init -q
git -C "$source_repo" config user.name Test
git -C "$source_repo" config user.email test@example.invalid
touch "$source_repo/README.md"
git -C "$source_repo" add README.md
git -C "$source_repo" commit -qm fixture
git -C "$source_repo" worktree add -q -b drain-test "$worktree"

cat > "$config_dir/test.yaml" <<EOF
repos:
  - name: app
    path: $source_repo
EOF

printf 'Project: test\nBrief: drain fixture\nBranch: drain-test\nRepos: app\n' \
  > "$task_dir/brief.md"

# Fleet ownership state
printf '%s\n' "$worktree" > "$repo_state/worktree"
cat "$worktree/.git" > "$repo_state/worktree_git_pointer"
worktree_git_dir_path="$(sed 's/^gitdir: //' "$worktree/.git")"
printf '%s\n' "$(cd "$worktree_git_dir_path" && pwd -P)" > "$repo_state/worktree_git_dir"

# Intent files
cat > "$task_dir/.sergeant-intent.md" <<'EOF'
## Objective

Drain admission test.
EOF
cp "$task_dir/.sergeant-intent.md" "$repo_state/.sergeant-intent.md"
cp "$task_dir/.sergeant-intent.md" "$worktree/.sergeant-intent.md"
bash -c 'source "$1"; _sgt_intent_revision "$2"' _ \
  "$ROOT_DIR/bin/_sgt-intent.sh" "$task_dir/.sergeant-intent.md" \
  > "$task_dir/intent_revision"
cp "$task_dir/intent_revision" "$repo_state/intent_revision"

# Worker brief
cat > "$worktree/.sergeant-brief.md" <<EOF
**Task ID:** task-1
**Project:** test
**Repo:** app
**Branch:** drain-test
**Worktree:** $worktree
**Fleet state:** $repo_state/
EOF

# Fake tmux: supports live/new pane identity, auto-delivers notifications.
# PANE_ALIVE=1 required. For old pane mismatch set PANE_IDENTITY='bash:other'.
# Reuse the pattern from sgt-respond-test.sh.
cat > "$fake_bin/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TMUX_LOG:-/dev/null}"
case "$1" in
  display-message)
    [[ "${PANE_ALIVE:-1}" == 1 ]] || exit 1
    target=""
    previous=""
    for argument in "$@"; do
      [[ "$previous" == -t ]] && target="$argument"
      previous="$argument"
    done
    pane_identity="${PANE_IDENTITY:-0|%42|4242|123456|sgt-interactive-worker:$EXPECTED_WORKER}"
    if [[ "$target" == "${NEW_PANE:-%99}" ]]; then
      pane_identity="0|$target|9999|654321|sgt-interactive-worker:$EXPECTED_WORKER"
      if [[ "${AUTO_DELIVER:-1}" == 1 && -s "$EXPECTED_WORKER/notification_id" ]]; then
        notification_id="$(cat "$EXPECTED_WORKER/notification_id")"
        notification_worktree="$(cat "$EXPECTED_WORKER/worktree")"
        nonce="$(cat "$EXPECTED_WORKER/notification_target" 2>/dev/null || true)"
        if [[ "$nonce" =~ ^[a-f0-9]{32}$ ]]; then
          token="$notification_id|$nonce"
          target_dir="$EXPECTED_WORKER/notifications/$notification_id/targets/$nonce"
          mkdir -p "$notification_worktree/.sergeant-notification-acks" \
            "$notification_worktree/.sergeant-notification-accepts"
          printf '%s\n' "$token" > "$notification_worktree/.sergeant-notification-acks/$nonce"
          printf '%s\n' "$token" > "$notification_worktree/.sergeant-notification-accepts/$nonce"
          printf '%s\n' "$token" > "$target_dir/accepted"
          printf '%s\n' "$token" > "$target_dir/delivered"
          printf '%s\n' "$pane_identity" > "$EXPECTED_WORKER/notification_delivered_pane_identity"
          printf '%s\n' "$notification_id" > "$EXPECTED_WORKER/notification_delivered"
        fi
      fi
    fi
    printf '%s\n' "$pane_identity"
    ;;
  new-window)
    printf '%s\n' "${NEW_PANE:-%99}"
    ;;
  kill-pane) exit 0 ;;
  send-keys) exit 0 ;;
esac
EOF
chmod +x "$fake_bin/tmux"

cat > "$fake_bin/td" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TD_LOG:-/dev/null}"
EOF
chmod +x "$fake_bin/td"
printf 'td-123\n' > "$repo_state/td_task"

printf 'sgt\n' > "$repo_state/tmux_session"
printf 'task/app\n' > "$repo_state/window_name"
printf 'fake-opencode\n' > "$repo_state/agent"
printf 'drain-test\n' > "$repo_state/branch"

# Stored pane identity (for live pane matching check)
printf '0|%%42|4242|123456|sgt-interactive-worker:%s\n' "$repo_state" \
  > "$repo_state/pane_identity"
chmod 600 "$repo_state/pane_identity"

respond() {
  local response_body="$1"
  # env vars on the LEFT of a pipeline apply only to the left-side command.
  # Use a subshell so PATH and other vars are in scope for sgt-respond (right side).
  (
    export PATH="$fake_bin:$PATH"
    export EXPECTED_WORKER="$repo_state"
    export TD_LOG="${TD_LOG:-$TEST_ROOT/td.log}"
    export TMUX_LOG="${TMUX_LOG:-$TEST_ROOT/tmux.log}"
    printf '%s' "$response_body" | "$ROOT_DIR/bin/sgt-respond" task-1 app
  )
}

_reset_worker() {
  printf 'needs_input\n' > "$repo_state/status"
  printf 'needs_input\n' > "$worktree/.sergeant-status"
  printf '1\n' > "$worktree/.sergeant-gate-generation"
  rm -f "$repo_state/pane" "$repo_state/response" "$repo_state/response_generation" \
    "$repo_state/response_id" "$repo_state/drain_held" "$repo_state/notification_id" \
    "$repo_state/notification_delivered" "$repo_state/notification_target" \
    "$worktree/.sergeant-response" "$worktree/.sergeant-response-generation" \
    "$worktree/.sergeant-response-id" "$worktree/.sergeant-notification"
  rm -rf "$config_dir/drain"
}

_reset_worker

# ── Slice 1: Global drain — response stored, no relaunch, drain_held written ──
# Worker has no live pane (no pane file) → would normally go to dead-pane
# relaunch. With global drain active, relaunch is held.

mkdir -p "$config_dir/drain"
printf 'reason=maintenance\ncreated=2025-01-01T00:00:00Z\n' > "$config_dir/drain/global"

PATH="$fake_bin:$PATH" PANE_ALIVE=1 PANE_IDENTITY='bash:other-worker' \
  EXPECTED_WORKER="$repo_state" \
  TMUX_LOG="$TEST_ROOT/drain-global.log" TD_LOG="$TEST_ROOT/td.log" \
  respond 'drain response' >/dev/null 2>&1

# Response stored in both fleet and worktree
[[ -f "$worktree/.sergeant-response" ]] || {
  printf 'drain: response should be stored in worktree\n' >&2; exit 1
}
[[ -f "$repo_state/response" ]] || {
  printf 'drain: response should be stored in fleet\n' >&2; exit 1
}
# No new-window call
! grep -qF 'new-window' "$TEST_ROOT/drain-global.log" || {
  printf 'drain: new-window should not be called when drained\n' >&2; exit 1
}
# drain_held marker written with gate generation
[[ -f "$repo_state/drain_held" ]] || {
  printf 'drain: drain_held marker should be written\n' >&2; exit 1
}
[[ "$(cat "$repo_state/drain_held")" == "1" ]] || {
  printf 'drain: drain_held should contain the gate generation (1), got: %s\n' \
    "$(cat "$repo_state/drain_held")" >&2; exit 1
}
printf 'sgt-respond global drain holds relaunch: ok\n'

_reset_worker

# ── Slice 2: Project drain — matching project holds relaunch ─────────────────

mkdir -p "$config_dir/drain"
printf 'reason=feature-gate\ncreated=2025-01-01T00:00:00Z\n' > "$config_dir/drain/test"

PATH="$fake_bin:$PATH" PANE_ALIVE=1 PANE_IDENTITY='bash:other-worker' \
  EXPECTED_WORKER="$repo_state" \
  TMUX_LOG="$TEST_ROOT/drain-project.log" TD_LOG="$TEST_ROOT/td-project.log" \
  respond 'drain project response' >/dev/null 2>&1

[[ -f "$worktree/.sergeant-response" ]] || {
  printf 'project drain: response should be stored\n' >&2; exit 1
}
! grep -qF 'new-window' "$TEST_ROOT/drain-project.log" || {
  printf 'project drain: new-window should not be called\n' >&2; exit 1
}
[[ -f "$repo_state/drain_held" ]] || {
  printf 'project drain: drain_held should be written\n' >&2; exit 1
}
printf 'sgt-respond project drain holds relaunch: ok\n'

_reset_worker

# ── Slice 3: Unrelated project drain — relaunch proceeds normally ─────────────

mkdir -p "$config_dir/drain"
printf 'reason=other\ncreated=2025-01-01T00:00:00Z\n' > "$config_dir/drain/otherproject"

PATH="$fake_bin:$PATH" PANE_ALIVE=1 PANE_IDENTITY='bash:other-worker' \
  NEW_PANE="%77" EXPECTED_WORKER="$repo_state" \
  TMUX_LOG="$TEST_ROOT/drain-other.log" TD_LOG="$TEST_ROOT/td-other.log" \
  respond 'no drain response' >/dev/null 2>&1

grep -qF 'new-window' "$TEST_ROOT/drain-other.log" || {
  printf 'unrelated drain: new-window should be called\n' >&2; exit 1
}
[[ ! -f "$repo_state/drain_held" ]] || {
  printf 'unrelated drain: drain_held should NOT be written\n' >&2; exit 1
}
[[ "$(cat "$repo_state/pane")" == "%77" ]] || {
  printf 'unrelated drain: pane should be updated to %%77\n' >&2; exit 1
}
printf 'sgt-respond unrelated project drain allows relaunch: ok\n'

_reset_worker

# ── Slice 4: drain_held reevaluation — relaunch proceeds after undrain ────────
# Simulate: response was previously stored with drain_held during drain.
# Now drain is lifted; calling sgt-respond again should relaunch.

# Pre-populate stored response and drain_held (simulating prior drained delivery)
printf 'Use option A' > "$repo_state/response"
response_id_hex="$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
printf '%s\n' "1" > "$worktree/.sergeant-gate-generation"
printf '%s\n' "1" > "$repo_state/response_generation"
printf '%s\n' "$response_id_hex" > "$repo_state/response_id"
cp "$repo_state/response" "$worktree/.sergeant-response"
printf '%s\n' "1" > "$worktree/.sergeant-response-generation"
printf '%s\n' "$response_id_hex" > "$worktree/.sergeant-response-id"
printf '1\n' > "$repo_state/drain_held"
# No drain active (undrained)

PATH="$fake_bin:$PATH" PANE_ALIVE=1 PANE_IDENTITY='bash:other-worker' \
  NEW_PANE="%88" EXPECTED_WORKER="$repo_state" \
  TMUX_LOG="$TEST_ROOT/drain-reevaluate.log" TD_LOG="$TEST_ROOT/td-reevaluate.log" \
  respond 'Use option A' >/dev/null 2>&1

# new-window should be called (drain lifted, reevaluation proceeds)
grep -qF 'new-window' "$TEST_ROOT/drain-reevaluate.log" || {
  printf 'reevaluate: new-window should be called after undrain\n' >&2; exit 1
}
[[ "$(cat "$repo_state/pane")" == "%88" ]] || {
  printf 'reevaluate: pane should be updated to %%88\n' >&2; exit 1
}
# drain_held cleared
[[ ! -f "$repo_state/drain_held" ]] || {
  printf 'reevaluate: drain_held should be cleared after relaunch\n' >&2; exit 1
}
printf 'sgt-respond drain_held reevaluation relaunches after undrain: ok\n'

_reset_worker

# ── Slice 5: drain_held mismatch — stale drain_held does not unlock wrong gen ─
# If drain_held generation doesn't match current gate generation, treat as
# a concurrent relaunch attempt and fail closed.

printf 'needs_input\n' > "$repo_state/status"
printf 'needs_input\n' > "$worktree/.sergeant-status"
printf '2\n' > "$worktree/.sergeant-gate-generation"
# Pre-populate stored response from generation 1 (stale)
printf 'old response' > "$repo_state/response"
old_response_id="$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
printf '1\n' > "$repo_state/response_generation"
printf '%s\n' "$old_response_id" > "$repo_state/response_id"
cp "$repo_state/response" "$worktree/.sergeant-response"
printf '1\n' > "$worktree/.sergeant-response-generation"
printf '%s\n' "$old_response_id" > "$worktree/.sergeant-response-id"
# drain_held from generation 1 (stale vs current gen 2)
printf '1\n' > "$repo_state/drain_held"
# No drain active

set +e
PATH="$fake_bin:$PATH" PANE_ALIVE=1 PANE_IDENTITY='bash:other-worker' \
  EXPECTED_WORKER="$repo_state" \
  respond 'new response' >/dev/null 2>&1
mismatch_status=$?
set -e
# Should fail: gate generation mismatch
[[ "$mismatch_status" -ne 0 ]] || {
  printf 'drain_held mismatch: should refuse when gate generation does not match drain_held\n' >&2
  exit 1
}
printf 'sgt-respond drain_held generation mismatch fails closed: ok\n'

printf 'sgt-respond drain: all tests passed\n'
