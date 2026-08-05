#!/usr/bin/env bash
# Per-harness end-to-end notification handshake regression (td-db6323 / GH #175).
#
# tests/sgt-dispatch-worker-test.sh iterates `for agent in goose claude` but only
# asserts that prohibited one-shot forms were avoided and that `agent` was
# recorded.  No test reached .sergeant-notification-acks/<nonce>, acceptance,
# completion, clean exit, or relaunch for ANY harness — which is precisely why
# GH #175 went unnoticed for every harness except opencode.
#
# This drives the real durable handshake, for EVERY harness in the shared
# registry, twice: once for the initial notification and again for a response
# notification delivered to a relaunched worker.  The fake harness parses the ack
# token and both file paths out of the injected nudge text itself, so a change to
# the protocol wording or to the target paths fails the test rather than passing
# on state the harness read behind Sergeant's back.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
TMUX_SESSION="sgt-worker-handshake-test-$$"
trap 'tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true; rm -rf "$TEST_ROOT"' EXIT

command -v tmux >/dev/null 2>&1 || {
  printf 'tmux is required for the per-harness handshake regression\n' >&2
  exit 1
}

# shellcheck source=bin/_sgt-harness.sh
source "$ROOT_DIR/bin/_sgt-harness.sh"

HARNESSES="$(_sgt_harness_names)"
[[ -n "$HARNESSES" ]] || {
  printf 'shared harness registry is empty\n' >&2
  exit 1
}

mkdir -p "$TEST_ROOT/fake-bin"

# One fake harness body, installed under every accepted harness name.  It speaks
# the acknowledgement protocol exactly as bin/.sergeant-brief.md instructs an
# agent to: ack, wait for acceptance, act once, publish completion.
cat > "$TEST_ROOT/fake-bin/_harness-body" <<'HARNESS'
#!/usr/bin/env bash
set -uo pipefail

printf '%s|%s\n' "$#" "$*" > "$ARG_LOG"
# Render something so the readiness probe can observe a drawn interface.  No
# recognisable banner text: readiness must not depend on a presentation string.
printf 'harness %s up\n' "$HARNESS_NAME"

_fail() { printf '%s\n' "$1" > "$FAILURE_LOG"; exit 90; }

IFS= read -r nudge || _fail 'no nudge line was injected'
printf '%s\n' "$nudge" > "$NUDGE_LOG"

token="$(printf '%s' "$nudge" | \
  sed -n 's/.*, write \([^ ][^ ]*\) to \([^ ][^ ]*\), and do not act.*/\1/p')"
ack_path="$(printf '%s' "$nudge" | \
  sed -n 's/.*, write \([^ ][^ ]*\) to \([^ ][^ ]*\), and do not act.*/\2/p')"
[[ -n "$token" && -n "$ack_path" ]] || _fail "unparseable nudge: $nudge"
[[ "$ack_path" == *"/.sergeant-notification-acks/"* ]] || \
  _fail "nudge did not name the acks directory: $ack_path"
nonce="${token#*|}"
[[ "$nonce" =~ ^[a-f0-9]{32}$ ]] || _fail "nudge carried no valid target nonce: $token"

mkdir -p "$(dirname "$ack_path")"
printf '%s\n' "$token" > "$ack_path"
printf '%s\n' "$token" > "$ACK_TOKEN_LOG"

accept_path="$(printf '%s' "$nudge" | \
  sed -n 's/.*supervisor sends acceptance and \([^ ][^ ]*\) contains that token.*/\1/p')"
[[ -n "$accept_path" ]] || _fail "nudge did not name the accepts path: $nudge"
for _ in $(seq 1 2000); do
  [[ "$(cat "$accept_path" 2>/dev/null || true)" == "$token" ]] && break
  sleep 0.02
done
[[ "$(cat "$accept_path" 2>/dev/null || true)" == "$token" ]] || \
  _fail "acceptance never arrived at $accept_path"

acceptance=""
for _ in $(seq 1 200); do
  IFS= read -r -t 1 candidate || break
  if [[ "$candidate" == *"Sergeant accepted $token"* ]]; then
    acceptance="$candidate"
    break
  fi
done
[[ -n "$acceptance" ]] || _fail 'acceptance message was never injected'

complete_path="$(printf '%s' "$acceptance" | \
  sed -n 's/.*then write it to \(.*\)\.$/\1/p')"
[[ -n "$complete_path" ]] || _fail "unparseable acceptance: $acceptance"
[[ "$complete_path" == *"/.sergeant-notification-complete/$nonce" ]] || \
  _fail "acceptance named the wrong completion path: $complete_path"

mkdir -p "$(dirname "$complete_path")"
printf '%s\n' "$token" > "$complete_path"

# Wait for the supervisor to publish durable completion for this exact turn.
for _ in $(seq 1 2000); do
  [[ "$(cat "$COMPLETED_PROOF" 2>/dev/null || true)" == "$token" ]] && break
  sleep 0.02
done
[[ "$(cat "$COMPLETED_PROOF" 2>/dev/null || true)" == "$token" ]] || \
  _fail "supervisor never published completion proof at $COMPLETED_PROOF"

case "${TURN:-initial}" in
  initial)
    # Clean, deliberate nonterminal exit so the turn can be relaunched.
    printf '2\n' > .sergeant-gate-generation
    printf 'Initial turn handshake complete; awaiting a response.\n' > .sergeant-message
    printf 'needs_input\n' > .sergeant-status
    ;;
  response)
    printf 'done\n' > .sergeant-status
    printf 'https://example.invalid/pr/%s\n' "$HARNESS_NAME" > .sergeant-result
    ;;
esac
exit 0
HARNESS
chmod +x "$TEST_ROOT/fake-bin/_harness-body"

while IFS= read -r harness; do
  [[ -n "$harness" ]] || continue
  ln -sf _harness-body "$TEST_ROOT/fake-bin/$harness"
done <<EOF
$HARNESSES
EOF

tmux new-session -d -s "$TMUX_SESSION" -n keepalive "while :; do sleep 1; done"

# publish_target: mirror what sgt-dispatch/sgt-respond do — record the pane
# identity and publish a fresh nonce-addressed notification target.
publish_target() {
  local state="$1" window="$2" notification_id="$3"
  local pane identity nonce target_dir
  pane="$(tmux display-message -p -t "$TMUX_SESSION:$window" '#{pane_id}')"
  identity="$(tmux display-message -p -t "$pane" \
    '#{pane_dead}|#{pane_id}|#{pane_pid}|#{pane_created}|#{pane_start_command}')"
  printf '%s\n' "$pane" > "$state/pane"
  printf '%s\n' "$identity" > "$state/pane_identity"
  printf '%s\n' "$notification_id" > "$state/notification_id"
  nonce="$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  target_dir="$state/notifications/$notification_id/targets/$nonce"
  mkdir -p "$target_dir"
  printf '%s\n' "$identity" > "$target_dir/pane_identity"
  printf '%s\n' "$nonce" > "$state/notification_target"
  printf '%s\n' "$nonce"
}

expected_launch_args() {
  _sgt_harness_launch_args "$1" | tr '\n' ' ' | sed 's/ *$//'
}

run_turn() {
  local harness="$1" turn="$2" kind="$3" notification_id="$4" state="$5" worktree="$6"
  local window nonce target_dir arg_log failure_log nudge_log ack_log expected_count

  window="$harness-$turn"
  arg_log="$TEST_ROOT/$harness.$turn.args"
  failure_log="$TEST_ROOT/$harness.$turn.failure"
  nudge_log="$TEST_ROOT/$harness.$turn.nudge"
  ack_log="$TEST_ROOT/$harness.$turn.token"

  cat > "$worktree/.sergeant-notification" <<EOF
notification_id=$notification_id
kind=$kind
instruction=Read the .sergeant-brief.md file and execute the mission.
EOF

  tmux new-window -d -t "$TMUX_SESSION:" -n "$window" \
    "env HARNESS_NAME='$harness' TURN='$turn' \
    ARG_LOG='$arg_log' FAILURE_LOG='$failure_log' NUDGE_LOG='$nudge_log' \
    ACK_TOKEN_LOG='$ack_log' \
    COMPLETED_PROOF='$TEST_ROOT/$harness.$turn.completed-proof' \
    SGT_NOTIFICATION_RETRY_INTERVAL=0.02 SGT_HARNESS_SETTLE_SECONDS=0 \
    SGT_PROGRESS_INTERVAL=600 SGT_DRAIN_CHECK_INTERVAL=600 \
    '$ROOT_DIR/bin/sgt-interactive-worker' '$state' '$worktree' \
    '$TEST_ROOT/fake-bin/$harness'"

  nonce="$(publish_target "$state" "$window" "$notification_id")"
  target_dir="$state/notifications/$notification_id/targets/$nonce"
  # Tell the harness where to watch for its own completion proof.
  ln -sf "$target_dir/completed" "$TEST_ROOT/$harness.$turn.completed-proof"

  # ── The handshake must reach the acks directory ──────────────────────────────
  for _ in $(seq 1 2000); do
    [[ -f "$worktree/.sergeant-notification-acks/$nonce" ]] && break
    [[ -f "$failure_log" ]] && break
    sleep 0.02
  done
  [[ ! -f "$failure_log" ]] || {
    printf '%s/%s harness reported: %s\n' "$harness" "$turn" "$(cat "$failure_log")" >&2
    exit 1
  }
  [[ "$(cat "$worktree/.sergeant-notification-acks/$nonce")" == "$notification_id|$nonce" ]] || {
    printf '%s/%s never wrote the exact ack token to .sergeant-notification-acks/%s\n' \
      "$harness" "$turn" "$nonce" >&2
    exit 1
  }

  # ── Acceptance is published to the worktree and to fleet state ───────────────
  for _ in $(seq 1 2000); do
    [[ -f "$target_dir/accepted" ]] && break
    sleep 0.02
  done
  [[ "$(cat "$worktree/.sergeant-notification-accepts/$nonce")" == "$notification_id|$nonce" ]] || {
    printf '%s/%s acceptance was not published to the worktree\n' "$harness" "$turn" >&2
    exit 1
  }
  [[ "$(cat "$target_dir/accepted")" == "$notification_id|$nonce" ]]
  [[ "$(cat "$target_dir/acknowledged")" == "$notification_id|$nonce" ]]

  # ── Delivery and completion are durable, and the lease is held by this nonce ─
  for _ in $(seq 1 2000); do
    [[ -f "$target_dir/completed" ]] && break
    [[ -f "$failure_log" ]] && break
    sleep 0.02
  done
  [[ ! -f "$failure_log" ]] || {
    printf '%s/%s harness reported: %s\n' "$harness" "$turn" "$(cat "$failure_log")" >&2
    exit 1
  }
  [[ "$(cat "$target_dir/delivered")" == "$notification_id|$nonce" ]]
  [[ "$(cat "$target_dir/completed")" == "$notification_id|$nonce" ]]
  [[ "$(cat "$state/notifications/$notification_id/action_lease")" == "$nonce" ]]

  # ── The nudge really was injected, carrying this exact token ─────────────────
  grep -Fq "$notification_id|$nonce" "$nudge_log" || {
    printf '%s/%s nudge did not carry the ack token:\n%s\n' \
      "$harness" "$turn" "$(cat "$nudge_log")" >&2
    exit 1
  }

  # ── Launch args came from the shared registry ────────────────────────────────
  [[ "$(cat "$arg_log")" == "$(printf '%s|%s' \
      "$(_sgt_harness_launch_args "$harness" | grep -c . || true)" \
      "$(expected_launch_args "$harness")")" ]] || {
    printf '%s launch args diverged from the registry: got %s, registry says %s\n' \
      "$harness" "$(cat "$arg_log")" "$(expected_launch_args "$harness")" >&2
    exit 1
  }
  expected_count="$(_sgt_harness_launch_args "$harness" | grep -c . || true)"
  [[ "$(cat "$arg_log")" == "$expected_count|"* ]]

  printf '%s\n' "$nonce"
}

while IFS= read -r harness; do
  [[ -n "$harness" ]] || continue

  state="$TEST_ROOT/$harness/state"
  worktree="$TEST_ROOT/$harness/worktree"
  mkdir -p "$state" "$worktree"
  printf 'in_progress\n' > "$worktree/.sergeant-status"
  printf '1\n' > "$worktree/.sergeant-gate-generation"

  # ── Turn 1: the initial notification ────────────────────────────────────────
  initial_nonce="$(run_turn "$harness" initial initial "initial-$harness" "$state" "$worktree")"

  # Clean nonterminal exit: not orphaned, and the handoff is preserved.
  for _ in $(seq 1 2000); do
    [[ "$(cat "$state/status" 2>/dev/null || true)" == "needs_input" ]] && break
    sleep 0.02
  done
  [[ "$(cat "$state/status")" == "needs_input" ]] || {
    printf '%s exited the initial turn as %s, expected needs_input\n' \
      "$harness" "$(cat "$state/status" 2>/dev/null || true)" >&2
    exit 1
  }
  [[ ! -e "$state/diagnostic" ]] || {
    printf '%s recorded a diagnostic after a clean nonterminal exit:\n%s\n' \
      "$harness" "$(cat "$state/diagnostic")" >&2
    exit 1
  }

  # ── Turn 2: relaunch with a response notification ───────────────────────────
  # A relaunch must complete the same durable handshake, for the same harness,
  # against a fresh notification id and a fresh target nonce.
  response_nonce="$(run_turn "$harness" response response "response-$harness" "$state" "$worktree")"
  [[ "$response_nonce" != "$initial_nonce" ]] || {
    printf '%s relaunch reused the initial target nonce\n' "$harness" >&2
    exit 1
  }

  for _ in $(seq 1 2000); do
    [[ -s "$state/result" ]] && break
    sleep 0.02
  done
  [[ "$(cat "$state/status")" == "done" ]] || {
    printf '%s relaunch ended as %s, expected done\n' \
      "$harness" "$(cat "$state/status" 2>/dev/null || true)" >&2
    exit 1
  }
  [[ "$(cat "$state/result")" == "https://example.invalid/pr/$harness" ]]

  # Both turns' evidence survives: neither overwrote the other.
  [[ "$(cat "$state/notifications/initial-$harness/action_lease")" == "$initial_nonce" ]]
  [[ "$(cat "$state/notifications/response-$harness/action_lease")" == "$response_nonce" ]]
done <<EOF
$HARNESSES
EOF

# ── The accepted-harness lists must not drift apart ───────────────────────────
# _require_interactive_agent in bin/_sgt-lib.sh keeps its own copy of the
# accepted list.  If either side gains or loses a harness without the other, a
# harness can once again ship without a readiness probe.
lib_list="$(sed -n '/_require_interactive_agent()/,/^}/p' "$ROOT_DIR/bin/_sgt-lib.sh" | \
  sed -n 's/^[[:space:]]*\([a-z|]*\))[[:space:]]*;;[[:space:]]*$/\1/p' | \
  tr '|' '\n' | grep -v '^\*$' | grep . | sort -u)"
registry_list="$(printf '%s\n' "$HARNESSES" | grep . | sort -u)"
[[ "$lib_list" == "$registry_list" ]] || {
  printf 'accepted-harness lists drifted.\n_require_interactive_agent:\n%s\nshared registry:\n%s\n' \
    "$lib_list" "$registry_list" >&2
  exit 1
}

printf 'per-harness notification handshake: ok\n'
