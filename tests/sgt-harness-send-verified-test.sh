#!/usr/bin/env bash
# Regression for GH #114 (reopened) / GH #229: notification delivery must be
# proven, not assumed.
#
# Seam under test: _sgt_harness_send_verified in bin/_sgt-harness.sh, exercised
# against a fake tmux so it needs no real server and cannot touch the developer's
# session (td-be53d1).
#
# Why this exists.  `tmux send-keys` reports success once tmux has handed the
# bytes to the pane's terminal; it says nothing about whether the program running
# there consumed them.  Measured against opencode 1.18.18 in an isolated tmux
# server:
#
#   * keys sent at t=0, before the TUI drew anything, were LOST PERMANENTLY --
#     not queued.  The pane showed no trace of them and no model turn ran, still
#     true 45 seconds later.
#   * keys sent once the first glyph was on screen were accepted and the turn
#     completed in about 4 seconds.
#
# The notification loop used to send the payload, press Enter, and record
# `delivered` without ever checking the text arrived.  Worse, `accepted` is
# written BEFORE the send, so a lost payload advanced the state machine and was
# never retried -- the worker then sat with no prompt until the acknowledgement
# timeout removed its pane, producing "interactive opencode session exited before
# terminal completion, exit code 0".  That reported symptom is a lost keystroke,
# not a crash.
#
# This is deliberately not a settle-time constant.  The reporter's 45s and the
# 2.4s measured here are machine- and version-dependent, so any fixed delay is
# either too short (silent loss) or a tax on every dispatch.  Verification is
# correct whichever harness or version draws when.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export SERGEANT_CONFIG="$TEST_ROOT/config"
export SERGEANT_DRAIN_DIR="$TEST_ROOT/drain"
export SERGEANT_FLEET="$TEST_ROOT/fleet"
export TMUX_TMPDIR="$TEST_ROOT/tmux"
mkdir -p "$SERGEANT_CONFIG" "$SERGEANT_DRAIN_DIR" "$SERGEANT_FLEET" "$TMUX_TMPDIR" \
  "$TEST_ROOT/bin"

PASS=0; FAIL=0
_pass() { PASS=$(( PASS + 1 )); printf 'PASS: %s\n' "$1"; }
_fail() { FAIL=$(( FAIL + 1 )); printf 'FAIL: %s\n' "$1" >&2; }

# Fake tmux.  PANE_CONTENT_FILE is what capture-pane returns; SEND_LOG records
# every send-keys.  ECHO_AFTER_N makes the pane start echoing only after N
# capture attempts, modelling a TUI whose input surface comes up late.
cat > "$TEST_ROOT/bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  send-keys)
    shift
    text=""
    for a in "$@"; do text="$a"; done
    printf '%s\n' "$text" >> "$SEND_LOG"
    if [[ "${ECHO_AFTER_N:-0}" -eq 0 ]]; then
      printf '%s\n' "$text" >> "$PANE_CONTENT_FILE"
    else
      printf '%s\n' "$text" > "$TEST_ROOT/pending-echo"
    fi
    exit 0
    ;;
  capture-pane)
    if [[ -n "${ECHO_AFTER_N:-}" && "${ECHO_AFTER_N}" -gt 0 ]]; then
      n=0; [[ -f "$TEST_ROOT/capture-count" ]] && n="$(cat "$TEST_ROOT/capture-count")"
      n=$(( n + 1 )); printf '%s\n' "$n" > "$TEST_ROOT/capture-count"
      if [[ "$n" -ge "${ECHO_AFTER_N}" && -f "$TEST_ROOT/pending-echo" ]]; then
        cat "$TEST_ROOT/pending-echo" >> "$PANE_CONTENT_FILE"
        rm -f "$TEST_ROOT/pending-echo"
      fi
    fi
    cat "$PANE_CONTENT_FILE" 2>/dev/null
    exit 0
    ;;
esac
exit 0
EOF
chmod +x "$TEST_ROOT/bin/tmux"
export PATH="$TEST_ROOT/bin:$PATH"
export SEND_LOG="$TEST_ROOT/send.log"
export PANE_CONTENT_FILE="$TEST_ROOT/pane.txt"
export TEST_ROOT
export SGT_HARNESS_SEND_VERIFY_INTERVAL=0.01

# shellcheck source=bin/_sgt-harness.sh
source "$ROOT_DIR/bin/_sgt-harness.sh"

PAYLOAD='Sergeant notification abc123 is available in .sergeant-notification. Read it now.'

# ── 1. A live input surface: delivery is confirmed ───────────────────────────
: > "$PANE_CONTENT_FILE"; : > "$SEND_LOG"; unset ECHO_AFTER_N
if _sgt_harness_send_verified '%9' "$PAYLOAD"; then
  _pass "confirms delivery when the pane echoes the payload"
else
  _fail "reported failure for a pane that did echo the payload"
fi

# ── 2. A dead input surface: delivery is NOT claimed ─────────────────────────
# This is the GH #114 case. Previously send-keys returned 0 here and the caller
# pressed Enter and recorded `delivered`, losing the notification silently.
: > "$PANE_CONTENT_FILE"; : > "$SEND_LOG"
export ECHO_AFTER_N=99999          # never echoes within the probe budget
SGT_HARNESS_SEND_VERIFY_TRIES=3 _sgt_harness_send_verified '%9' "$PAYLOAD" \
  && { _fail "claimed delivery for a pane that swallowed the payload"; } \
  || { _pass "refuses to claim delivery when the payload never appears"; }
unset ECHO_AFTER_N
rm -f "$TEST_ROOT/capture-count" "$TEST_ROOT/pending-echo"

# ── 3. It really did attempt the send ────────────────────────────────────────
if grep -Fq "${PAYLOAD:0:24}" "$SEND_LOG"; then
  _pass "the payload was actually sent, not merely reported"
else
  _fail "no send-keys was issued"
fi

# ── 4. A late input surface is tolerated, not failed ─────────────────────────
# A TUI that comes up slowly must succeed once it does, otherwise the fix trades
# silent loss for spurious failure.
: > "$PANE_CONTENT_FILE"; : > "$SEND_LOG"
rm -f "$TEST_ROOT/capture-count"
export ECHO_AFTER_N=3
if SGT_HARNESS_SEND_VERIFY_TRIES=20 _sgt_harness_send_verified '%9' "$PAYLOAD"; then
  _pass "waits for a slow input surface instead of failing early"
else
  _fail "gave up on an input surface that came up late"
fi
unset ECHO_AFTER_N
rm -f "$TEST_ROOT/capture-count" "$TEST_ROOT/pending-echo"

# ── 5. Refuses an empty pane id or empty payload ─────────────────────────────
_sgt_harness_send_verified '' "$PAYLOAD" && _fail "accepted an empty pane id" \
  || _pass "refuses an empty pane id"
_sgt_harness_send_verified '%9' '' && _fail "accepted an empty payload" \
  || _pass "refuses an empty payload"

# ── 6. Matching is on a bounded head, so pane wrapping cannot defeat it ──────
# tmux wraps long lines at the pane width, so the full payload is never
# contiguous in a capture. Only a short head is.
: > "$PANE_CONTENT_FILE"; : > "$SEND_LOG"; unset ECHO_AFTER_N
printf '%s\n' "${PAYLOAD:0:24}" > "$PANE_CONTENT_FILE"
if SGT_HARNESS_SEND_VERIFY_TRIES=3 _sgt_harness_send_verified '%9' "$PAYLOAD"; then
  _pass "matches on a bounded head, surviving pane line wrapping"
else
  _fail "required the whole payload contiguous, which wrapping prevents"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
