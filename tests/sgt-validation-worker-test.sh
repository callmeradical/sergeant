#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
TMUX_SESSION="sgt-validation-worker-test-$$"
trap 'tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true; rm -rf "$TEST_ROOT"' EXIT

state="$TEST_ROOT/state"
worktree="$TEST_ROOT/worktree"
fake_bin="$TEST_ROOT/bin"
mkdir -p "$state" "$worktree" "$fake_bin"
git -C "$worktree" init -q
git -C "$worktree" config user.name Test
git -C "$worktree" config user.email test@example.invalid
printf 'fixture\n' > "$worktree/README.md"
git -C "$worktree" add README.md
git -C "$worktree" commit -qm fixture
head_sha="$(git -C "$worktree" rev-parse HEAD)"
printf '%s\n' "$head_sha" > "$state/validation_head"
cat > "$state/validation-intent.md" <<'EOF'
## Objective

Validate only after release.
EOF
revision="$(bash -c 'source "$1"; _sgt_intent_revision "$2"' _ \
  "$ROOT_DIR/bin/_sgt-intent.sh" "$state/validation-intent.md")"
coordinator_start="$(ps -o lstart= -p "$$" | awk '{$1=$1; print}')"
cat > "$state/validation-launch.lock" <<EOF
pid=$$
start=$coordinator_start
coordinator=test-coordinator
purpose=test/validation-launch
EOF

cat > "$fake_bin/no-mistakes" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$NO_MISTAKES_LOG"
EOF
chmod +x "$fake_bin/no-mistakes"

tmux new-session -d -s "$TMUX_SESSION" -n anchor "sleep 60"
pane="$(tmux new-window -d -P -F '#{pane_id}' -t "$TMUX_SESSION" -n validation \
  -c "$worktree" \
  "env PATH='$fake_bin:$PATH' NO_MISTAKES_LOG='$TEST_ROOT/no-mistakes.log' \
  SGT_VALIDATION_COMMIT_ACK_DELAY=0.3 \
  SGT_VALIDATION_SUCCESS_ACK_DELAY=0.3 \
  '$ROOT_DIR/bin/sgt-validation-worker' '$state' '$worktree' '$revision' \
  2>'$TEST_ROOT/worker.err'")"
sleep 0.1
[[ ! -e "$TEST_ROOT/no-mistakes.log" ]]
for _ in $(seq 1 100); do
  [[ -f "$state/validation-child-ready" ]] && break
  sleep 0.02
done
[[ -s "$state/validation-child-ready" ]] || {
  cat "$TEST_ROOT/worker.err" >&2
  exit 1
}

printf '%s\n' "$pane" > "$state/validation_pane"
tmux display-message -p -t "$pane" \
  '#{pane_dead}|#{pane_id}|#{pane_pid}|#{pane_created}|#{pane_start_command}' \
  > "$state/validation_pane_identity"
printf '%s\n' "$revision" > "$state/validation-release.tmp"
sleep 0.3
mv "$state/validation-release.tmp" "$state/validation-release"

for _ in $(seq 1 100); do
  [[ -f "$state/validation-child-accepted" ]] && break
  sleep 0.02
done
cp "$state/validation-child-accepted" "$state/validation-child-commit"

for _ in $(seq 1 100); do
  [[ -f "$state/validation-child-committed" ]] && break
  sleep 0.02
done
[[ -s "$state/validation-child-committed" ]]
cp "$state/validation-child-committed" "$state/validation-success"
for _ in $(seq 1 100); do
  [[ -f "$state/validation-success-ack" ]] && break
  sleep 0.02
done
[[ -s "$state/validation-success-ack" ]]
rm "$state/validation-launch.lock"

for _ in $(seq 1 100); do
  [[ -f "$TEST_ROOT/no-mistakes.log" ]] && break
  sleep 0.02
done
grep -Fq 'axi run --intent' "$TEST_ROOT/no-mistakes.log"
grep -Fq 'Validate only after release.' "$TEST_ROOT/no-mistakes.log"
if grep -Fq -- '--yes' "$TEST_ROOT/no-mistakes.log"; then
  printf 'validation worker enabled automatic gates\n' >&2
  exit 1
fi
[[ "$(cat "$state/validation_status")" == 'exited:0' ]]
[[ -s "$state/validation-child-accepted" ]]

dead_state="$TEST_ROOT/dead-state"
mkdir -p "$dead_state"
cp "$state/validation-intent.md" "$dead_state/validation-intent.md"
printf '%s\n' "$head_sha" > "$dead_state/validation_head"
cat > "$dead_state/validation-launch.lock" <<EOF
pid=99999999
start=Thu Jul 23 00:00:00 2026
coordinator=test-coordinator
purpose=test/validation-launch
EOF
dead_pane="$(tmux new-window -d -P -F '#{pane_id}' -t "$TMUX_SESSION" -n dead-coordinator \
  -c "$worktree" \
  "env PATH='$fake_bin:$PATH' NO_MISTAKES_LOG='$TEST_ROOT/dead-no-mistakes.log' \
  '$ROOT_DIR/bin/sgt-validation-worker' '$dead_state' '$worktree' '$revision'")"
for _ in $(seq 1 100); do
  tmux display-message -p -t "$dead_pane" '#{pane_dead}' 2>/dev/null | grep -qx 1 && break
  sleep 0.02
done
[[ ! -e "$TEST_ROOT/dead-no-mistakes.log" ]]

exit_state="$TEST_ROOT/exit-state"
mkdir -p "$exit_state"
cp "$state/validation-intent.md" "$exit_state/validation-intent.md"
printf '%s\n' "$head_sha" > "$exit_state/validation_head"
cat > "$exit_state/validation-launch.lock" <<EOF
pid=$$
start=$coordinator_start
coordinator=test-coordinator
purpose=test/validation-launch
EOF
exit_pane="$(tmux new-window -d -P -F '#{pane_id}' -t "$TMUX_SESSION" -n child-exit \
  -c "$worktree" \
  "env PATH='$fake_bin:$PATH' NO_MISTAKES_LOG='$TEST_ROOT/exit-no-mistakes.log' \
  '$ROOT_DIR/bin/sgt-validation-worker' '$exit_state' '$worktree' '$revision'")"
for _ in $(seq 1 100); do
  [[ -f "$exit_state/validation-child-ready" ]] && break
  sleep 0.02
done
tmux kill-pane -t "$exit_pane"
[[ ! -e "$TEST_ROOT/exit-no-mistakes.log" && ! -e "$exit_state/validation-child-accepted" ]]

printf 'sgt-validation-worker release handshake: ok\n'
