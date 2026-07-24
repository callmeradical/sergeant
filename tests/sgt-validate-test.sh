#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fleet="$TEST_ROOT/fleet"
repo_state="$fleet/task-1/app"
worktree="$TEST_ROOT/worktree"
fake_bin="$TEST_ROOT/bin"
mkdir -p "$repo_state" "$worktree" "$fake_bin"
git -C "$worktree" init -q
git -C "$worktree" config user.name Test
git -C "$worktree" config user.email test@example.invalid
printf 'fixture\n' > "$worktree/README.md"
git -C "$worktree" add README.md
git -C "$worktree" commit -qm fixture
git -C "$worktree" remote add origin https://example.invalid/app.git
head_sha="$(git -C "$worktree" rev-parse HEAD)"
printf '%s\n' "$worktree" > "$repo_state/worktree"
printf '%%42\n' > "$repo_state/pane"
printf '0|%%42|4242|123456|worker-command\n' > "$repo_state/pane_identity"
printf '%%11\n' > "$fleet/task-1/primary_pane_id"
printf '0|%%11|1111|111111|coordinator-command\n' > "$fleet/task-1/primary_pane_identity"
printf 'implementation-app-task-1\n' > "$repo_state/window_name"
printf 'implementation\n' > "$repo_state/stage"
printf 'in_progress\n' > "$repo_state/status"
printf 'in_progress\n' > "$worktree/.sergeant-status"
cat > "$fleet/task-1/.sergeant-intent.md" <<'EOF'
## Objective

Validate the interactive worker safely.
EOF
cp "$fleet/task-1/.sergeant-intent.md" "$repo_state/.sergeant-intent.md"
cp "$fleet/task-1/.sergeant-intent.md" "$worktree/.sergeant-intent.md"
revision="$(bash -c 'source "$1"; _sgt_intent_revision "$2"' _ \
  "$ROOT_DIR/bin/_sgt-intent.sh" "$fleet/task-1/.sergeant-intent.md")"
printf '%s\n' "$revision" > "$fleet/task-1/intent_revision"
printf '%s\n' "$revision" > "$repo_state/intent_revision"
cat > "$worktree/.sergeant-validation-ready" <<EOF
intent_revision=$revision
head_sha=$head_sha
standards_review=passed
spec_review=passed
readiness_review=passed
EOF

cat > "$fake_bin/no-mistakes" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$fake_bin/no-mistakes"

cat > "$fake_bin/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_LOG"
case "$1" in
  display-message)
    if [[ "$*" == *'#W'* ]]; then
      if [[ "${FAIL_TRANSITION:-}" == "window-rollback-race" ]]; then
        printf 'manual-window-name\n'
      else
        printf 'validation-app-task-1\n'
      fi
    else case "$*" in
      *'%77'*)
        if [[ "${FAIL_TRANSITION:-}" == "pane-identity" ]]; then
          exit 7
        elif [[ "${FAIL_TRANSITION:-}" == "pane-acquire-reuse" ]]; then
          printf '0|%%77|8888|345678|unrelated-command\n'
        elif [[ "${FAIL_TRANSITION:-}" == "pane-pid" ]]; then
          printf '0|%%77||234567|%s\n' "$(cat "$CONCURRENT_DIR/validation-command")"
        elif [[ "${FAIL_TRANSITION:-}" == "pane-reuse" && \
          -e "$CONCURRENT_DIR/pane-identity-captured" ]]; then
          printf '0|%%77|8888|345678|unrelated-command\n'
        elif [[ "${FAIL_TRANSITION:-}" == "pane-dead" && \
          -e "$CONCURRENT_DIR/pane-identity-captured" ]]; then
          printf '1|%%77|7777|234567|%s\n' "$(cat "$CONCURRENT_DIR/validation-command")"
        else
          printf '0|%%77|7777|234567|%s\n' "$(cat "$CONCURRENT_DIR/validation-command")"
          [[ "${FAIL_TRANSITION:-}" != "pane-reuse" && \
            "${FAIL_TRANSITION:-}" != "pane-dead" ]] || \
            : > "$CONCURRENT_DIR/pane-identity-captured"
        fi
        ;;
      *'%11'*) printf '0|%%11|1111|111111|coordinator-command\n' ;;
      *) printf '0|%%42|4242|123456|worker-command\n' ;;
    esac
    fi
    ;;
  split-window)
    command="${!#}"
    printf '%s\n' "$command" > "$CONCURRENT_DIR/validation-command"
    : > "$CONCURRENT_DIR/pane-live"
    printf '%s|%%77|7777|Thu Jul 23 00:00:00 2026\n' \
      "$(cat "$CONCURRENT_DIR/revision")" > "$TEST_REPO_STATE/validation-child-ready"
    [[ "${FAIL_TRANSITION:-}" != "split-empty" ]] || exit 7
    if [[ "${FAIL_TRANSITION:-}" == "pane-pid" ]]; then
      printf '0|%%77||234567|%s\n' "$command"
    else
      printf '0|%%77|7777|234567|%s\n' "$command"
    fi
    [[ "${FAIL_TRANSITION:-}" != "split" ]] || exit 7
    ;;
  list-panes)
    printf '0|%%42|4242|123456|worker-command\n'
    if [[ -e "$CONCURRENT_DIR/pane-live" ]]; then
      if [[ "${FAIL_TRANSITION:-}" == "pane-acquire-reuse" ]]; then
        printf '0|%%77|8888|345678|unrelated-command\n'
      else
        printf '0|%%77|7777|234567|%s\n' "$(cat "$CONCURRENT_DIR/validation-command")"
      fi
    fi
    ;;
  kill-pane)
    rm -f "$CONCURRENT_DIR/pane-live"
    ;;
  rename-window)
    [[ "${FAIL_TRANSITION:-}" != "window-rename" ]] || exit 7
    ;;
esac
EOF
chmod +x "$fake_bin/tmux"
cat > "$fake_bin/ps" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'pgid='*)
    [[ "${FAIL_TRANSITION:-}" != "pane-pgid" && \
      "${FAIL_TRANSITION:-}" != "pane-reuse" ]] || exit 7
    printf '7777\n'
    ;;
  *'lstart='*)
    [[ "${FAIL_TRANSITION:-}" != "pane-start" ]] || exit 7
    printf 'Thu Jul 23 00:00:00 2026\n'
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$fake_bin/ps"

real_git="$(command -v git)"
real_cp="$(command -v cp)"
real_mv="$(command -v mv)"
real_ln="$(command -v ln)"
real_shasum="$(command -v shasum || command -v sha256sum)"
validation_path="${worktree}-validation-task-1"
concurrent_dir="$TEST_ROOT/concurrent"
mkdir -p "$concurrent_dir"
export REAL_GIT="$real_git" REAL_CP="$real_cp" REAL_MV="$real_mv" REAL_LN="$real_ln"
export REAL_SHASUM="$real_shasum" VALIDATION_PATH="$validation_path"
export CONCURRENT_DIR="$concurrent_dir" TEST_REPO_STATE="$repo_state"
printf '%s\n' "$revision" > "$concurrent_dir/revision"

cat > "$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
if [[ "${CONCURRENT_ROLE:-}" == "winner" && "$1" == "clone" ]]; then
  : > "$CONCURRENT_DIR/winner-ready"
  while [[ ! -e "$CONCURRENT_DIR/release-winner" ]]; do sleep 0.01; done
  exec "$REAL_GIT" "$@"
fi
if [[ "${FAIL_TRANSITION:-}" == "clone" && "$1" == "clone" ]]; then
  "$REAL_GIT" "$@"
  exit 7
fi
if [[ "${FAIL_TRANSITION:-}" == "clone-replaced" && "$1" == "clone" ]]; then
  rm -rf "$VALIDATION_PATH"
  mkdir "$CONCURRENT_DIR/replaced-inode-1" "$CONCURRENT_DIR/replaced-inode-2"
  mkdir "$VALIDATION_PATH"
  printf 'replacement\n' > "$VALIDATION_PATH/unowned"
  exit 7
fi
if [[ "${2:-}" == "$VALIDATION_PATH" ]]; then
  case "${FAIL_TRANSITION:-}:$3:${4:-}" in
    checkout:checkout:*) "$REAL_GIT" "$@"; exit 7 ;;
    remote:remote:set-url) exit 7 ;;
    verify:rev-parse:HEAD) exit 7 ;;
  esac
fi
exec "$REAL_GIT" "$@"
EOF
chmod +x "$fake_bin/git"

cat > "$fake_bin/cp" <<'EOF'
#!/usr/bin/env bash
if [[ "${FAIL_TRANSITION:-}" == "intent-copy" && "${2:-}" == *'/validation-intent.md.tmp.'* ]]; then
  exit 7
fi
exec "$REAL_CP" "$@"
EOF
chmod +x "$fake_bin/cp"

cat > "$fake_bin/mv" <<'EOF'
#!/usr/bin/env bash
if [[ "${FAIL_TRANSITION:-}" == "window-race" && "$1" == */window_name ]]; then
  rm -f "$1"
  printf 'concurrent-window\n' > "$1"
fi
if [[ "${FAIL_TRANSITION:-}" == "stage-race" && "$1" == */stage ]]; then
  rm -f "$1"
  printf 'concurrent-stage\n' > "$1"
fi
if [[ "${FAIL_TRANSITION:-}" == "lock-recovery-race" && \
  "$1" == */validation-launch.lock && "${2:-}" == */.validation-launch.lock.recovery.* ]]; then
  rm -f "$1"
  printf 'replacement-owner\n' > "$1"
fi
if [[ "${FAIL_TRANSITION:-}" == "marker" && "${2:-}" == */validation_worktree ]]; then
  exit 7
fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$fake_bin/mv"

cat > "$fake_bin/ln" <<'EOF'
#!/usr/bin/env bash
destination="${2:-}"
if [[ "${FAIL_TRANSITION:-}" == "marker-race" && "$destination" == */validation_worktree ]]; then
  printf 'concurrent-marker\n' > "$destination"
  exit 7
fi
if [[ "${FAIL_TRANSITION:-}" == "state-race" && "$destination" == */validation_pane ]]; then
  printf 'concurrent-pane\n' > "$destination"
  exit 7
fi
"$REAL_LN" "$@" || exit
if [[ "$destination" == */validation-release && \
  "${FAIL_TRANSITION:-}" != "handshake-timeout" ]]; then
  printf '%s|%%77|7777|Thu Jul 23 00:00:00 2026\n' \
    "$(cat "$CONCURRENT_DIR/revision")" > "$TEST_REPO_STATE/validation-child-accepted"
fi
EOF
chmod +x "$fake_bin/ln"

cat > "$fake_bin/shasum" <<'EOF'
#!/usr/bin/env bash
last="${!#}"
if [[ "${FAIL_TRANSITION:-}" == "intent-revision" && "$last" == */validation-intent.md ]]; then
  printf '%064d  %s\n' 0 "$last"
  exit 0
fi
exec "$REAL_SHASUM" "$@"
EOF
chmod +x "$fake_bin/shasum"

PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" "$ROOT_DIR/bin/sgt-validate" task-1 app >/dev/null

[[ "$(cat "$repo_state/validation_pane")" == "%77" ]]
[[ "$(cat "$repo_state/validation_pane_identity")" == \
  "0|%77|7777|234567|$ROOT_DIR/bin/sgt-validation-worker "* ]]
[[ "$(cat "$repo_state/stage")" == "validation" ]]
[[ "$(cat "$repo_state/window_name")" == "validation-app-task-1" ]]
[[ "$(cat "$repo_state/validation_process_group")" == "7777" ]]
[[ "$(cat "$repo_state/validation_pane_pid")" == "7777" ]]
grep -Fq 'rename-window -t %42 validation-app-task-1' "$TEST_ROOT/tmux.log"
grep -Fq 'split-window -P -F #{pane_dead}|#{pane_id}|#{pane_pid}|#{pane_created}|#{pane_start_command} -t %42' \
  "$TEST_ROOT/tmux.log"
grep -Fq "$ROOT_DIR/bin/sgt-validation-worker" "$TEST_ROOT/tmux.log"
grep -Fq "$revision" "$TEST_ROOT/tmux.log"
if grep -Fq 'Validate the interactive worker safely' "$TEST_ROOT/tmux.log" || \
  grep -Fq -- '--yes' "$TEST_ROOT/tmux.log"; then
  printf 'validation launch leaked intent or enabled automatic gates\n' >&2
  exit 1
fi

validation_worktree="$(cat "$repo_state/validation_worktree")"
rm "$repo_state/validation_pane" "$repo_state/validation_pane_identity" \
  "$repo_state/validation_pane_pid" "$repo_state/validation_process_group" \
  "$repo_state/validation_process_start" \
  "$repo_state/validation-intent.md" "$repo_state/validation-release" \
  "$repo_state/validation-child-ready" "$repo_state/validation-child-accepted" \
  "$repo_state/validation-child-commit" \
  "$repo_state/validation_status" "$repo_state/validation_worktree" \
  "$repo_state/validation_head"
rm -rf "$validation_worktree"
printf 'implementation-app-task-1\n' > "$repo_state/window_name"
printf 'implementation\n' > "$repo_state/stage"

cleanup_validation_state() {
  local launched_worktree
  launched_worktree="$(cat "$repo_state/validation_worktree" 2>/dev/null || true)"
  rm -f "$repo_state/validation_pane" "$repo_state/validation_pane_identity" \
    "$repo_state/validation_pane_pid" "$repo_state/validation_process_group" \
    "$repo_state/validation_process_start" "$repo_state/validation-intent.md" \
    "$repo_state/validation-release" "$repo_state/validation-child-ready" \
    "$repo_state/validation-child-accepted" "$repo_state/validation-child-commit" \
    "$repo_state/validation_status" \
    "$repo_state/validation_worktree" "$repo_state/validation_head"
  [[ -z "$launched_worktree" ]] || rm -rf "$launched_worktree"
  printf 'implementation-app-task-1\n' > "$repo_state/window_name"
  printf 'implementation\n' > "$repo_state/stage"
  rm -f "$concurrent_dir/pane-live" "$concurrent_dir/pane-identity-captured"
}

write_validation_lock() {
  local pid="$1" start="$2" coordinator="$3" purpose="$4"
  cat > "$repo_state/validation-launch.lock" <<EOF
pid=$pid
start=$start
coordinator=$coordinator
purpose=$purpose
EOF
}

assert_lock_blocks_and_is_preserved() {
  local expected="$1" output status
  set +e
  output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
    TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
    "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 && "$output" == *'already reserved or unsafe'* ]]
  [[ "$(cat "$repo_state/validation-launch.lock")" == "$expected" ]]
}

assert_failed_launch_rolls_back_and_retries() {
  local transition="$1" output status path before_transition_kills after_transition_kills attempts=200
  [[ "$transition" != handshake-timeout ]] || attempts=2
  before_transition_kills="$(grep -c '^kill-pane -t %77$' "$TEST_ROOT/tmux.log" || true)"
  set +e
  output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
    FAIL_TRANSITION="$transition" SGT_VALIDATE_FAIL_TRANSITION="$transition" \
    SGT_VALIDATION_HANDSHAKE_ATTEMPTS="$attempts" \
    TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
    "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
  status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    printf 'expected injected %s transition failure\n' "$transition" >&2
    exit 1
  fi
  [[ ! -e "$validation_path" ]] || {
    printf 'injected %s failure stranded validation clone: %s\n' "$transition" "$output" >&2
    exit 1
  }
  for path in validation_pane validation_pane_identity validation_pane_pid \
    validation_process_group validation_process_start validation-intent.md \
    validation-release validation-child-ready validation-child-accepted \
    validation-child-commit \
    validation_status validation_worktree validation_head \
    validation-launch.lock; do
    [[ ! -e "$repo_state/$path" ]] || {
      printf 'injected %s failure stranded %s: %s\n' "$transition" "$path" "$output" >&2
      exit 1
    }
  done
  transaction_paths=("$repo_state"/*.candidate.* "$repo_state"/*.validation-backup.*)
  for path in "${transaction_paths[@]}"; do
    [[ ! -e "$path" && ! -L "$path" ]] || {
      printf 'injected %s failure stranded transaction path %s\n' "$transition" "$path" >&2
      exit 1
    }
  done
  [[ "$(cat "$repo_state/window_name")" == "implementation-app-task-1" ]]
  [[ "$(cat "$repo_state/stage")" == "implementation" ]]
  after_transition_kills="$(grep -c '^kill-pane -t %77$' "$TEST_ROOT/tmux.log" || true)"
  case "$transition" in
    split|split-empty|pane-identity|pane-dead)
      [[ "$after_transition_kills" -eq $((before_transition_kills + 1)) ]] || {
        printf 'injected %s failure did not clean its exact pane\n' "$transition" >&2
        exit 1
      }
      ;;
  esac

  PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
    TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
    "$ROOT_DIR/bin/sgt-validate" task-1 app >/dev/null
  cleanup_validation_state
}

for transition in clone checkout remote verify marker-temp marker-write marker intent-copy \
  intent-rename intent-revision split split-empty pane-identity pane-pid pane-pgid \
  pane-start window-rename state-validation_pane state-validation_pane_identity \
  state-validation_pane_pid state-validation_process_group \
  state-validation_process_start state-window_name state-validation_head \
  state-stage state-validation_status release-write release-rename; do
  assert_failed_launch_rolls_back_and_retries "$transition"
done
assert_failed_launch_rolls_back_and_retries handshake-timeout

before_old_window_restores="$(grep -c '^rename-window -t %42 implementation-app-task-1$' \
  "$TEST_ROOT/tmux.log" || true)"
set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  FAIL_TRANSITION=window-rollback-race \
  SGT_VALIDATE_FAIL_TRANSITION=state-validation_pane \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 ]]
[[ "$(grep -c '^rename-window -t %42 implementation-app-task-1$' \
  "$TEST_ROOT/tmux.log" || true)" == "$before_old_window_restores" ]]
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app >/dev/null
cleanup_validation_state

lock_coordinator='%11|0|%11|1111|111111|coordinator-command'
lock_purpose='task-1/app/validation-launch'

write_validation_lock "$$" 'Thu Jul 23 00:00:00 2026' "$lock_coordinator" "$lock_purpose"
live_lock="$(cat "$repo_state/validation-launch.lock")"
assert_lock_blocks_and_is_preserved "$live_lock"
rm "$repo_state/validation-launch.lock"

write_validation_lock 99999999 'Thu Jul 23 00:00:00 2026' "$lock_coordinator" "$lock_purpose"
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app >/dev/null
cleanup_validation_state

write_validation_lock 99999999 'Thu Jul 23 00:00:00 2026' "$lock_coordinator" "$lock_purpose"
set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  FAIL_TRANSITION=lock-recovery-race TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$(cat "$repo_state/validation-launch.lock")" == 'replacement-owner' ]]
rm "$repo_state/validation-launch.lock"

write_validation_lock "$$" 'Thu Jul 23 00:00:01 2026' "$lock_coordinator" "$lock_purpose"
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app >/dev/null
cleanup_validation_state

printf 'pid=99999999\n' > "$repo_state/validation-launch.lock"
partial_lock="$(cat "$repo_state/validation-launch.lock")"
assert_lock_blocks_and_is_preserved "$partial_lock"
rm "$repo_state/validation-launch.lock"

write_validation_lock 99999999 'Thu Jul 23 00:00:00 2026' \
  '%99|0|%99|9999|999999|other-coordinator' "$lock_purpose"
foreign_lock="$(cat "$repo_state/validation-launch.lock")"
assert_lock_blocks_and_is_preserved "$foreign_lock"
rm "$repo_state/validation-launch.lock"

crash_candidate="$repo_state/.validation-launch.lock.99999999.1.1"
printf 'partial owner publication\n' > "$crash_candidate"
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app >/dev/null
[[ "$(cat "$crash_candidate")" == 'partial owner publication' ]]
cleanup_validation_state
rm "$crash_candidate"

for race in marker-race state-race; do
  set +e
  output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
    FAIL_TRANSITION="$race" TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
    "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 ]]
  if [[ "$race" == marker-race ]]; then
    [[ "$(cat "$repo_state/validation_worktree")" == "concurrent-marker" ]]
    rm "$repo_state/validation_worktree"
  else
    [[ "$(cat "$repo_state/validation_pane")" == "concurrent-pane" ]]
    rm "$repo_state/validation_pane"
  fi
  PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
    TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
    "$ROOT_DIR/bin/sgt-validate" task-1 app >/dev/null
  cleanup_validation_state
done

for race in window-race stage-race; do
  set +e
  output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
    FAIL_TRANSITION="$race" TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
    "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 ]]
  if [[ "$race" == window-race ]]; then
    [[ "$(cat "$repo_state/window_name")" == "concurrent-window" ]]
    printf 'implementation-app-task-1\n' > "$repo_state/window_name"
  else
    [[ "$(cat "$repo_state/stage")" == "concurrent-stage" ]]
    printf 'implementation\n' > "$repo_state/stage"
  fi
  PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
    TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
    "$ROOT_DIR/bin/sgt-validate" task-1 app >/dev/null
  cleanup_validation_state
done

rm -f "$concurrent_dir/pane-identity-captured"
before_kills="$(grep -c '^kill-pane -t %77$' "$TEST_ROOT/tmux.log" || true)"
set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  FAIL_TRANSITION=pane-acquire-reuse TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 ]]
[[ "$(grep -c '^kill-pane -t %77$' "$TEST_ROOT/tmux.log" || true)" == "$before_kills" ]]
rm -f "$concurrent_dir/pane-live"
rm -f "$repo_state/validation-child-ready" "$repo_state/validation-child-accepted"
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app >/dev/null
cleanup_validation_state

assert_failed_launch_rolls_back_and_retries pane-dead

set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  FAIL_TRANSITION=clone-replaced TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 ]]
[[ "$(cat "$validation_path/unowned")" == "replacement" ]]
rm -rf "$validation_path"
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app >/dev/null
cleanup_validation_state

for prior_state in window_name stage; do
  prior_value="$(cat "$repo_state/$prior_state")"
  rm "$repo_state/$prior_state"
  ln -s "$TEST_ROOT/missing-prior-state" "$repo_state/$prior_state"
  before_mutations="$(grep -Ec '^(split-window|rename-window|kill-pane)' "$TEST_ROOT/tmux.log" || true)"
  set +e
  output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
    TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
    "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 && -L "$repo_state/$prior_state" ]]
  [[ "$(grep -Ec '^(split-window|rename-window|kill-pane)' "$TEST_ROOT/tmux.log" || true)" == \
    "$before_mutations" ]]
  rm "$repo_state/$prior_state"
  printf '%s\n' "$prior_value" > "$repo_state/$prior_state"
done

rm -f "$concurrent_dir/pane-identity-captured"
before_kills="$(grep -c '^kill-pane -t %77$' "$TEST_ROOT/tmux.log" || true)"
assert_failed_launch_rolls_back_and_retries pane-reuse
[[ "$(grep -c '^kill-pane -t %77$' "$TEST_ROOT/tmux.log" || true)" == "$before_kills" ]] || {
  printf 'pane identity reuse killed an unrelated pane\n' >&2
  exit 1
}

PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" CONCURRENT_ROLE=winner \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app >"$concurrent_dir/winner.out" 2>&1 &
winner_pid=$!
while [[ ! -e "$concurrent_dir/winner-ready" ]]; do sleep 0.01; done
set +e
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app >"$concurrent_dir/loser.out" 2>&1
loser_status=$?
set -e
[[ "$loser_status" -ne 0 ]]
[[ -d "$validation_path" && ! -L "$validation_path" ]] || {
  printf 'concurrent launch loser removed winner reservation\n' >&2
  exit 1
}
: > "$concurrent_dir/release-winner"
wait "$winner_pid"
[[ "$(cat "$repo_state/validation_worktree")" == "$validation_path" ]]
cleanup_validation_state

for dangling_path in "$validation_path" "$repo_state/validation_worktree" \
  "$repo_state/validation-intent.md" "$repo_state/validation_head" \
  "$repo_state/validation_pane" "$repo_state/validation_pane_identity" \
  "$repo_state/validation_pane_pid" "$repo_state/validation_process_group" \
  "$repo_state/validation_process_start" "$repo_state/validation_status" \
  "$repo_state/validation-release" "$repo_state/validation-release.tmp"; do
  ln -s "$TEST_ROOT/missing-validation-state" "$dangling_path"
  before_mutations="$(grep -Ec '^(split-window|rename-window|kill-pane)' "$TEST_ROOT/tmux.log" || true)"
  set +e
  output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
    TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
    "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 ]]
  [[ -L "$dangling_path" ]]
  [[ "$(grep -Ec '^(split-window|rename-window|kill-pane)' "$TEST_ROOT/tmux.log" || true)" == \
    "$before_mutations" ]] || {
    printf 'dangling validation state reached tmux mutation: %s\n' "$dangling_path" >&2
    exit 1
  }
  rm "$dangling_path"
done

printf 'preexisting\n' > "$repo_state/validation-intent.md"
set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *'Validation launch state already exists'* ]]
[[ "$(cat "$repo_state/validation-intent.md")" == "preexisting" ]]
[[ ! -e "$validation_path" ]]
rm "$repo_state/validation-intent.md"

rm "$worktree/.sergeant-validation-ready"
before_lines="$(wc -l < "$TEST_ROOT/tmux.log")"
set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *'validation-ready marker'* ]]
[[ "$(wc -l < "$TEST_ROOT/tmux.log")" == "$before_lines" ]]

cat > "$worktree/.sergeant-validation-ready" <<EOF
intent_revision=$revision
head_sha=$head_sha
standards_review=passed
spec_review=passed
readiness_review=passed
EOF
before_lines="$(wc -l < "$TEST_ROOT/tmux.log")"
set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%12 SERGEANT_FLEET="$fleet" "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *'coordinator pane identity'* ]]
[[ "$(wc -l < "$TEST_ROOT/tmux.log")" == "$before_lines" ]]

cat > "$worktree/.sergeant-validation-ready" <<EOF
intent_revision=$revision
head_sha=0000000000000000000000000000000000000000
standards_review=passed
spec_review=passed
readiness_review=passed
EOF
before_lines="$(wc -l < "$TEST_ROOT/tmux.log")"
set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *'HEAD or review evidence'* ]]
[[ "$(wc -l < "$TEST_ROOT/tmux.log")" == "$before_lines" ]]

cat > "$worktree/.sergeant-validation-ready" <<EOF
intent_revision=$revision
head_sha=$head_sha
standards_review=passed
spec_review=passed
readiness_review=passed
EOF
printf '\nDrift.\n' >> "$worktree/.sergeant-intent.md"
before_lines="$(wc -l < "$TEST_ROOT/tmux.log")"
set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *'canonical intent revision mismatch'* ]]
[[ "$(wc -l < "$TEST_ROOT/tmux.log")" == "$before_lines" ]]

printf 'sgt-validate split-pane launch: ok\n'
