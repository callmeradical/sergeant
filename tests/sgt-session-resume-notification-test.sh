#!/usr/bin/env bash
# Regression: sgt-session-resume must not time out with the
# "Resumed worker notification timed out" error when the resumed worker
# is compatible and acknowledges its notification.
#
# Before PR #246, _deliver_notifications only wrote targets/<nonce>/delivered
# after complete_path appeared (full action done). _sgt_wait_worker_notification
# polls delivered+accepted with a 60-second timeout — its documented contract is
# the DELIVERY handshake only, not action completion. Any real task takes longer
# than 60s, so session-resume always timed out with all ack/accept/complete
# directories empty. Confirmed by @mrtnebrle after upgrading to 0.17082026.1.
#
# Seam under test: sgt-session-resume end-to-end — specifically the path:
#   sgt-session-resume
#     → sgt-interactive-worker (tmux pane)
#       → _deliver_notifications (background)
#         → sends notification prompt to pane
#         → writes accepted / delivered after agent writes ack_path
#     → _sgt_wait_worker_notification (60s timeout poll)
#       must return 0 BEFORE the agent writes complete_path
#
# Requires: tmux, git, yq, python3

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT_DIR/bin"
TEST_ROOT="$(mktemp -d)"
TMUX_SESSION="sgt-resume-notification-test-$$"

trap 'tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true; rm -rf "$TEST_ROOT"' EXIT

# ── Dependency checks ─────────────────────────────────────────────────────────
command -v tmux    >/dev/null 2>&1 || { printf 'tmux is required\n' >&2; exit 1; }
command -v git     >/dev/null 2>&1 || { printf 'git is required\n'  >&2; exit 1; }
command -v yq      >/dev/null 2>&1 || { printf 'yq is required\n'   >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { printf 'python3 is required\n' >&2; exit 1; }

# ── Isolation ─────────────────────────────────────────────────────────────────
export SERGEANT_FLEET="$TEST_ROOT/fleet"
export SERGEANT_CONFIG="$TEST_ROOT/config"
export SERGEANT_DRAIN_DIR="$TEST_ROOT/drain"
export TMUX_TMPDIR="$TEST_ROOT/tmux"
export HOME="$TEST_ROOT/home"
export SGT_WIKI_DISABLED=1
export SGT_TEST_HOOKS=1
# Zero settle so the harness readiness gate fires on first glyph (test speed).
export SGT_HARNESS_SETTLE_SECONDS=0
# Short ack timeout: must succeed well inside 15s; default is 60s.
export SGT_NOTIFICATION_ACK_TIMEOUT=15

mkdir -p "$SERGEANT_FLEET" "$SERGEANT_CONFIG" "$SERGEANT_DRAIN_DIR" \
  "$TMUX_TMPDIR" "$HOME" "$TEST_ROOT/fake-bin" "$TEST_ROOT/worktree"

# ── Fake config (sgt-session-resume loads global config via _sgt-lib.sh) ─────
cat > "$SERGEANT_CONFIG/config.yaml" <<EOF
dev_root: $TEST_ROOT/home/dev
EOF

# ── Fake opencode binary ──────────────────────────────────────────────────────
# The binary runs inside the tmux pane (as the interactive worker's agent).
# It must:
#   1. Print a glyph immediately so _sgt_harness_ready_tui sees activity.
#   2. Read the initial notification prompt from stdin (injected via send-keys).
#   3. Write ack_path.
#   4. Wait for accept_path from the supervisor.
#   5. Read the acceptance message.
#   6. Write complete_path so the action lease is finalized.
#   7. Set .sergeant-status=done and exit.
#
# REPO_DIR is baked in at test-write time so the binary knows where
# notification_target and notification_id live.
TASK_ID="resume-notification-test"
REPO="ws-lab"
REPO_DIR="$SERGEANT_FLEET/$TASK_ID/$REPO"
mkdir -p "$REPO_DIR"

cat > "$TEST_ROOT/fake-bin/opencode" <<AGENTEOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" ]]; then printf 'opencode 1.18.18\n'; exit 0; fi

# Print immediately — this is the glyph that satisfies _sgt_harness_ready_tui.
printf 'Agent ready\\n'

# Read the initial notification prompt sent by _deliver_notifications.
# The prompt arrives only after the harness is ready (settle=0 means fast).
IFS= read -r -t 20 _notification_prompt || exit 1

# Discover notification identity from fleet state.
nonce="\$(cat "$REPO_DIR/notification_target" 2>/dev/null || true)"
notification_id="\$(cat "$REPO_DIR/notification_id" 2>/dev/null || true)"
ack_token="\${notification_id}|\${nonce}"

# Write the acknowledgement.
mkdir -p ".sergeant-notification-acks"
printf '%s\n' "\$ack_token" > ".sergeant-notification-acks/\$nonce"

# Wait for supervisor acceptance (written after it sees ack_path).
for _ in \$(seq 1 200); do
  [[ "\$(cat ".sergeant-notification-accepts/\$nonce" 2>/dev/null || true)" == "\$ack_token" ]] && break
  sleep 0.05
done

# Read the acceptance message from the supervisor.
IFS= read -r -t 10 _acceptance_message || true

# Write completion proof — this triggers action-lease finalization.
mkdir -p ".sergeant-notification-complete"
printf '%s\n' "\$ack_token" > ".sergeant-notification-complete/\$nonce"

# Mark done and exit cleanly.
printf 'done\n' > ".sergeant-status"
printf 'https://example.invalid/pr/test\n' > ".sergeant-result"
exit 0
AGENTEOF
chmod +x "$TEST_ROOT/fake-bin/opencode"
export PATH="$TEST_ROOT/fake-bin:$PATH"

# ── Git worktree with at least one commit ─────────────────────────────────────
git -C "$TEST_ROOT/worktree" init -q -b main
git -C "$TEST_ROOT/worktree" -c user.email=t@t -c user.name=t \
  commit -q --allow-empty -m "fixture seed"
git -C "$TEST_ROOT/worktree" remote add origin \
  "git@github.com:example/ws-lab.git" 2>/dev/null || true

# ── Fleet fixture — orphaned task ─────────────────────────────────────────────
mkdir -p "$SERGEANT_FLEET/$TASK_ID"
cat > "$SERGEANT_FLEET/$TASK_ID/brief.md" <<EOF
Project: test
Brief:   configure home assistant
Branch:  feat/configure-ha
Repos:   $REPO
EOF

printf 'orphaned\n'                         > "$REPO_DIR/status"
printf 'feat/configure-ha\n'               > "$REPO_DIR/branch"
printf '%s\n' "$TEST_ROOT/worktree"        > "$REPO_DIR/worktree"
printf 'opencode\n'                        > "$REPO_DIR/agent"
printf 'test\n'                            > "$REPO_DIR/project"
printf 'sgt\n'                             > "$REPO_DIR/tmux_session"
printf '%%99999\n'                         > "$REPO_DIR/pane"

# Worker process marker (required by _sgt_worker_process_marker_preflight)
old_marker_path="$TEST_ROOT/old-marker"
old_generation=11111111111111111111111111111111
printf '%s\n' "$old_generation" > "$old_marker_path"
chmod 400 "$old_marker_path"
old_identity="$(stat -Lc '%d:%i' "$old_marker_path" 2>/dev/null || \
  stat -f '%d:%i' "$old_marker_path" 2>/dev/null)"
printf '%s|%s|198|%s\n' \
  "$old_generation" "$old_identity" "$old_marker_path" \
  > "$REPO_DIR/worker_process_marker"
chmod 600 "$REPO_DIR/worker_process_marker"
old_launch_floor="$(awk '{ print $22 }' /proc/$$/stat 2>/dev/null || echo 0)"
printf '%s|%s|%s\n' "$old_generation" "$old_identity" "$old_launch_floor" \
  > "$REPO_DIR/worker_process_markers"
chmod 600 "$REPO_DIR/worker_process_markers"

# ── Start a private tmux server ───────────────────────────────────────────────
tmux new-session -d -s "$TMUX_SESSION" -n keepalive \
  "while :; do sleep 1; done"
export TMUX=""      # ensure sgt-session-resume is not inside a pane
export TMUX_PANE="" # likewise

# ── Run sgt-session-resume ────────────────────────────────────────────────────
resume_out="$TEST_ROOT/resume.out"
resume_err="$TEST_ROOT/resume.err"

set +e
"$BIN/sgt-session-resume" "$TASK_ID" "$REPO" \
  > "$resume_out" 2> "$resume_err"
resume_rc=$?
set -e

# ── Assertions ────────────────────────────────────────────────────────────────
pass=0
fail=0
_pass() { printf 'PASS: %s\n' "$1"; pass=$(( pass + 1 )); }
_fail() { printf 'FAIL: %s (%s)\n' "$1" "${2:-}" >&2; fail=$(( fail + 1 )); }

# 1. sgt-session-resume exits 0 (no timeout, no orphan).
if [[ "$resume_rc" -eq 0 ]]; then
  _pass "sgt-session-resume exits 0 — notification handshake completed within timeout"
else
  combined="$(cat "$resume_out" "$resume_err" 2>/dev/null)"
  _fail "sgt-session-resume exited $resume_rc" "$(printf '%s' "$combined" | tail -5)"
fi

# 2. Fleet status must not be orphaned after a successful resume.
final_status="$(cat "$REPO_DIR/status" 2>/dev/null || true)"
if [[ "$final_status" != "orphaned" ]]; then
  _pass "fleet status is not orphaned after resume ($final_status)"
else
  _fail "fleet status is orphaned — resume did not complete cleanly"
fi

# 3. Notification target dir must have delivered and accepted.
nonce="$(cat "$REPO_DIR/notification_target" 2>/dev/null || true)"
notification_id="$(cat "$REPO_DIR/notification_id" 2>/dev/null || true)"
target_dir="$REPO_DIR/notifications/$notification_id/targets/$nonce"

if [[ -f "$target_dir/delivered" ]]; then
  _pass "notification target has delivered marker"
else
  _fail "notification target missing delivered marker" \
    "target_dir=$target_dir contents=$(ls "$target_dir" 2>/dev/null | tr '\n' ' ')"
fi

if [[ -f "$target_dir/accepted" ]]; then
  _pass "notification target has accepted marker"
else
  _fail "notification target missing accepted marker"
fi

# 4. Handshake proof must be present (written by _sgt_wait_worker_notification).
if [[ -f "$target_dir/handshake_complete" ]]; then
  _pass "handshake_complete written — _sgt_wait_worker_notification confirmed delivery"
else
  _fail "handshake_complete absent — _sgt_wait_worker_notification may have timed out"
fi

# 5. Resume must not emit the timeout error message.
combined_out="$(cat "$resume_out" "$resume_err" 2>/dev/null)"
if [[ "$combined_out" != *"timed out"* ]]; then
  _pass "no timeout error in sgt-session-resume output"
else
  _fail "timeout error present in output" "$(printf '%s' "$combined_out" | grep 'timed out')"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
