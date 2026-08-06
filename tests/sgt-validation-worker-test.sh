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

# Capability probes must not count as a run, so --version and `axi run --help`
# answer without touching NO_MISTAKES_LOG.
cat > "$fake_bin/no-mistakes" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --version|-v)
    printf 'no-mistakes version %s\n' "${NO_MISTAKES_FAKE_VERSION:-v9.9.9 (stub)}"
    exit 0
    ;;
esac
if [[ "$*" == *'axi run --help'* ]]; then
  if [[ "${NO_MISTAKES_NO_INTENT:-}" != "1" ]]; then
    printf '      --intent string   what the user set out to accomplish\n'
  fi
  if [[ "${NO_MISTAKES_NO_INTENT_FILE:-}" != "1" ]]; then
    printf '      --intent-file string   read the intent from a file instead of argv\n'
  fi
  printf '      --skip string     comma-separated pipeline steps to skip\n'
  exit 0
fi
printf '%s\n' "$*" > "$NO_MISTAKES_LOG"
EOF
chmod +x "$fake_bin/no-mistakes"

tmux new-session -d -s "$TMUX_SESSION" -n anchor "sleep 60"
pane="$(tmux new-window -d -P -F '#{pane_id}' -t "$TMUX_SESSION" -n validation \
  -c "$worktree" \
  "env PATH='$fake_bin:$PATH' NO_MISTAKES_LOG='$TEST_ROOT/no-mistakes.log' \
  SGT_VALIDATION_COMMIT_ACK_DELAY=0.3 \
  SGT_VALIDATION_SUCCESS_ACK_DELAY=0.3 \
  '$ROOT_DIR/bin/sgt-validation-worker' '$state' '$worktree' '$revision' intent-file \
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
chmod 600 "$state/validation_pane_identity"
cp "$state/validation-child-ready" "$state/validation-release.tmp"
sleep 0.3
mv "$state/validation-release.tmp" "$state/validation-release"
chmod 600 "$state/validation-release"
ln "$state/validation-release" "$state/validation-release-owner"

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
sleep 0.1
[[ ! -e "$TEST_ROOT/no-mistakes.log" ]]
: > "$TEST_ROOT/coordinator-return-initiated"
rm "$state/validation-launch.lock"

VALIDATION_INTENT="$state/validation-intent.md"
for _ in $(seq 1 100); do
  [[ -f "$TEST_ROOT/no-mistakes.log" ]] && break
  sleep 0.02
done
grep -Fq 'axi run --intent-file' "$TEST_ROOT/no-mistakes.log"
# The worker passes the intent file path; intent content must not appear in argv.
grep -Fq "$VALIDATION_INTENT" "$TEST_ROOT/no-mistakes.log"
if grep -Fq 'Validate only after release.' "$TEST_ROOT/no-mistakes.log"; then
  printf 'validation worker leaked intent content into argv\n' >&2
  exit 1
fi
if grep -Fq 'Validate only after release.' "$TEST_ROOT/no-mistakes.log"; then
  printf 'validation worker leaked intent content into argv\n' >&2
  exit 1
fi
[[ -e "$TEST_ROOT/coordinator-return-initiated" ]]
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
  '$ROOT_DIR/bin/sgt-validation-worker' '$dead_state' '$worktree' '$revision' intent-file")"
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
  '$ROOT_DIR/bin/sgt-validation-worker' '$exit_state' '$worktree' '$revision' intent-file")"
for _ in $(seq 1 100); do
  [[ -f "$exit_state/validation-child-ready" ]] && break
  sleep 0.02
done
tmux kill-pane -t "$exit_pane"
[[ ! -e "$TEST_ROOT/exit-no-mistakes.log" && ! -e "$exit_state/validation-child-accepted" ]]

rm -f "$exit_state/validation-child-ready"
symlink_pane="$(tmux new-window -d -P -F '#{pane_id}' -t "$TMUX_SESSION" -n release-symlink \
  -c "$worktree" \
  "env PATH='$fake_bin:$PATH' NO_MISTAKES_LOG='$TEST_ROOT/symlink-no-mistakes.log' \
  '$ROOT_DIR/bin/sgt-validation-worker' '$exit_state' '$worktree' '$revision' intent-file")"
for _ in $(seq 1 100); do
  [[ -f "$exit_state/validation-child-ready" ]] && break
  sleep 0.02
done
printf '%s\n' "$symlink_pane" > "$exit_state/validation_pane"
tmux display-message -p -t "$symlink_pane" \
  '#{pane_dead}|#{pane_id}|#{pane_pid}|#{pane_created}|#{pane_start_command}' \
  > "$exit_state/validation_pane_identity"
chmod 600 "$exit_state/validation_pane_identity"
chmod 600 "$exit_state/validation_pane_identity"
cp "$exit_state/validation-child-ready" "$exit_state/release-target"
chmod 600 "$exit_state/release-target"
ln -s "$exit_state/release-target" "$exit_state/validation-release"
ln "$exit_state/release-target" "$exit_state/validation-release-owner"
sleep 0.1
[[ ! -e "$TEST_ROOT/symlink-no-mistakes.log" && \
  ! -e "$exit_state/validation-child-accepted" ]]

# Prove that a mutation to the intent file between release and sealing is caught.
# The worker must write exited:2 to validation_status and must not run no-mistakes.
# Drives the full coordinator handshake so the sealed-intent check is reached.
state2="$TEST_ROOT/state2"
worktree2="$TEST_ROOT/worktree2"
mkdir -p "$state2" "$worktree2"
git -C "$worktree2" init -q
git -C "$worktree2" config user.name Test
git -C "$worktree2" config user.email test@example.invalid
printf 'fixture\n' > "$worktree2/README.md"
git -C "$worktree2" add README.md
git -C "$worktree2" commit -qm fixture
head_sha2="$(git -C "$worktree2" rev-parse HEAD)"
printf '%s\n' "$head_sha2" > "$state2/validation_head"
cat > "$state2/validation-intent.md" <<'EOF'
## Objective

Validate only after release.
EOF
revision2="$(bash -c 'source "$1"; _sgt_intent_revision "$2"' _ \
  "$ROOT_DIR/bin/_sgt-intent.sh" "$state2/validation-intent.md")"
cat > "$state2/validation-launch.lock" <<EOF
pid=$$
start=$coordinator_start
coordinator=test-coordinator
purpose=test/validation-mutation
EOF
mutated_log="$TEST_ROOT/mutated-no-mistakes.log"
TMUX_SESSION2="sgt-vw-mutation-test-$$"
trap 'tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true; tmux kill-session -t "$TMUX_SESSION2" 2>/dev/null || true; rm -rf "$TEST_ROOT"' EXIT
pane2="$(tmux new-session -d -P -F '#{pane_id}' -s "$TMUX_SESSION2" -n validation \
  -c "$worktree2" \
  "env PATH='$fake_bin:$PATH' NO_MISTAKES_LOG='$mutated_log' \
  SGT_VALIDATION_COMMIT_ACK_DELAY=0 SGT_VALIDATION_SUCCESS_ACK_DELAY=0 \
  '$ROOT_DIR/bin/sgt-validation-worker' '$state2' '$worktree2' '$revision2' intent-file")"
# Wait for validation-child-ready to get the HANDSHAKE token.
# The mutation must happen AFTER the worker's initial revision check passes.
for _ in $(seq 1 200); do
  [[ -f "$state2/validation-child-ready" ]] && break
  sleep 0.02
done
[[ -s "$state2/validation-child-ready" ]] || {
  printf 'mutation test: worker did not publish child-ready\n' >&2
  exit 1
}
handshake2="$(cat "$state2/validation-child-ready")"
printf '%s\n' "$pane2" > "$state2/validation_pane"
tmux display-message -p -t "$pane2" \
  '#{pane_dead}|#{pane_id}|#{pane_pid}|#{pane_created}|#{pane_start_command}' \
  > "$state2/validation_pane_identity"
chmod 600 "$state2/validation_pane_identity"
# Mutate AFTER child-ready: the worker already passed its initial revision check.
# The sealed copy will hash the mutated file and detect the mismatch.
printf '\nMutation.\n' >> "$state2/validation-intent.md"
# Write release as a mode-600 hardlink pair so _sgt_read_same_owned_files passes.
cp "$state2/validation-child-ready" "$state2/validation-release.tmp"
mv "$state2/validation-release.tmp" "$state2/validation-release"
chmod 600 "$state2/validation-release"
ln "$state2/validation-release" "$state2/validation-release-owner"
# Drive remaining handshake steps so the worker reaches the sealed-intent phase.
for _ in $(seq 1 200); do
  [[ -f "$state2/validation-child-accepted" ]] && break
  sleep 0.02
done
cp "$state2/validation-child-accepted" "$state2/validation-child-commit"
for _ in $(seq 1 200); do
  [[ -f "$state2/validation-child-committed" ]] && break
  sleep 0.02
done
cp "$state2/validation-child-committed" "$state2/validation-success"
for _ in $(seq 1 200); do
  [[ -f "$state2/validation-success-ack" ]] && break
  sleep 0.02
done
# Remove coordinator lock so the worker exits the lock-wait loop and reaches
# the sealing phase, where it detects the mutation and writes exited:2.
rm -f "$state2/validation-launch.lock"
for _ in $(seq 1 200); do
  [[ "$(cat "$state2/validation_status" 2>/dev/null || true)" =~ ^exited: ]] && break
  sleep 0.02
done
[[ ! -e "$mutated_log" ]] || {
  printf 'validation worker ran no-mistakes despite mutated intent file\n' >&2
  exit 1
}
[[ "$(cat "$state2/validation_status" 2>/dev/null)" == 'exited:2' ]] || {
  printf 'mutation test: expected exited:2, got: %s\n' \
    "$(cat "$state2/validation_status" 2>/dev/null || echo 'empty')" >&2
  exit 1
}

# ── intent transport contract ────────────────────────────────────────────────
# Drives the coordinator side of the handshake so a worker reaches the phase
# where it invokes no-mistakes.
release_worker() {
  local dir="$1" worker_pane="$2"
  printf '%s\n' "$worker_pane" > "$dir/validation_pane"
  tmux display-message -p -t "$worker_pane" \
    '#{pane_dead}|#{pane_id}|#{pane_pid}|#{pane_created}|#{pane_start_command}' \
    > "$dir/validation_pane_identity"
  chmod 600 "$dir/validation_pane_identity"
  cp "$dir/validation-child-ready" "$dir/validation-release.tmp"
  mv "$dir/validation-release.tmp" "$dir/validation-release"
  chmod 600 "$dir/validation-release"
  ln "$dir/validation-release" "$dir/validation-release-owner"
  wait_for_file "$dir/validation-child-accepted"
  cp "$dir/validation-child-accepted" "$dir/validation-child-commit"
  wait_for_file "$dir/validation-child-committed"
  cp "$dir/validation-child-committed" "$dir/validation-success"
  wait_for_file "$dir/validation-success-ack"
  rm -f "$dir/validation-launch.lock"
}
wait_for_file() {
  local path="$1" _
  for _ in $(seq 1 200); do
    [[ -f "$path" ]] && return 0
    sleep 0.02
  done
  return 1
}
new_transport_state() {
  local dir="$1"
  mkdir -p "$dir"
  cp "$state/validation-intent.md" "$dir/validation-intent.md"
  printf '%s\n' "$head_sha" > "$dir/validation_head"
  cat > "$dir/validation-launch.lock" <<EOF
pid=$$
start=$coordinator_start
coordinator=test-coordinator
purpose=test/validation-transport
EOF
}
launch_transport_worker() {
  local dir="$1" log="$2" transport="$3" extra_env="${4:-}"
  tmux new-window -d -P -F '#{pane_id}' -t "$TMUX_SESSION" -n "transport-$$-$RANDOM" \
    -c "$worktree" \
    "env PATH='$fake_bin:$PATH' NO_MISTAKES_LOG='$log' $extra_env \
    SGT_VALIDATION_COMMIT_ACK_DELAY=0 SGT_VALIDATION_SUCCESS_ACK_DELAY=0 \
    '$ROOT_DIR/bin/sgt-validation-worker' '$dir' '$worktree' '$revision' '$transport' \
    2>'$dir/worker.err'"
}

# A consented argv transport passes the intent content through --intent.
argv_state="$TEST_ROOT/argv-state"
new_transport_state "$argv_state"
argv_log="$TEST_ROOT/argv-no-mistakes.log"
argv_pane="$(launch_transport_worker "$argv_state" "$argv_log" argv \
  "NO_MISTAKES_NO_INTENT_FILE=1")"
wait_for_file "$argv_state/validation-child-ready" || {
  cat "$argv_state/worker.err" >&2
  exit 1
}
release_worker "$argv_state" "$argv_pane"
wait_for_file "$argv_log" || {
  cat "$argv_state/worker.err" >&2
  printf 'consented argv transport never invoked no-mistakes\n' >&2
  exit 1
}
grep -Fq 'axi run --intent ' "$argv_log" || {
  printf 'argv transport did not use --intent: %s\n' "$(cat "$argv_log")" >&2
  exit 1
}
grep -Fq 'Validate only after release.' "$argv_log" || {
  printf 'argv transport did not deliver the canonical intent\n' >&2
  exit 1
}
if grep -Fq -- '--intent-file' "$argv_log"; then
  printf 'argv transport used the private transport flag\n' >&2
  exit 1
fi

# The private transport must fail closed when the installed build lost the flag,
# rather than degrading to argv.
missing_state="$TEST_ROOT/missing-capability-state"
new_transport_state "$missing_state"
missing_log="$TEST_ROOT/missing-no-mistakes.log"
launch_transport_worker "$missing_state" "$missing_log" intent-file \
  "NO_MISTAKES_NO_INTENT_FILE=1" >/dev/null
for _ in $(seq 1 200); do
  [[ -s "$missing_state/worker.err" ]] && break
  sleep 0.02
done
grep -Fq 'required capability: no-mistakes axi run --intent-file' \
  "$missing_state/worker.err" || {
  printf 'worker did not report the missing capability: %s\n' \
    "$(cat "$missing_state/worker.err" 2>/dev/null || echo empty)" >&2
  exit 1
}
[[ ! -e "$missing_log" && ! -e "$missing_state/validation-child-ready" ]] || {
  printf 'worker proceeded without the private intent transport\n' >&2
  exit 1
}

# The diagnostic must describe the build actually installed: when only the argv
# transport exists, it must name --allow-argv-intent as the operator's remedy
# instead of claiming no intent flag exists at all.
grep -Fq 'Re-run with --allow-argv-intent' "$missing_state/worker.err" || {
  printf 'worker diagnostic did not name the available remedy: %s\n' \
    "$(cat "$missing_state/worker.err" 2>/dev/null || echo empty)" >&2
  exit 1
}
if grep -Fq 'this build accepts no intent flag' "$missing_state/worker.err"; then
  printf 'worker diagnostic contradicted the observed flag surface\n' >&2
  exit 1
fi

# A build that offers only the private transport must not run a consented argv
# request through --intent, which that build does not accept.
mismatch_state="$TEST_ROOT/argv-unavailable-state"
new_transport_state "$mismatch_state"
mismatch_log="$TEST_ROOT/argv-unavailable-no-mistakes.log"
launch_transport_worker "$mismatch_state" "$mismatch_log" argv \
  "NO_MISTAKES_NO_INTENT=1" >/dev/null
for _ in $(seq 1 200); do
  [[ -s "$mismatch_state/worker.err" ]] && break
  sleep 0.02
done
grep -Fq 'required capability' "$mismatch_state/worker.err" || {
  printf 'worker accepted an argv transport the build cannot serve: %s\n' \
    "$(cat "$mismatch_state/worker.err" 2>/dev/null || echo empty)" >&2
  exit 1
}
[[ ! -e "$mismatch_log" && ! -e "$mismatch_state/validation-child-ready" ]] || {
  printf 'unavailable argv transport reached the handshake or a run\n' >&2
  exit 1
}

# An unrecognised transport is refused before any handshake or run.
unknown_state="$TEST_ROOT/unknown-transport-state"
new_transport_state "$unknown_state"
unknown_log="$TEST_ROOT/unknown-no-mistakes.log"
launch_transport_worker "$unknown_state" "$unknown_log" plaintext >/dev/null
for _ in $(seq 1 200); do
  [[ -s "$unknown_state/worker.err" ]] && break
  sleep 0.02
done
grep -Fq 'unsupported validation intent transport: plaintext' \
  "$unknown_state/worker.err" || {
  printf 'worker accepted an unsupported transport: %s\n' \
    "$(cat "$unknown_state/worker.err" 2>/dev/null || echo empty)" >&2
  exit 1
}
[[ ! -e "$unknown_log" && ! -e "$unknown_state/validation-child-ready" ]] || {
  printf 'unsupported transport reached the handshake or a run\n' >&2
  exit 1
}

printf 'sgt-validation-worker release handshake: ok\n'
