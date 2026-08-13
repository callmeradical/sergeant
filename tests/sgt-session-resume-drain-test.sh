#!/usr/bin/env bash
# Tests that sgt-session-resume honours the cooperative drain contract.
#
# Seam under test:
#   sgt-session-resume <task-id> <repo>   relaunches a worker pane
#
# sgt-dispatch, sgt-respond and sgt-recover all take drain admission before
# spawning a worker: while a drain is active, workers finish their current turn
# and exit, and nothing new starts. A resume spawns a worker by exactly the
# same mechanism (tmux new-window running sgt-interactive-worker), so an
# ungated resume silently defeats the drain.
#
# Isolation: fleet root, drain directory, config root, HOME and the tmux server
# are all redirected into a scratch directory. The assertion that no tmux
# server was started doubles as proof that the isolation held.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT_DIR/bin"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export SERGEANT_FLEET="$TEST_ROOT/fleet"
export SERGEANT_CONFIG="$TEST_ROOT/config"
export SERGEANT_DRAIN_DIR="$TEST_ROOT/drain"
export TMUX_TMPDIR="$TEST_ROOT/tmux"
export HOME="$TEST_ROOT/home"
mkdir -p "$SERGEANT_FLEET" "$SERGEANT_CONFIG" "$SERGEANT_DRAIN_DIR" "$TMUX_TMPDIR" \
  "$HOME" "$TEST_ROOT/fake-bin"
cat > "$TEST_ROOT/fake-bin/opencode" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEST_ROOT/fake-bin/opencode"
export PATH="$TEST_ROOT/fake-bin:$PATH"
unset TMUX

pass=0
fail=0
_pass() { printf '  ok: %s\n' "$*"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n' "$*" >&2; fail=$((fail + 1)); }

TASK_ID="drain-probe-a1b2c3"
REPO="demo"
PROJECT="demoproject"
TASK_DIR="$SERGEANT_FLEET/$TASK_ID"
REPO_DIR="$TASK_DIR/$REPO"
WORKTREE="$TEST_ROOT/worktree"

# ── Fixture: a fleet record whose worker pane is gone ────────────────────────
mkdir -p "$REPO_DIR" "$WORKTREE"
git -C "$WORKTREE" init -q -b main
git -C "$WORKTREE" -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed

printf 'Project: %s\nBrief: probe\nBranch: feat/probe\nRepos: %s\n' "$PROJECT" "$REPO" \
  > "$TASK_DIR/brief.md"
printf 'orphaned\n'      > "$REPO_DIR/status"
printf 'feat/probe\n'    > "$REPO_DIR/branch"
printf '%s\n' "$WORKTREE" > "$REPO_DIR/worktree"
printf 'opencode\n'      > "$REPO_DIR/agent"
printf '%s\n' "$PROJECT" > "$REPO_DIR/project"
printf 'sgt-probe\n'     > "$REPO_DIR/tmux_session"
printf '%%99999\n'       > "$REPO_DIR/pane"
old_marker_path="$TEST_ROOT/old-worker-marker"
old_generation=11111111111111111111111111111111
printf '%s\n' "$old_generation" > "$old_marker_path"
chmod 400 "$old_marker_path"
old_marker_identity="$(stat -Lc '%d:%i' "$old_marker_path")"
old_marker_record="$old_generation|$old_marker_identity|198|$old_marker_path"
printf '%s\n' "$old_marker_record" > "$REPO_DIR/worker_process_marker"
chmod 600 "$REPO_DIR/worker_process_marker"
printf '%s|%s|0\n' "$old_generation" "$old_marker_identity" \
  > "$REPO_DIR/worker_process_markers"
chmod 600 "$REPO_DIR/worker_process_markers"

_tmux_server_started() {
  # Any socket under the isolated TMUX_TMPDIR means a server was created.
  [[ -n "$(find "$TMUX_TMPDIR" -type s 2>/dev/null | head -1)" ]]
}

# ── Baseline: with no drain, the gate must not block ─────────────────────────
# Proves the refusal below is caused by the drain and not by fixture shape.
# The resume is expected to fail later (no real agent), just not at the gate.
set +e
baseline="$(SGT_NOTIFICATION_ACK_TIMEOUT=0 \
  "$BIN/sgt-session-resume" "$TASK_ID" "$REPO" --force 2>&1)"
set -e
if grep -qi 'held by drain' <<<"$baseline"; then
  _fail "undrained resume passes the drain gate"
else
  _pass "undrained resume passes the drain gate"
fi
if [[ "$(cat "$REPO_DIR/worker_process_marker")" != "$old_marker_record" ]]; then
  _pass "resume publishes a fresh worker marker generation"
else
  _fail "resume publishes a fresh worker marker generation"
fi
# Reset anything the baseline attempt changed.
printf 'orphaned\n' > "$REPO_DIR/status"
tmux -f /dev/null kill-server 2>/dev/null || true
rm -rf "${TMUX_TMPDIR:?}"/* 2>/dev/null || true

# ── Drain active: resume must be refused ─────────────────────────────────────

"$BIN/sgt-drain" --global --reason "resume gate test" >/dev/null 2>&1 \
  || _fail "could not activate a global drain for the test"

set +e
out="$("$BIN/sgt-session-resume" "$TASK_ID" "$REPO" --force 2>&1)"
rc=$?
set -e

# Exit 4 specifically, not merely non-zero: an ungated resume also fails here,
# but on a downstream notification timeout. Only the documented drain-held code
# distinguishes "refused at the gate" from "attempted and broke later".
if [[ $rc -eq 4 ]]; then
  _pass "resume exits 4 (drain held) while a global drain is active"
else
  _fail "resume exits 4 (drain held) while a global drain is active (got $rc: $(head -1 <<<"$out"))"
fi

if grep -q 'held by drain' <<<"$out"; then
  _pass "refusal reports the resume was held by drain"
else
  _fail "refusal reports the resume was held by drain (got: $(head -2 <<<"$out"))"
fi

if ! _tmux_server_started; then
  _pass "a drained resume starts no tmux server"
else
  _fail "a drained resume starts no tmux server (one was created)"
fi

if [[ "$(cat "$REPO_DIR/status")" == "orphaned" ]]; then
  _pass "a drained resume leaves fleet status untouched"
else
  _fail "a drained resume leaves fleet status untouched (now: $(cat "$REPO_DIR/status"))"
fi

printf '\nsgt-session-resume drain gate: %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
