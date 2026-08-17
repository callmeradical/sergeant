#!/usr/bin/env bash
# Regression test for GH #114 / GH #229 / PR #242:
# Notification delivery and acceptance retry contract.
#
# Proves:
# 1. Settle time in _sgt_harness_settle_seconds defaults to at least 2 seconds.
# 2. Supervisor sends initial notification and waits for .sergeant-notification-acks/<nonce>.
# 3. Supervisor delivers acceptance to .sergeant-notification-accepts/<nonce> and sends message to tmux pane.
# 4. Supervisor finalizes delivery once .sergeant-notification-complete/<nonce> is written.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export SERGEANT_CONFIG="$TEST_ROOT/config"
export SERGEANT_DRAIN_DIR="$TEST_ROOT/drain"
export SERGEANT_FLEET="$TEST_ROOT/fleet"
export TMUX_TMPDIR="$TEST_ROOT/tmux"
mkdir -p "$SERGEANT_CONFIG" "$SERGEANT_DRAIN_DIR" "$SERGEANT_FLEET" "$TMUX_TMPDIR" "$TEST_ROOT/bin"

PASS=0
FAIL=0
_pass() { PASS=$(( PASS + 1 )); printf 'PASS: %s\n' "$1"; }
_fail() { FAIL=$(( FAIL + 1 )); printf 'FAIL: %s (%s)\n' "$1" "${2:-}" >&2; }

# shellcheck source=bin/_sgt-lib.sh
source "$ROOT_DIR/bin/_sgt-lib.sh"
# shellcheck source=bin/_sgt-harness.sh
source "$ROOT_DIR/bin/_sgt-harness.sh"

# ── 1. Default settle seconds is non-zero (prevents t=0 keystroke loss) ───────

settle="$(_sgt_harness_settle_seconds)"
if [[ "$settle" -ge 2 ]]; then
  _pass "default settle time is at least 2s for TUI harnesses ($settle seconds)"
else
  _fail "default settle time is too short ($settle seconds; expected >= 2s)"
fi

# ── 2. Notification delivery and acceptance handshake ─────────────────────────

WORKTREE="$TEST_ROOT/worktree"
REPO_STATE="$TEST_ROOT/repo_state"
mkdir -p "$WORKTREE" "$REPO_STATE"

notification_id="$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
nonce="$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
ack_token="$notification_id|$nonce"
target_dir="$REPO_STATE/notifications/$notification_id/targets/$nonce"
mkdir -p "$target_dir"

printf '%s\n' "$notification_id" > "$REPO_STATE/notification_id"
printf '%s\n' "$nonce" > "$REPO_STATE/notification_target"
printf 'notification_id=%s\n' "$notification_id" > "$WORKTREE/.sergeant-notification"

FAKE_PANE="%99"
printf '0|%s|12345|100000|opencode\n' "$FAKE_PANE" > "$target_dir/pane_identity"
printf '0|%s|12345|100000|opencode\n' "$FAKE_PANE" > "$REPO_STATE/pane_identity"

SEND_LOG="$TEST_ROOT/send.log"
: > "$SEND_LOG"

cat > "$TEST_ROOT/bin/tmux" <<EOF
#!/usr/bin/env bash
case "\$1" in
  display-message)
    shift
    pane="$FAKE_PANE"
    format=""
    while [[ \$# -gt 0 ]]; do
      case "\$1" in
        -t) pane="\$2"; shift 2 ;;
        -p) shift ;;
        *) format="\$1"; shift ;;
      esac
    done
    if [[ "\$format" == *'#{pane_id}|#{pane_dead}'* ]]; then
      printf '%s|0\n' "\$pane"
    else
      printf '0|%s|12345|100000|opencode\n' "\$pane"
    fi
    exit 0
    ;;
  capture-pane)
    printf 'Ask anything...\n'
    exit 0
    ;;
  send-keys)
    shift
    printf '%s\n' "\$*" >> "$SEND_LOG"
    exit 0
    ;;
esac
exit 0
EOF
chmod +x "$TEST_ROOT/bin/tmux"
export PATH="$TEST_ROOT/bin:$PATH"

# Fake agent binary that simulates an interactive agent named opencode
cat > "$TEST_ROOT/bin/opencode" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  printf 'opencode 1.18.18\n'
  exit 0
fi
while [[ ! -f "$TEST_ROOT/agent-exit" ]]; do
  sleep 0.05
done
exit 0
EOF
chmod +x "$TEST_ROOT/bin/opencode"

# Run interactive worker in a simulated terminal environment
export TMUX_PANE="$FAKE_PANE"
export SGT_NOTIFICATION_RETRY_INTERVAL=0.02
export SGT_HARNESS_SETTLE_SECONDS=0
export SGT_TEST_HOOKS=1

# Start sgt-interactive-worker
(
  exec "$ROOT_DIR/bin/sgt-interactive-worker" "$REPO_STATE" "$WORKTREE" "$TEST_ROOT/bin/opencode" > "$TEST_ROOT/worker.log" 2>&1
) &
WORKER_PID=$!
trap 'touch "$TEST_ROOT/agent-exit" 2>/dev/null || true; kill "$WORKER_PID" 2>/dev/null || true; rm -rf "$TEST_ROOT"' EXIT

# Step 1: Prove initial notification prompt was sent
for _ in $(seq 1 100); do
  [[ -s "$SEND_LOG" ]] && break
  sleep 0.02
done

initial_sends="$(grep -c 'is available in .sergeant-notification' "$SEND_LOG" || true)"
if [[ "$initial_sends" -ge 1 ]]; then
  _pass "supervisor sent initial notification prompt ($initial_sends attempt(s))"
else
  _fail "supervisor did not send initial notification prompt"
fi

# Step 2: Agent writes acknowledgement
ack_path="$WORKTREE/.sergeant-notification-acks/$nonce"
mkdir -p "$(dirname "$ack_path")"
printf '%s\n' "$ack_token" > "$ack_path"

# Step 3: Prove supervisor publishes acceptance and sends acceptance message
accept_path="$WORKTREE/.sergeant-notification-accepts/$nonce"
for _ in $(seq 1 100); do
  [[ -f "$accept_path" && "$(cat "$accept_path")" == "$ack_token" ]] && break
  sleep 0.02
done

if [[ -f "$accept_path" && "$(cat "$accept_path")" == "$ack_token" ]]; then
  _pass "supervisor published acceptance to .sergeant-notification-accepts/$nonce"
else
  _fail "supervisor failed to publish acceptance to $accept_path"
fi

acceptance_sends="$(grep -c 'Sergeant accepted' "$SEND_LOG" || true)"
if [[ "$acceptance_sends" -ge 1 ]]; then
  _pass "supervisor sent acceptance message to tmux pane ($acceptance_sends attempt(s))"
else
  _fail "supervisor did not send acceptance message to pane"
fi

# Step 4: Supervisor records delivered BEFORE the agent writes complete proof.
# _sgt_wait_worker_notification polls for delivered+accepted; it must return
# within the 60s delivery timeout so sgt-dispatch and sgt-session-resume can
# confirm the handshake before the agent has even started work.  Regression
# check: delivered must appear right after acceptance, not after complete_path.
for _ in $(seq 1 100); do
  [[ -f "$target_dir/delivered" ]] && break
  sleep 0.02
done

if [[ -f "$target_dir/delivered" && "$(cat "$target_dir/delivered")" == "$ack_token" ]]; then
  _pass "supervisor recorded delivery proof before agent writes complete_path"
else
  _fail "supervisor did not record delivery proof after acceptance (regression: delivered tied to complete_path)"
fi

# Step 5: Agent writes complete proof; supervisor finalizes the action lease.
complete_path="$WORKTREE/.sergeant-notification-complete/$nonce"
mkdir -p "$(dirname "$complete_path")"
printf '%s\n' "$ack_token" > "$complete_path"

for _ in $(seq 1 100); do
  [[ -f "$target_dir/completed" ]] && break
  sleep 0.02
done

if [[ -f "$target_dir/completed" && "$(cat "$target_dir/completed")" == "$ack_token" ]]; then
  _pass "supervisor finalized action lease after agent wrote complete_path"
else
  _fail "supervisor did not finalize action lease after complete_path"
fi

touch "$TEST_ROOT/agent-exit"
kill "$WORKER_PID" 2>/dev/null || true

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
