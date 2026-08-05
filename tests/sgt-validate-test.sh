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
chmod 600 "$repo_state/pane_identity" "$fleet/task-1/primary_pane_identity"
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

# Stub no-mistakes advertising the same axi run flag surface as a real build.
# NO_MISTAKES_NO_INTENT_FILE=1 drops --intent-file to emulate an installed build
# without the private intent transport.
cat > "$fake_bin/no-mistakes" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --version|-v)
    printf 'no-mistakes version %s\n' "${NO_MISTAKES_FAKE_VERSION:-v9.9.9 (stub)}"
    exit 0
    ;;
esac
if [[ "$*" == *'axi run --help'* ]]; then
  printf '  -h, --help            help for run\n'
  printf '      --intent string   what the user set out to accomplish\n'
  if [[ "${NO_MISTAKES_NO_INTENT_FILE:-}" != "1" ]]; then
    printf '      --intent-file string   read the intent from a file instead of argv\n'
  fi
  printf '      --skip string     comma-separated pipeline steps to skip\n'
  printf '  -y, --yes             auto-resolve every gate\n'
  exit 0
fi
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
        if [[ ! -e "$CONCURRENT_DIR/pane-live" && -z "${FAIL_TRANSITION:-}" ]]; then
          exit 7
        elif [[ "${FAIL_TRANSITION:-}" == "pane-identity" || \
          ( "${FAIL_TRANSITION:-}" == @(commit-child-exit|exit-after-committed|exit-during-success|exit-after-final-ack) && \
            ! -e "$CONCURRENT_DIR/pane-live" ) ]]; then
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
      *'%11'*)
        if [[ -n "${PRIMARY_PANE_FLIP:-}" ]]; then
          count=0
          [[ ! -f "$CONCURRENT_DIR/primary-reads" ]] || \
            count="$(cat "$CONCURRENT_DIR/primary-reads")"
          count=$((count + 1))
          printf '%s\n' "$count" > "$CONCURRENT_DIR/primary-reads"
          if [[ "$count" -ge "$PRIMARY_PANE_FLIP" ]]; then
            printf '0|%%11|9911|991111|flipped-command\n'
            exit 0
          fi
        fi
        case "${PRIMARY_PANE_STATE:-live}" in
          dead) printf '1|%%11|1111|111111|coordinator-command\n' ;;
          gone) printf '||||\n' ;;
          recycled) printf '0|%%11|5151|515151|unrelated-command\n' ;;
          *) printf '0|%%11|1111|111111|coordinator-command\n' ;;
        esac
        ;;
      # %12 is a claiming coordinator pane whose pane_pid really is an ancestor
      # of sgt-validate, so pane residency can be proven.
      *'%12'*) printf '0|%%12|%s|121212|claim-coordinator-command\n' "$CLAIM_PANE_PID" ;;
      # %13 sets TMUX_PANE without running inside that pane.
      *'%13'*) printf '0|%%13|999999|131313|forged-coordinator-command\n' ;;
      # %99 does not exist; tmux prints empty fields for an unknown pane ID.
      *'%99'*) printf '||||\n' ;;
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
  *'ppid='*) exec "$REAL_PS" "$@" ;;
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
real_chmod="$(command -v chmod)"
real_mv="$(command -v mv)"
real_ln="$(command -v ln)"
real_rm="$(command -v rm)"
real_stat="$(command -v stat)"
real_shasum="$(command -v shasum || command -v sha256sum)"
validation_path="${worktree}-validation-task-1"
concurrent_dir="$TEST_ROOT/concurrent"
mkdir -p "$concurrent_dir"
export REAL_GIT="$real_git" REAL_CP="$real_cp" REAL_MV="$real_mv" REAL_LN="$real_ln"
export REAL_RM="$real_rm"
export REAL_CHMOD="$real_chmod"
export REAL_STAT="$real_stat"
export REAL_SHASUM="$real_shasum" VALIDATION_PATH="$validation_path"
export REAL_PS="$(command -v ps)"
# sgt-validate runs as a child of this test, so this PID is a real ancestor and
# stands in for the claiming coordinator pane's pane_pid.
export CLAIM_PANE_PID="$$"
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
if [[ "${FAIL_TRANSITION:-}" == "lock-release-failure" && \
  "$1" == */validation-launch.lock && "${2:-}" == */.validation-launch.lock.recovery.* ]]; then
  exit 7
fi
if [[ -n "${EXIT_RELEASE_OUTPUT:-}" && "$1" == */validation-launch.lock && \
  "${2:-}" == */.validation-launch.lock.recovery.* ]]; then
  grep -Fq 'Validation launched in pane %77 beside worker %42.' "$EXIT_RELEASE_OUTPUT" || exit 7
  : > "$CONCURRENT_DIR/exit-release-after-success"
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
if [[ "$destination" == */validation-child-commit ]]; then
  if [[ "${FAIL_TRANSITION:-}" == "commit-child-exit" ]]; then
    rm -f "$CONCURRENT_DIR/pane-live"
  elif [[ "${FAIL_TRANSITION:-}" == "wrong-commit-ack" ]]; then
    printf 'wrong-ack\n' > "$TEST_REPO_STATE/validation-child-committed"
  elif [[ "${FAIL_TRANSITION:-}" != "commit-ack-timeout" ]]; then
    printf '%s|%%77|7777|Thu Jul 23 00:00:00 2026\n' \
      "$(cat "$CONCURRENT_DIR/revision")" > "$TEST_REPO_STATE/validation-child-committed"
    [[ "${FAIL_TRANSITION:-}" != "exit-after-committed" ]] || \
      rm -f "$CONCURRENT_DIR/pane-live"
  fi
fi
if [[ "$destination" == */validation-success ]]; then
  if [[ "${FAIL_TRANSITION:-}" == "exit-during-success" ]]; then
    rm -f "$CONCURRENT_DIR/pane-live"
  elif [[ "${FAIL_TRANSITION:-}" == "wrong-final-token" ]]; then
    printf 'wrong-final\n' > "$TEST_REPO_STATE/validation-success-ack"
  elif [[ "${FAIL_TRANSITION:-}" != "final-ack-timeout" ]]; then
    printf '%s|%%77|7777|Thu Jul 23 00:00:00 2026\n' \
      "$(cat "$CONCURRENT_DIR/revision")" > "$TEST_REPO_STATE/validation-success-ack"
    [[ "${FAIL_TRANSITION:-}" != "exit-after-final-ack" ]] || \
      rm -f "$CONCURRENT_DIR/pane-live"
  fi
fi
EOF
chmod +x "$fake_bin/ln"

cat > "$fake_bin/rm" <<'EOF'
#!/usr/bin/env bash
if [[ "${FAIL_TRANSITION:-}" == "rollback-rm-failure" && "$*" == *validation_worktree* ]]; then
  exit 7
fi
if [[ "${FAIL_TRANSITION:-}" == "checkout-delete-failure" && \
  "$*" == *worktree-validation-task-1* ]]; then
  exit 7
fi
exec "$REAL_RM" "$@"
EOF
chmod +x "$fake_bin/rm"

cat > "$fake_bin/chmod" <<'EOF'
#!/usr/bin/env bash
exec "$REAL_CHMOD" "$@"
EOF
chmod +x "$fake_bin/chmod"

cat > "$fake_bin/stat" <<'EOF'
#!/usr/bin/env bash
last="${!#}"
if [[ "${FAIL_TRANSITION:-}" == "identity-chmod-race" && \
  "$last" == */primary_pane_identity ]]; then
  "$REAL_STAT" "$@"
  chmod 644 "$last"
  exit 0
fi
if [[ "$last" == */primary_pane_identity && -n "${IDENTITY_RACE_MARKER:-}" && \
  "${FAIL_TRANSITION:-}" == @(legacy-identity-content-race|legacy-identity-publish-replaced) ]]; then
  count_file="${IDENTITY_RACE_MARKER}.count"
  count=0
  [[ ! -f "$count_file" ]] || count="$(cat "$count_file")"
  count=$((count + 1))
  printf '%s\n' "$count" > "$count_file"
  if [[ "$count" -eq 3 ]]; then
    case "${FAIL_TRANSITION:-}" in
      legacy-identity-content-race)
        printf 'tampered-pane\n' > "$last"
        chmod 664 "$last"
        ;;
      legacy-identity-publish-replaced)
        rm -f "$last"
        printf 'tampered-pane\n' > "$last"
        chmod 664 "$last"
        ;;
    esac
    : > "${IDENTITY_RACE_MARKER:?}"
  fi
fi
if [[ "${FAIL_TRANSITION:-}" == "release-fifo-race" && "$last" == "$FIFO_PATH" ]]; then
  "$REAL_STAT" "$@"
  rm -f "$last"
  mkfifo "$last"
  chmod 600 "$last"
  (printf '%s\n' "$FIFO_CONTENT" > "$last") </dev/null >/dev/null 2>&1 &
  exit 0
fi
exec "$REAL_STAT" "$@"
EOF
chmod +x "$fake_bin/stat"

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

# The release wrapper reads this output during the coordinator's EXIT trap.
# shellcheck disable=SC2094
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  EXIT_RELEASE_OUTPUT="$TEST_ROOT/initial-validation.out" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" "$ROOT_DIR/bin/sgt-validate" task-1 app \
  > "$TEST_ROOT/initial-validation.out"
[[ -e "$concurrent_dir/exit-release-after-success" ]]

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
grep -Fq "review,document" "$concurrent_dir/validation-command"
if grep -Fq 'Validate the interactive worker safely' "$TEST_ROOT/tmux.log" || \
  grep -Fq -- '--yes' "$TEST_ROOT/tmux.log"; then
  printf 'validation launch leaked intent or enabled automatic gates\n' >&2
  exit 1
fi

validation_worktree="$(cat "$repo_state/validation_worktree")"
printf 'stale-finished-clone\n' > "$validation_worktree/stale-finished"
printf 'exited:0\n' > "$repo_state/validation_status"
rm -f "$concurrent_dir/pane-live"
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app --skip lint >/dev/null
validation_worktree="$(cat "$repo_state/validation_worktree")"
[[ "$(cat "$repo_state/validation_status")" == launched && \
  ! -e "$validation_worktree/stale-finished" ]]
grep -Fq "lint" "$concurrent_dir/validation-command"
if grep -Fq "review,document" "$concurrent_dir/validation-command"; then
  printf 'explicit skip did not replace the medium default\n' >&2
  exit 1
fi

printf 'legacy-finished-clone\n' > "$validation_worktree/legacy-finished"
rm -f "$repo_state/validation_worktree_identity" "$repo_state/validation_worktree_git_dir" \
  "$repo_state/validation_worktree_git_identity" "$repo_state/validation_worktree_owner"
printf 'exited:0\n' > "$repo_state/validation_status"
rm -f "$concurrent_dir/pane-live"
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app --skip '' >/dev/null
validation_worktree="$(cat "$repo_state/validation_worktree")"
[[ "$(cat "$repo_state/validation_status")" == launched && \
  ! -e "$validation_worktree/legacy-finished" ]]
if grep -Fq "review,document" "$concurrent_dir/validation-command"; then
  printf 'explicit empty skip did not request full validation\n' >&2
  exit 1
fi
[[ -s "$repo_state/validation_worktree_identity" && -s "$repo_state/validation_worktree_git_dir" && \
  -s "$repo_state/validation_worktree_git_identity" && -s "$repo_state/validation_worktree_owner" ]]

rm "$repo_state/validation_pane" "$repo_state/validation_pane_identity" \
  "$repo_state/validation_pane_pid" "$repo_state/validation_process_group" \
  "$repo_state/validation_process_start" \
  "$repo_state/validation-intent.md" "$repo_state/validation-release" \
  "$repo_state/validation-release-owner" \
  "$repo_state/validation-child-ready" "$repo_state/validation-child-accepted" \
  "$repo_state/validation-child-commit" \
  "$repo_state/validation-child-committed" \
  "$repo_state/validation-success" "$repo_state/validation-success-ack" \
  "$repo_state/validation_status" "$repo_state/validation_worktree" \
  "$repo_state/validation_worktree_identity" "$repo_state/validation_worktree_git_dir" \
  "$repo_state/validation_worktree_git_identity" "$repo_state/validation_worktree_owner" \
  "$repo_state/validation_head" "$repo_state/validation_intent_transport"
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
    "$repo_state/validation-release-owner" \
    "$repo_state/validation-child-accepted" "$repo_state/validation-child-commit" \
    "$repo_state/validation-child-committed" \
    "$repo_state/validation-success" "$repo_state/validation-success-ack" \
    "$repo_state/validation_status" \
    "$repo_state/validation_worktree" "$repo_state/validation_worktree_identity" \
    "$repo_state/validation_worktree_git_dir" "$repo_state/validation_worktree_git_identity" \
    "$repo_state/validation_worktree_owner" "$repo_state/validation_head" \
    "$repo_state/validation_intent_transport"
  [[ -z "$launched_worktree" ]] || rm -rf "$launched_worktree"
  printf 'implementation-app-task-1\n' > "$repo_state/window_name"
  printf 'implementation\n' > "$repo_state/stage"
  rm -f "$concurrent_dir/pane-live" "$concurrent_dir/pane-identity-captured"
  rm -f "$repo_state"/*.candidate.* "$repo_state"/*.validation-backup.*
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
  case "$transition" in
    handshake-timeout|commit-ack-timeout|commit-child-exit|exit-after-committed|exit-during-success|exit-after-final-ack|final-ack-timeout) attempts=2 ;;
  esac
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
    validation-release validation-release-owner validation-child-ready validation-child-accepted \
    validation-child-commit \
    validation-child-committed \
    validation-success validation-success-ack \
    validation_status validation_worktree validation_worktree_identity \
    validation_worktree_git_dir validation_worktree_git_identity validation_worktree_owner \
    validation_head validation_intent_transport \
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
assert_failed_launch_rolls_back_and_retries commit-ack-timeout
assert_failed_launch_rolls_back_and_retries commit-child-exit
assert_failed_launch_rolls_back_and_retries exit-after-committed
assert_failed_launch_rolls_back_and_retries exit-during-success
assert_failed_launch_rolls_back_and_retries exit-after-final-ack
assert_failed_launch_rolls_back_and_retries final-ack-timeout

set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  FAIL_TRANSITION=wrong-commit-ack SGT_VALIDATION_HANDSHAKE_ATTEMPTS=2 \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$(cat "$repo_state/validation-child-committed")" == wrong-ack ]]
rm -f "$repo_state/validation-child-committed"
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app >/dev/null
cleanup_validation_state

set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  FAIL_TRANSITION=checkout-delete-failure \
  SGT_VALIDATE_FAIL_TRANSITION=state-validation_pane \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *'could not remove owned validation checkout'* && \
  "$output" == *'rollback cleanup also failed'* ]]
for recovery_path in validation_worktree validation_worktree_identity \
  validation_worktree_git_dir validation_worktree_git_identity validation_worktree_owner \
  validation_head; do
  [[ -s "$repo_state/$recovery_path" ]]
done
[[ -d "$validation_path" ]]
cleanup_validation_state

set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  FAIL_TRANSITION=wrong-final-token SGT_VALIDATION_HANDSHAKE_ATTEMPTS=2 \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$(cat "$repo_state/validation-success-ack")" == wrong-final ]]
rm -f "$repo_state/validation-success-ack"
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app >/dev/null
cleanup_validation_state

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

for identity_path in "$fleet/task-1/primary_pane_identity" "$repo_state/pane_identity"; do
  saved_identity="${identity_path}.saved"
  mv "$identity_path" "$saved_identity"
  ln -s "$saved_identity" "$identity_path"
  set +e
  output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
    TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
    "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 ]]
  rm "$identity_path"
  mv "$saved_identity" "$identity_path"
  for legacy_mode in 644 664 640; do
    chmod "$legacy_mode" "$identity_path"
    PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
      TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
      "$ROOT_DIR/bin/sgt-validate" task-1 app >/dev/null
    [[ "$(stat -c '%a' "$identity_path" 2>/dev/null || stat -f '%Lp' "$identity_path")" == \
      "600" ]]
    cleanup_validation_state
  done
  for unsafe_mode in 444 700 400 666 755; do
    chmod "$unsafe_mode" "$identity_path"
    set +e
    output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
      TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
      "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
    status=$?
    set -e
    [[ "$status" -ne 0 ]]
  done
  chmod 600 "$identity_path"
done

legacy_race_marker="$TEST_ROOT/legacy-pane-race"
chmod 664 "$fleet/task-1/primary_pane_identity"
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  FAIL_TRANSITION=legacy-identity-content-race IDENTITY_RACE_MARKER="$legacy_race_marker" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app >/dev/null
[[ "$(cat "$fleet/task-1/primary_pane_identity")" == '0|%11|1111|111111|coordinator-command' ]]
[[ "$(stat -c '%a' "$fleet/task-1/primary_pane_identity" 2>/dev/null || \
  stat -f '%Lp' "$fleet/task-1/primary_pane_identity")" == "600" ]]
[[ -e "$legacy_race_marker" ]]
cleanup_validation_state

legacy_replace_marker="$TEST_ROOT/legacy-pane-replaced"
chmod 664 "$fleet/task-1/primary_pane_identity"
set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  FAIL_TRANSITION=legacy-identity-publish-replaced \
  IDENTITY_RACE_MARKER="$legacy_replace_marker" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 ]]
[[ "$(cat "$fleet/task-1/primary_pane_identity")" == "tampered-pane" ]]
[[ "$(stat -c '%a' "$fleet/task-1/primary_pane_identity" 2>/dev/null || \
  stat -f '%Lp' "$fleet/task-1/primary_pane_identity")" == "664" ]]
[[ -e "$legacy_replace_marker" ]]
printf '0|%%11|1111|111111|coordinator-command\n' > "$fleet/task-1/primary_pane_identity"
chmod 600 "$fleet/task-1/primary_pane_identity"

saved_identity="$repo_state/pane_identity.saved"
mv "$repo_state/pane_identity" "$saved_identity"
mkfifo "$repo_state/pane_identity"
set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 ]]
rm "$repo_state/pane_identity"
mv "$saved_identity" "$repo_state/pane_identity"

set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  FAIL_TRANSITION=identity-chmod-race TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 ]]
chmod 600 "$fleet/task-1/primary_pane_identity"

printf 'paired-release\n' > "$TEST_ROOT/fd-release"
chmod 600 "$TEST_ROOT/fd-release"
ln "$TEST_ROOT/fd-release" "$TEST_ROOT/fd-release-owner"
set +e
PATH="$fake_bin:$PATH" FAIL_TRANSITION=release-fifo-race \
  FIFO_PATH="$TEST_ROOT/fd-release-owner" FIFO_CONTENT=paired-release \
  bash -c 'source "$1"; _sgt_read_same_owned_files "$2" "$3"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$TEST_ROOT/fd-release" "$TEST_ROOT/fd-release-owner" \
  >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 && -p "$TEST_ROOT/fd-release-owner" ]]
rm -f "$TEST_ROOT/fd-release" "$TEST_ROOT/fd-release-owner"

set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  FAIL_TRANSITION=rollback-rm-failure \
  SGT_VALIDATE_FAIL_TRANSITION=state-validation_pane \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *'Failed to publish validation code snapshot marker'* && \
  "$output" == *'rollback cleanup also failed'* ]]
[[ -e "$repo_state/validation_worktree" ]]
cleanup_validation_state

set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  FAIL_TRANSITION=lock-release-failure \
  SGT_VALIDATE_FAIL_TRANSITION=state-validation_pane \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *'Failed to publish validation pane'* && \
  "$output" == *'could not release validation launch lock'* && \
  "$output" == *'rollback cleanup also failed'* ]]
[[ -f "$repo_state/validation-launch.lock" ]]
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app >/dev/null
cleanup_validation_state

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

# ── no-mistakes intent-transport capability probe ─────────────────────────────
# An installed no-mistakes without --intent-file must fail closed BEFORE any
# validation run, marker mutation, or state change, and the diagnostic must name
# the required capability, the observed version, and the operator's options.
before_lines="$(wc -l < "$TEST_ROOT/tmux.log")"
set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  NO_MISTAKES_NO_INTENT_FILE=1 NO_MISTAKES_FAKE_VERSION='v1.41.2 (867d64d)' \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 ]] || {
  printf 'missing --intent-file capability did not fail the launch\n' >&2
  exit 1
}
for expected in 'private intent transport' '--intent-file' 'v1.41.2 (867d64d)' \
  '--allow-argv-intent'; do
  [[ "$output" == *"$expected"* ]] || {
    printf 'capability diagnostic omitted %s: %s\n' "$expected" "$output" >&2
    exit 1
  }
done
[[ "$(wc -l < "$TEST_ROOT/tmux.log")" == "$before_lines" ]] || {
  printf 'capability probe failure reached tmux\n' >&2
  exit 1
}
for path in validation-launch.lock validation_worktree validation-intent.md \
  validation_status validation_intent_transport; do
  [[ ! -e "$repo_state/$path" ]] || {
    printf 'capability probe failure mutated %s\n' "$path" >&2
    exit 1
  }
done
[[ ! -e "$validation_path" ]] || {
  printf 'capability probe failure created a validation snapshot\n' >&2
  exit 1
}
[[ "$(cat "$repo_state/stage")" == "implementation" ]]

# The supported private transport is recorded for audit and keeps intent content
# out of the launched argv.
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app >/dev/null
[[ "$(cat "$repo_state/validation_intent_transport")" == "intent-file" ]] || {
  printf 'supported transport was not recorded: %s\n' \
    "$(cat "$repo_state/validation_intent_transport" 2>/dev/null || echo missing)" >&2
  exit 1
}
grep -Fq 'intent-file' "$concurrent_dir/validation-command"
if grep -Fq 'Validate the interactive worker safely' "$TEST_ROOT/tmux.log"; then
  printf 'supported transport leaked intent content into argv\n' >&2
  exit 1
fi
cleanup_validation_state

# The argv fallback is consent-gated: it runs only when the operator passes
# --allow-argv-intent, and the privacy tradeoff is recorded in fleet state.
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  NO_MISTAKES_NO_INTENT_FILE=1 \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app --allow-argv-intent >/dev/null
[[ "$(cat "$repo_state/validation_intent_transport")" == "argv" ]] || {
  printf 'consented argv transport was not recorded: %s\n' \
    "$(cat "$repo_state/validation_intent_transport" 2>/dev/null || echo missing)" >&2
  exit 1
}
grep -Fq 'argv' "$concurrent_dir/validation-command"
cleanup_validation_state

# --allow-argv-intent must not downgrade a build that does support --intent-file.
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app --allow-argv-intent >/dev/null
[[ "$(cat "$repo_state/validation_intent_transport")" == "intent-file" ]] || {
  printf 'consent flag downgraded a capable build\n' >&2
  exit 1
}
cleanup_validation_state

# --skip and --allow-argv-intent compose in either order, and an explicitly
# empty --skip still requests the full pipeline.
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  NO_MISTAKES_NO_INTENT_FILE=1 \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app --allow-argv-intent --skip lint >/dev/null
grep -Fq 'lint' "$concurrent_dir/validation-command"
if grep -Fq 'review,document' "$concurrent_dir/validation-command"; then
  printf 'composed flags lost the explicit skip list\n' >&2
  exit 1
fi
cleanup_validation_state

set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app --unknown-flag 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *'Usage: sgt-validate'* ]]

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

# Each absent marker field, and each unpassed review axis, reports its own cause.
ready_messages=""
for missing_field in intent_revision head_sha standards_review spec_review \
  readiness_review; do
  grep -v "^${missing_field}=" "$worktree/.sergeant-validation-ready" \
    > "$TEST_ROOT/ready-partial"
  cp "$TEST_ROOT/ready-partial" "$worktree/.sergeant-validation-ready"
  set +e
  output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
    TMUX_PANE=%11 SERGEANT_FLEET="$fleet" "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 && "$output" == *"no single non-empty $missing_field value"* ]] || {
    printf 'missing %s did not report its own cause: %s\n' "$missing_field" "$output" >&2
    exit 1
  }
  ready_messages="$ready_messages
$output"
  cat > "$worktree/.sergeant-validation-ready" <<EOF
intent_revision=$revision
head_sha=$head_sha
standards_review=passed
spec_review=passed
readiness_review=passed
EOF
done
for failed_axis in standards spec readiness; do
  sed "s/^${failed_axis}_review=passed/${failed_axis}_review=blocked/" \
    "$worktree/.sergeant-validation-ready" > "$TEST_ROOT/ready-axis"
  cp "$TEST_ROOT/ready-axis" "$worktree/.sergeant-validation-ready"
  set +e
  output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
    TMUX_PANE=%11 SERGEANT_FLEET="$fleet" "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 && "$output" == *"${failed_axis}_review=blocked"* ]] || {
    printf 'unpassed %s review did not report its own cause: %s\n' "$failed_axis" "$output" >&2
    exit 1
  }
  ready_messages="$ready_messages
$output"
  cat > "$worktree/.sergeant-validation-ready" <<EOF
intent_revision=$revision
head_sha=$head_sha
standards_review=passed
spec_review=passed
readiness_review=passed
EOF
done
[[ "$(printf '%s\n' "$ready_messages" | grep -c .)" == \
  "$(printf '%s\n' "$ready_messages" | grep . | sort -u | wc -l)" ]] || {
  printf 'validation-ready diagnostics are not distinct\n' >&2
  exit 1
}

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
# ── coordinator ownership: distinct diagnostics and verified handover ─────────
# Each precondition failure must name its own cause, because each has a
# different remedy. No failure may reach tmux or mutate ownership records.
ownership_flags=()
assert_ownership_failure() {
  local expected="$1"
  shift
  local output status before_mutations before_id before_identity
  # Ownership resolution legitimately reads tmux; it must never mutate it.
  before_mutations="$(grep -Ec '^(split-window|new-window|rename-window|kill-pane)' \
    "$TEST_ROOT/tmux.log" || true)"
  before_id="$(cat "$fleet/task-1/primary_pane_id" 2>/dev/null || true)"
  before_identity="$(cat "$fleet/task-1/primary_pane_identity" 2>/dev/null || true)"
  set +e
  output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
    SERGEANT_FLEET="$fleet" "$@" "$ROOT_DIR/bin/sgt-validate" task-1 app \
    ${ownership_flags[@]+"${ownership_flags[@]}"} 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || {
    printf 'expected ownership failure %s but the launch succeeded\n' "$expected" >&2
    exit 1
  }
  [[ "$output" == *"$expected"* ]] || {
    printf 'expected ownership diagnostic %s, got: %s\n' "$expected" "$output" >&2
    exit 1
  }
  [[ "$(grep -Ec '^(split-window|new-window|rename-window|kill-pane)' \
    "$TEST_ROOT/tmux.log" || true)" == "$before_mutations" ]] || {
    printf 'ownership failure %s mutated tmux\n' "$expected" >&2
    exit 1
  }
  [[ "$(cat "$fleet/task-1/primary_pane_id" 2>/dev/null || true)" == "$before_id" && \
    "$(cat "$fleet/task-1/primary_pane_identity" 2>/dev/null || true)" == \
    "$before_identity" ]] || {
    printf 'ownership failure %s mutated the ownership records\n' "$expected" >&2
    exit 1
  }
  ownership_messages="$ownership_messages
$expected"
}
ownership_messages=""

assert_ownership_failure 'TMUX_PANE is not set' env -u TMUX_PANE
assert_ownership_failure 'dispatching pane %11 is still live' env TMUX_PANE=%12
assert_ownership_failure 'is gone; claim it with --claim-ownership' \
  env TMUX_PANE=%12 PRIMARY_PANE_STATE=dead
# A live dispatching pane whose identity no longer matches the dispatch record is
# a recycled pane, not a live owner and not an absent pane.
assert_ownership_failure 'no longer matches the dispatch record' \
  env TMUX_PANE=%12 PRIMARY_PANE_STATE=recycled
assert_ownership_failure 'was recycled' env TMUX_PANE=%11 PRIMARY_PANE_STATE=recycled

mv "$fleet/task-1/primary_pane_id" "$TEST_ROOT/saved-primary-pane-id"
assert_ownership_failure 'did not record a coordinator pane' env TMUX_PANE=%11
printf 'not-a-pane\n' > "$fleet/task-1/primary_pane_id"
assert_ownership_failure 'Recorded coordinator pane ID is malformed' env TMUX_PANE=%11
mv "$TEST_ROOT/saved-primary-pane-id" "$fleet/task-1/primary_pane_id"

mv "$fleet/task-1/primary_pane_identity" "$TEST_ROOT/saved-primary-identity"
assert_ownership_failure 'coordinator pane identity was never recorded' env TMUX_PANE=%11
printf 'unsafe\n' > "$fleet/task-1/primary_pane_identity"
chmod 606 "$fleet/task-1/primary_pane_identity"
assert_ownership_failure 'unreadable or unsafely owned' env TMUX_PANE=%11
rm -f "$fleet/task-1/primary_pane_identity"
mv "$TEST_ROOT/saved-primary-identity" "$fleet/task-1/primary_pane_identity"

# A claim is refused while the dispatching pane is still live and unreleased, and
# refused when the claimant cannot prove it runs in the pane it names - even
# though the dispatching pane really is gone.
ownership_flags=(--claim-ownership)
assert_ownership_failure 'still live and has not released ownership' env TMUX_PANE=%12
assert_ownership_failure 'cannot prove it runs in pane %13' \
  env TMUX_PANE=%13 PRIMARY_PANE_STATE=gone
assert_ownership_failure 'is not a live tmux pane' \
  env TMUX_PANE=%99 PRIMARY_PANE_STATE=dead
ownership_flags=()

# Every diagnostic above must be distinct from every other.
[[ "$(printf '%s\n' "$ownership_messages" | grep -c .)" == \
  "$(printf '%s\n' "$ownership_messages" | grep . | sort -u | wc -l)" ]] || {
  printf 'ownership diagnostics are not distinct\n' >&2
  exit 1
}

# A verified claim over a dead dispatching pane transfers ownership, records the
# transfer with both identities, and lets validation proceed.
prior_identity="$(cat "$fleet/task-1/primary_pane_identity")"
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%12 PRIMARY_PANE_STATE=dead SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app --claim-ownership >/dev/null
[[ "$(cat "$fleet/task-1/primary_pane_id")" == "%12" ]]
[[ "$(cat "$fleet/task-1/primary_pane_identity")" == "0|%12|$CLAIM_PANE_PID|121212|claim-coordinator-command" ]]
[[ "$(stat -c '%a' "$fleet/task-1/primary_pane_identity" 2>/dev/null || \
  stat -f '%Lp' "$fleet/task-1/primary_pane_identity")" == "600" ]]
handover_log="$fleet/task-1/coordinator_handover.log"
[[ -f "$handover_log" ]]
[[ "$(stat -c '%a' "$handover_log" 2>/dev/null || stat -f '%Lp' "$handover_log")" == "600" ]] || {
  printf 'handover audit log is not owner-only\n' >&2
  exit 1
}
grep -Fq "prior_pane=%11" "$handover_log"
grep -Fq "prior_identity=$prior_identity" "$handover_log"
grep -Fq "new_pane=%12" "$handover_log"
grep -Fq "reason=dispatching-pane-dead" "$handover_log"
[[ "$(cat "$repo_state/validation_status")" == "launched" ]]
cleanup_validation_state

# A recycled dispatching pane is claimable, and the audit names that reason.
printf '%%11\n' > "$fleet/task-1/primary_pane_id"
bash -c 'source "$1"; _sgt_replace_owned_file "$2" "$3"' _ "$ROOT_DIR/bin/_sgt-lib.sh" \
  "$fleet/task-1/primary_pane_identity" '0|%11|1111|111111|coordinator-command'
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%12 PRIMARY_PANE_STATE=recycled SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app --claim-ownership >/dev/null
[[ "$(cat "$fleet/task-1/primary_pane_id")" == "%12" ]]
grep -Fq 'reason=dispatching-pane-recycled' "$fleet/task-1/coordinator_handover.log"
cleanup_validation_state

# The new owner validates from its own pane without claiming again.
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%12 PRIMARY_PANE_STATE=dead SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app >/dev/null
cleanup_validation_state
[[ "$(wc -l < "$handover_log")" == "2" ]]

# Restore %11 ownership for the release-path checks.
printf '%%11\n' > "$fleet/task-1/primary_pane_id"
bash -c 'source "$1"; _sgt_replace_owned_file "$2" "$3"' _ "$ROOT_DIR/bin/_sgt-lib.sh" \
  "$fleet/task-1/primary_pane_identity" '0|%11|1111|111111|coordinator-command'

# A live owner can hand over deliberately by releasing ownership first.
set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%12 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app --release-ownership 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *'Only the recorded coordinator pane can release ownership'* ]]
[[ ! -e "$fleet/task-1/primary_pane_released" ]]

before_mutations="$(grep -Ec '^(split-window|new-window|rename-window|kill-pane)' \
  "$TEST_ROOT/tmux.log" || true)"
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app --release-ownership >/dev/null
[[ "$(cat "$fleet/task-1/primary_pane_released")" == "0|%11|1111|111111|coordinator-command" ]]
[[ "$(grep -Ec '^(split-window|new-window|rename-window|kill-pane)' \
  "$TEST_ROOT/tmux.log" || true)" == "$before_mutations" ]] || {
  printf 'releasing ownership launched validation\n' >&2
  exit 1
}
[[ ! -e "$repo_state/validation_status" ]]

# The released owner is still live, and the claim now succeeds.
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%12 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app --claim-ownership >/dev/null
[[ "$(cat "$fleet/task-1/primary_pane_id")" == "%12" ]]
grep -Fq 'reason=released-by-owner' "$handover_log"
# The release is consumed, so a third pane cannot replay it.
[[ ! -e "$fleet/task-1/primary_pane_released" ]]
cleanup_validation_state

# --claim-ownership and --release-ownership are mutually exclusive.
set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%12 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app --claim-ownership --release-ownership 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *'mutually exclusive'* ]]

# Releasing ownership launches nothing, so launch-only options are refused rather
# than silently ignored.
for release_conflict in --skip:lint --allow-argv-intent:; do
  set +e
  output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
    TMUX_PANE=%11 SERGEANT_FLEET="$fleet" "$ROOT_DIR/bin/sgt-validate" task-1 app \
    --release-ownership "${release_conflict%%:*}" ${release_conflict#*:} 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 && "$output" == *'does not launch validation'* ]] || {
    printf '%s was silently ignored with --release-ownership: %s\n' \
      "${release_conflict%%:*}" "$output" >&2
    exit 1
  }
done

# An interrupted handover leaves recoverable state: a later claim from the same
# verified pane completes the transfer instead of stranding it.
printf '%%11\n' > "$fleet/task-1/primary_pane_id"
bash -c 'source "$1"; _sgt_replace_owned_file "$2" "$3"' _ "$ROOT_DIR/bin/_sgt-lib.sh" \
  "$fleet/task-1/primary_pane_identity" '0|%11|1111|111111|coordinator-command'
: > "$handover_log"
set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  SGT_VALIDATE_FAIL_TRANSITION=handover-pane-id \
  TMUX_PANE=%12 PRIMARY_PANE_STATE=dead SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app --claim-ownership 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *'Failed to publish coordinator ownership'* ]]
[[ "$(cat "$fleet/task-1/primary_pane_id")" == "%11" ]]
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%12 PRIMARY_PANE_STATE=dead SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app --claim-ownership >/dev/null
[[ "$(cat "$fleet/task-1/primary_pane_id")" == "%12" ]]
cleanup_validation_state

printf '%%11\n' > "$fleet/task-1/primary_pane_id"
bash -c 'source "$1"; _sgt_replace_owned_file "$2" "$3"' _ "$ROOT_DIR/bin/_sgt-lib.sh" \
  "$fleet/task-1/primary_pane_identity" '0|%11|1111|111111|coordinator-command'
rm -f "$handover_log"

# An audit log that is not owner-only cannot be trusted to record the transfer, so
# the handover fails closed and the existing log is preserved untouched.
printf 'preexisting-audit\n' > "$handover_log"
chmod 644 "$handover_log"
set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%12 PRIMARY_PANE_STATE=dead SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app --claim-ownership 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *'Failed to record coordinator ownership handover'* ]]
[[ "$(cat "$handover_log")" == "preexisting-audit" ]]
[[ "$(cat "$fleet/task-1/primary_pane_id")" == "%11" ]]
rm -f "$handover_log"

# An owner that resumes validating revokes a pending release, so a later claim is
# refused again.
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app --release-ownership >/dev/null
[[ -e "$fleet/task-1/primary_pane_released" ]]
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app >/dev/null
[[ ! -e "$fleet/task-1/primary_pane_released" ]] || {
  printf 'a resuming owner did not revoke its pending release\n' >&2
  exit 1
}
cleanup_validation_state
set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%12 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app --claim-ownership 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *'still live and has not released ownership'* ]]

# The recorded coordinator identity must not change between the reads that verify
# it; a pane replaced mid-verification is reported, not silently accepted.
rm -f "$concurrent_dir/primary-reads"
set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  PRIMARY_PANE_FLIP=2 TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *'changed while ownership was being verified'* ]] || {
  printf 'a pane replaced mid-verification was not reported: %s\n' "$output" >&2
  exit 1
}
rm -f "$concurrent_dir/primary-reads"

# The durable transport audit survives a retry reset, which clears the per-run
# transport record.
transport_log="$repo_state/validation_transport.log"
rm -f "$transport_log"
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  NO_MISTAKES_NO_INTENT_FILE=1 TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app --allow-argv-intent >/dev/null
grep -Fq 'transport=argv' "$transport_log"
grep -Fq "head=$head_sha" "$transport_log"
[[ "$(stat -c '%a' "$transport_log" 2>/dev/null || stat -f '%Lp' "$transport_log")" == "600" ]]
printf 'exited:0\n' > "$repo_state/validation_status"
rm -f "$concurrent_dir/pane-live"
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-validate" task-1 app >/dev/null
[[ "$(wc -l < "$transport_log")" == "2" ]] || {
  printf 'the durable transport audit did not survive the retry reset: %s\n' \
    "$(cat "$transport_log")" >&2
  exit 1
}
grep -Fq 'transport=argv' "$transport_log"
grep -Fq 'transport=intent-file' "$transport_log"
cleanup_validation_state
rm -f "$transport_log"

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
[[ "$status" -ne 0 && "$output" == *'records a stale head_sha'* ]]
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
