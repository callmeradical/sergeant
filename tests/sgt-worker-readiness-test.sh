#!/usr/bin/env bash
# Regression: the interactive worker's readiness wait is bounded and reported
# (td-ed15d5 / GH #175 AC4), and a harness that reaches its pane without ever
# acknowledging is NOT misrecorded as orphaned (GH #175 AC5).
#
# Before this, bin/sgt-interactive-worker:257-260 looped forever on
# `_harness_ready || { sleep; continue; }` with no bound and no report, so a
# harness whose readiness could never be satisfied produced a silently spinning
# worker and, at exit, a misleading `orphaned` record.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"

# ── Drain state isolation (td-79f0a8) ────────────────────────────────────────
# Commands exercised here source bin/_sgt-drain.sh, which resolves
# SERGEANT_DRAIN_DIR, else SERGEANT_CONFIG/drain, else the operator's real
# $HOME/.config/sergeant/drain.  Pin it to this suite's temporary root so the
# tests never consult — or mutate — live drain state.
export SERGEANT_DRAIN_DIR="$TEST_ROOT/drain"
export SERGEANT_CONFIG="$TEST_ROOT/sergeant-config"
mkdir -p "$SERGEANT_DRAIN_DIR" "$SERGEANT_CONFIG"
TMUX_SESSION="sgt-worker-readiness-test-$$"
# Run against a private tmux server.  Sharing the developer's server makes these
# tests contend with every other pane on it — including ones leaked by other
# suites — which turns pane operations slow enough to blow the per-test budget,
# and it leaks panes back the other way.  Child `tmux` calls inside the worker
# follow $TMUX, so they reach this same private server.
export TMUX_TMPDIR="$TEST_ROOT/tmux"
mkdir -p "$TMUX_TMPDIR"

trap 'tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true; rm -rf "$TEST_ROOT"' EXIT

command -v tmux >/dev/null 2>&1 || {
  printf 'tmux is required for the bounded readiness regression\n' >&2
  exit 1
}

mkdir -p "$TEST_ROOT/fake-bin" "$TEST_ROOT/state" "$TEST_ROOT/worktree"

# A harness that starts, renders absolutely nothing, and stays alive.  Readiness
# can therefore never be satisfied, which is exactly the unreachable state the
# bound has to report.
cat > "$TEST_ROOT/fake-bin/claude" <<'EOF'
#!/usr/bin/env bash
touch "$HARNESS_STARTED_FILE"
while :; do sleep 1; done
EOF
chmod +x "$TEST_ROOT/fake-bin/claude"

state="$TEST_ROOT/state"
worktree="$TEST_ROOT/worktree"

printf 'in_progress\n' > "$worktree/.sergeant-status"
printf '1\n' > "$worktree/.sergeant-gate-generation"
printf 'unreachable-readiness-1\n' > "$state/notification_id"
cat > "$worktree/.sergeant-notification" <<'EOF'
notification_id=unreachable-readiness-1
kind=initial
instruction=Read the .sergeant-brief.md file and execute the mission.
EOF

tmux new-session -d -s "$TMUX_SESSION" -n keepalive "while :; do sleep 1; done"
tmux new-window -d -t "$TMUX_SESSION:" -n unreachable \
  "env HARNESS_STARTED_FILE='$TEST_ROOT/harness-started' \
  SGT_NOTIFICATION_RETRY_INTERVAL=0.02 \
  SGT_HARNESS_READY_TIMEOUT=1 \
  SGT_HARNESS_SETTLE_SECONDS=0 \
  SGT_PROGRESS_INTERVAL=600 \
  SGT_DRAIN_CHECK_INTERVAL=600 \
  '$ROOT_DIR/bin/sgt-interactive-worker' '$state' '$worktree' \
  '$TEST_ROOT/fake-bin/claude'"

pane="$(tmux display-message -p -t "$TMUX_SESSION:unreachable" '#{pane_id}')"
identity="$(tmux display-message -p -t "$pane" \
  '#{pane_dead}|#{pane_id}|#{pane_pid}|#{pane_created}|#{pane_start_command}')"
printf '%s\n' "$pane" > "$state/pane"
printf '%s\n' "$identity" > "$state/pane_identity"
nonce="$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
target_dir="$state/notifications/unreachable-readiness-1/targets/$nonce"
mkdir -p "$target_dir"
printf '%s\n' "$identity" > "$target_dir/pane_identity"
printf '%s\n' "$nonce" > "$state/notification_target"

for _ in $(seq 1 500); do
  [[ -e "$TEST_ROOT/harness-started" ]] && break
  sleep 0.02
done
[[ -e "$TEST_ROOT/harness-started" ]] || {
  printf 'fake harness never started\n' >&2
  exit 1
}

# ── 1. The unreachable readiness state is reported within the bound ───────────

for _ in $(seq 1 1000); do
  [[ -f "$target_dir/readiness_failed" ]] && break
  sleep 0.02
done
[[ -f "$target_dir/readiness_failed" ]] || {
  printf 'readiness never became bounded; no readiness_failed evidence was published\n' >&2
  printf 'state dir:\n%s\n' "$(find "$state" -type f | sed 's/^/  /')" >&2
  exit 1
}
grep -Fq 'unreachable-readiness-1' "$target_dir/readiness_failed" || {
  printf 'readiness_failed evidence does not name the notification:\n%s\n' \
    "$(cat "$target_dir/readiness_failed")" >&2
  exit 1
}

# ── 2. A diagnostic names the harness and the readiness bound ─────────────────

for _ in $(seq 1 500); do
  [[ -s "$state/diagnostic" ]] && break
  sleep 0.02
done
grep -Fq 'readiness' "$state/diagnostic" || {
  printf 'diagnostic does not report the readiness failure:\n%s\n' \
    "$(cat "$state/diagnostic" 2>/dev/null || true)" >&2
  exit 1
}
grep -Fq 'claude' "$state/diagnostic" || {
  printf 'diagnostic does not name the harness:\n%s\n' "$(cat "$state/diagnostic")" >&2
  exit 1
}

# ── 3. Nothing was fabricated: no ack, accept, lease, delivery or completion ──

for artefact in acknowledged accepted delivered completed; do
  [[ ! -e "$target_dir/$artefact" ]] || {
    printf 'readiness failure fabricated %s evidence\n' "$artefact" >&2
    exit 1
  }
done
[[ ! -e "$state/notifications/unreachable-readiness-1/action_lease" ]] || {
  printf 'readiness failure took an action lease\n' >&2
  exit 1
}
[[ ! -e "$worktree/.sergeant-notification-accepts/$nonce" ]] || {
  printf 'readiness failure published an acceptance to the worktree\n' >&2
  exit 1
}

# ── 4. The worker is recoverable, not orphaned ───────────────────────────────

for _ in $(seq 1 500); do
  [[ "$(cat "$state/status" 2>/dev/null || true)" == "needs_input" ]] && break
  sleep 0.02
done
[[ "$(cat "$state/status")" == "needs_input" ]] || {
  printf 'unreachable readiness did not publish a recoverable gate, status=%s\n' \
    "$(cat "$state/status" 2>/dev/null || true)" >&2
  exit 1
}
[[ "$(cat "$worktree/.sergeant-status")" == "needs_input" ]]

# The gate generation must have advanced so the blocker is a new gate.
[[ "$(cat "$worktree/.sergeant-gate-generation")" == "2" ]] || {
  printf 'gate generation did not advance for the readiness gate: %s\n' \
    "$(cat "$worktree/.sergeant-gate-generation")" >&2
  exit 1
}
grep -Fq 'readiness' "$worktree/.sergeant-message" || {
  printf 'operator message does not explain the readiness blocker:\n%s\n' \
    "$(cat "$worktree/.sergeant-message" 2>/dev/null || true)" >&2
  exit 1
}

# ── 5. The report happens exactly once, not on every poll ────────────────────

first_report="$(cat "$target_dir/readiness_failed")"
sleep 0.5
[[ "$(cat "$target_dir/readiness_failed")" == "$first_report" ]] || {
  printf 'readiness failure evidence was rewritten on a later poll\n' >&2
  exit 1
}
[[ "$(cat "$worktree/.sergeant-gate-generation")" == "2" ]] || {
  printf 'readiness gate generation advanced more than once: %s\n' \
    "$(cat "$worktree/.sergeant-gate-generation")" >&2
  exit 1
}

# ── 6. Exiting with an unacknowledged handshake is not recorded as orphaned ──

tmux kill-window -t "$TMUX_SESSION:unreachable" 2>/dev/null || true
sleep 0.5
[[ "$(cat "$state/status")" != "orphaned" ]] || {
  printf 'a harness that never acknowledged was misrecorded as orphaned\n' >&2
  exit 1
}

printf 'bounded interactive worker readiness: ok\n'
