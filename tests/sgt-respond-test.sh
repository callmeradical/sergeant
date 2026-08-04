#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
TMUX_KILLED_DIR="$TEST_ROOT/killed-panes"
mkdir -p "$TMUX_KILLED_DIR"
export TMUX_KILLED_DIR

run_in_pty() {
  python3 -c '
import errno
import os
import pty
import sys

payload = sys.stdin.buffer.read()
pid, master = pty.fork()
if pid == 0:
    os.execvpe(sys.argv[1], sys.argv[1:], os.environ)

offset = 0
while offset < len(payload):
    try:
        offset += os.write(master, payload[offset:])
    except InterruptedError:
        continue

while True:
    try:
        chunk = os.read(master, 4096)
        if not chunk:
            break
        os.write(sys.stdout.fileno(), chunk)
    except OSError as error:
        if error.errno == errno.EIO:
            break
        raise

_, status = os.waitpid(pid, 0)
os.close(master)
if os.WIFEXITED(status):
    raise SystemExit(os.WEXITSTATUS(status))
raise SystemExit(128 + os.WTERMSIG(status))
' "$@"
}

fleet="$TEST_ROOT/fleet"
repo_state="$fleet/task-1/app"
worktree="$TEST_ROOT/worktree"
source_repo="$TEST_ROOT/source"
fake_bin="$TEST_ROOT/fake-bin"
config_dir="$TEST_ROOT/config"
mkdir -p "$repo_state" "$source_repo" "$fake_bin" "$config_dir"
export SERGEANT_CONFIG="$config_dir"
git -C "$source_repo" init -q
git -C "$source_repo" config user.name Test
git -C "$source_repo" config user.email test@example.invalid
touch "$source_repo/README.md"
git -C "$source_repo" add README.md
git -C "$source_repo" commit -qm fixture
git -C "$source_repo" worktree add -q -b response-test "$worktree"
worktree="$(cd "$worktree" && pwd -P)"
cat > "$config_dir/test.yaml" <<EOF
repos:
  - name: app
    path: $source_repo
  - name: replacement
    path: $source_repo
EOF
printf 'Project: test\nBrief: fixture\nBranch: response-test\nRepos: app replacement\n' \
  > "$fleet/task-1/brief.md"
printf '%s\n' "$worktree" > "$repo_state/worktree"
cat "$worktree/.git" > "$repo_state/worktree_git_pointer"
worktree_git_dir="$(sed 's/^gitdir: //' "$worktree/.git")"
printf '%s\n' "$(cd "$worktree_git_dir" && pwd -P)" > "$repo_state/worktree_git_dir"
printf -v expected_worker_command '%q %q %q %q' \
  "$ROOT_DIR/bin/sgt-interactive-worker" "$repo_state" "$worktree" fake-opencode
EXPECTED_PANE_IDENTITY="0|%42|4242|123456|$expected_worker_command"
export EXPECTED_PANE_IDENTITY
printf '%%42\n' > "$repo_state/pane"
printf '%s\n' "$EXPECTED_PANE_IDENTITY" > "$repo_state/pane_identity"
chmod 600 "$repo_state/pane_identity"
printf 'sgt\n' > "$repo_state/tmux_session"
printf 'task/app\n' > "$repo_state/window_name"
printf 'fake-opencode\n' > "$repo_state/agent"
printf 'initial mission\n' > "$repo_state/initial_message"
printf 'needs_input\n' > "$worktree/.sergeant-status"
printf 'needs_input\n' > "$repo_state/status"
printf '1\n' > "$worktree/.sergeant-gate-generation"
cat > "$fleet/task-1/.sergeant-intent.md" <<'EOF'
## Objective

Resume safely.
EOF
cp "$fleet/task-1/.sergeant-intent.md" "$repo_state/.sergeant-intent.md"
cp "$fleet/task-1/.sergeant-intent.md" "$worktree/.sergeant-intent.md"
bash -c 'source "$1"; _sgt_intent_revision "$2"' _ \
  "$ROOT_DIR/bin/_sgt-intent.sh" "$fleet/task-1/.sergeant-intent.md" \
  > "$fleet/task-1/intent_revision"
cp "$fleet/task-1/intent_revision" "$repo_state/intent_revision"
cat > "$worktree/.sergeant-brief.md" <<EOF
**Task ID:** task-1
**Project:** test
**Repo:** app
**Branch:** response-test
**Worktree:** $worktree
**Fleet state:** $repo_state/
EOF

cat > "$fake_bin/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_LOG"
case "$1" in
  display-message)
    [[ "${PANE_ALIVE:-0}" == 1 ]] || exit 1
    target=""
    previous=""
    for argument in "$@"; do
      [[ "$previous" == -t ]] && target="$argument"
      previous="$argument"
    done
    [[ ! -e "$TMUX_KILLED_DIR/${target#%}" ]] || exit 1
    pane_identity="${PANE_IDENTITY:-$EXPECTED_PANE_IDENTITY}"
    if [[ "$target" == "${NEW_PANE:-%99}" ]]; then
      expected_remainder="${EXPECTED_PANE_IDENTITY#*|}"
      expected_remainder="${expected_remainder#*|}"
      expected_remainder="${expected_remainder#*|}"
      expected_command="${expected_remainder#*|}"
      pane_identity="0|$target|9999|654321|$expected_command"
      if [[ "${REQUIRE_FRESH_ACK:-0}" == 1 &&
            -e "$(cat "$EXPECTED_WORKER/worktree")/.sergeant-notification-ack" &&
            ! -e "$EXPECTED_WORKER/notification_delivered_pane_identity" ]]; then
        exit 31
      fi
    fi
    deliver=true
    if [[ -n "${DELIVER_COUNT_FILE:-}" && "$target" == "${NEW_PANE:-%99}" ]]; then
      count=0
      [[ ! -f "$DELIVER_COUNT_FILE" ]] || count="$(cat "$DELIVER_COUNT_FILE")"
      count=$((count + 1))
      printf '%s\n' "$count" > "$DELIVER_COUNT_FILE"
      [[ "$count" -ge "${DELIVER_AFTER:-1}" ]] || deliver=false
    fi
    if [[ "$target" == "${NEW_PANE:-%99}" && "${STALE_SUPERVISOR_ACK:-0}" == 1 &&
          "${count:-0}" == 2 && -s "$EXPECTED_WORKER/notification_id" ]]; then
      notification_id="$(cat "$EXPECTED_WORKER/notification_id")"
      notification_worktree="$(cat "$EXPECTED_WORKER/worktree")"
      printf '%s|0|%%99|9999|654321|stale-supervisor\n' "$notification_id" \
        > "$notification_worktree/.sergeant-notification-ack"
      printf '0|%%99|9999|654321|stale-supervisor\n' \
        > "$EXPECTED_WORKER/notification_delivered_pane_identity"
      printf '%s\n' "$notification_id" > "$EXPECTED_WORKER/notification_delivered"
    fi
    if [[ "${REQUIRE_LOCK_RELEASE:-0}" == 1 &&
          -e "$EXPECTED_WORKER/response.lock" ]]; then
      touch "$LOCK_HELD_MARKER"
    elif [[ "${AUTO_DELIVER:-1}" == 1 && "$deliver" == true &&
            "${pane_identity%%|*}" == "0" && -s "$EXPECTED_WORKER/notification_id" ]]; then
      if [[ "${REQUIRE_TARGET:-0}" == 1 ]]; then
        _rt_nonce="$(cat "$EXPECTED_WORKER/notification_target" 2>/dev/null || true)"
        _rt_id="$(cat "$EXPECTED_WORKER/notification_id" 2>/dev/null || true)"
        _rt_identity=""
        if [[ -n "$_rt_id" && "$_rt_nonce" =~ ^[a-f0-9]{32}$ ]]; then
          _rt_identity="$(cat "$EXPECTED_WORKER/notifications/$_rt_id/targets/$_rt_nonce/pane_identity" 2>/dev/null || true)"
        fi
        if [[ "$_rt_identity" != "$pane_identity" ]]; then
          exit 32
        fi
      fi
      notification_id="$(cat "$EXPECTED_WORKER/notification_id")"
      notification_worktree="$(cat "$EXPECTED_WORKER/worktree")"
      nonce="$(cat "$EXPECTED_WORKER/notification_target" 2>/dev/null || true)"
      if [[ "$nonce" =~ ^[a-f0-9]{32}$ ]]; then
        token="$notification_id|$nonce"
        target_dir="$EXPECTED_WORKER/notifications/$notification_id/targets/$nonce"
        mkdir -p "$notification_worktree/.sergeant-notification-acks" \
          "$notification_worktree/.sergeant-notification-accepts"
        printf '%s\n' "$token" > "$notification_worktree/.sergeant-notification-acks/$nonce"
        printf '%s\n' "$token" > "$notification_worktree/.sergeant-notification-accepts/$nonce"
        printf '%s\n' "$token" > "$target_dir/accepted"
        printf '%s\n' "$token" > "$target_dir/delivered"
        printf '%s\n' "$pane_identity" > "$EXPECTED_WORKER/notification_delivered_pane_identity"
        printf '%s\n' "$notification_id" > "$EXPECTED_WORKER/notification_delivered"
      fi
    fi
    printf '%s\n' "$pane_identity"
    ;;
  new-window)
    [[ "${FAIL_WINDOW:-0}" == 0 ]] || exit 7
    [[ "${EMPTY_WINDOW:-0}" == 0 ]] || exit 0
    printf '%s\n' "${NEW_PANE:-%99}"
    ;;
  list-panes)
    current_identity="${PANE_IDENTITY:-$EXPECTED_PANE_IDENTITY}"
    if [[ "${PANE_ALIVE:-0}" == "1" && "${current_identity%%|*}" == "0" ]]; then
      if [[ "${!#}" == '#{pane_id}' ]]; then
        current_remainder="${current_identity#*|}"
        printf '%s\n' "${current_remainder%%|*}"
      else
        printf '%s\n' "$current_identity"
      fi
    fi
    ;;
  kill-pane)
    target="${!#}"
    if [[ "${FAIL_KILL_PANE:-}" == "all" ||
          ( -n "${FAIL_KILL_PANE:-}" && "$target" == "$FAIL_KILL_PANE" ) ]]; then
      exit 9
    fi
    : > "$TMUX_KILLED_DIR/${target#%}"
    ;;
  send-keys) exit 0 ;;
esac
EOF
chmod +x "$fake_bin/tmux"
cat > "$fake_bin/td" <<'EOF'
#!/usr/bin/env bash
[[ ! -e "$TD_RESPONSE_FILE" ]] || {
  printf 'response was delivered before td decision log\n' >&2
  exit 1
}
printf '%s\n' "$*" >> "$TD_LOG"
EOF
chmod +x "$fake_bin/td"
export TEST_SOURCE_REPO="$source_repo"
cat > "$fake_bin/yq" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  '.repos | length') printf '2\n' ;;
  '.repos[0].name') printf 'app\n' ;;
  '.repos[1].name') printf 'replacement\n' ;;
  '.repos[0].path'|'.repos[1].path') printf '%s\n' "$TEST_SOURCE_REPO" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$fake_bin/yq"
printf 'td-123\n' > "$repo_state/td_task"

real_mv="$(command -v mv)"
cat > "$fake_bin/mv" <<'EOF'
#!/usr/bin/env bash
target=""
for argument in "$@"; do
  target="$argument"
done
if [[ -n "${FAIL_PUBLISH_TARGET:-}" && "$target" == "$FAIL_PUBLISH_TARGET" ]]; then
  exit 23
fi
if [[ "${REQUIRE_REVOKED_BEFORE_NOTIFICATION:-0}" == 1 &&
      "$target" == "$EXPECTED_WORKER/notification_id" &&
      -e "$EXPECTED_WORKER/notification_target" ]]; then
  exit 24
fi
exec "${REAL_MV:-/bin/mv}" "$@"
EOF
chmod +x "$fake_bin/mv"

respond() {
  local response_body="$1"
  printf '%s' "$response_body" | "$ROOT_DIR/bin/sgt-respond" task-1 app
}

assert_publication_failure() {
  local target="$1"
  local label="$2"
  local status

  rm -f "$repo_state/response" "$repo_state/response_generation" "$repo_state/response_id" \
    "$worktree/.sergeant-response" "$worktree/.sergeant-response-generation" \
    "$worktree/.sergeant-response-id"
  set +e
  PATH="$fake_bin:$PATH" REAL_MV="$real_mv" FAIL_PUBLISH_TARGET="$target" \
    TMUX_LOG="$TEST_ROOT/publication-$label.log" TD_LOG="$TEST_ROOT/publication-$label-td.log" \
    TD_RESPONSE_FILE="$worktree/.sergeant-response" PANE_ALIVE=1 EXPECTED_WORKER="$repo_state" \
    SERGEANT_FLEET="$fleet" respond "publication failure $label" >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || {
    printf 'response publication unexpectedly succeeded at %s\n' "$label" >&2
    exit 1
  }
  [[ "$(cat "$repo_state/replacement_phase")" == "response-pending" ]]
  if [[ -e "$worktree/.sergeant-response" ]]; then
    [[ -s "$repo_state/response_generation" && -s "$repo_state/response_id" && \
       -s "$worktree/.sergeant-response-generation" && -s "$worktree/.sergeant-response-id" ]]
    [[ "$(cat "$repo_state/response_id")" == "$(cat "$worktree/.sergeant-response-id")" ]]
    [[ "$(cat "$repo_state/response_generation")" == \
       "$(cat "$worktree/.sergeant-response-generation")" ]]
  fi
  [[ ! -e "$TEST_ROOT/publication-$label.log" ]] || \
    ! grep -Fq 'send-keys' "$TEST_ROOT/publication-$label.log"
}

assert_publication_failure "$repo_state/response_generation" fleet-generation
assert_publication_failure "$repo_state/response_id" fleet-id
assert_publication_failure "$worktree/.sergeant-response-generation" worktree-generation
assert_publication_failure "$worktree/.sergeant-response-id" worktree-id
assert_publication_failure "$repo_state/response" fleet-response
assert_publication_failure "$worktree/.sergeant-response" worktree-response
rm -f "$repo_state/response" "$repo_state/response_generation" "$repo_state/response_id" \
  "$repo_state/response_td_recorded" "$repo_state/replacement_phase" \
  "$worktree/.sergeant-response" "$worktree/.sergeant-response-generation" \
  "$worktree/.sergeant-response-id"

set +e
printf 'retry exact response' | PATH="$fake_bin:$PATH" REAL_MV="$real_mv" \
  FAIL_PUBLISH_TARGET="$worktree/.sergeant-response" \
  TMUX_LOG="$TEST_ROOT/retry-first.log" TD_LOG="$TEST_ROOT/retry-td.log" \
  TD_RESPONSE_FILE="$worktree/.sergeant-response" PANE_ALIVE=1 \
  EXPECTED_WORKER="$repo_state" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-respond" task-1 app >/dev/null 2>&1
retry_first_status=$?
set -e
[[ "$retry_first_status" -ne 0 ]]
retry_response_id="$(cat "$repo_state/response_id")"
printf 'retry exact response' | PATH="$fake_bin:$PATH" REAL_MV="$real_mv" \
  TMUX_LOG="$TEST_ROOT/retry-second.log" TD_LOG="$TEST_ROOT/retry-td.log" \
  TD_RESPONSE_FILE="$worktree/.sergeant-response" PANE_ALIVE=1 \
  EXPECTED_WORKER="$repo_state" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-respond" task-1 app >/dev/null
[[ "$(cat "$repo_state/response_id")" == "$retry_response_id" ]]
[[ "$(cat "$repo_state/response")" == 'retry exact response' ]]
[[ "$(grep -Fc 'log td-123' "$TEST_ROOT/retry-td.log")" == '1' ]]
[[ ! -e "$repo_state/replacement_phase" ]]
rm -f "$repo_state/response" "$repo_state/response_generation" "$repo_state/response_id" \
  "$repo_state/response_td_recorded" "$worktree/.sergeant-response" \
  "$worktree/.sergeant-response-generation" "$worktree/.sergeant-response-id"

set +e
printf 'resume one delivery target' | PATH="$fake_bin:$PATH" \
  TMUX_LOG="$TEST_ROOT/inflight-first.log" TD_LOG="$TEST_ROOT/inflight-td.log" \
  TD_RESPONSE_FILE="$worktree/.sergeant-response" PANE_ALIVE=1 AUTO_DELIVER=0 \
  SGT_NOTIFICATION_ACK_TIMEOUT=0 EXPECTED_WORKER="$repo_state" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-respond" task-1 app >/dev/null 2>&1
inflight_first_status=$?
set -e
[[ "$inflight_first_status" -ne 0 ]]
inflight_response_id="$(cat "$repo_state/response_id")"
inflight_nonce="$(cat "$repo_state/notification_target")"
printf 'resume one delivery target' | PATH="$fake_bin:$PATH" \
  TMUX_LOG="$TEST_ROOT/inflight-second.log" TD_LOG="$TEST_ROOT/inflight-td.log" \
  TD_RESPONSE_FILE="$worktree/.sergeant-response" PANE_ALIVE=1 \
  EXPECTED_WORKER="$repo_state" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-respond" task-1 app >/dev/null
[[ "$(cat "$repo_state/response_id")" == "$inflight_response_id" ]]
[[ "$(cat "$repo_state/notification_target")" == "$inflight_nonce" ]]
[[ "$(find "$repo_state/notifications/$inflight_response_id/targets" -mindepth 1 \
  -maxdepth 1 -type d | wc -l | tr -d ' ')" == '1' ]]
[[ ! -e "$repo_state/replacement_phase" ]]
rm -f "$repo_state/response" "$repo_state/response_generation" "$repo_state/response_id" \
  "$repo_state/response_td_recorded" "$worktree/.sergeant-response" \
  "$worktree/.sergeant-response-generation" "$worktree/.sergeant-response-id"

# A stored response with no relaunch metadata is a completed publication path,
# not an active pane replacement. Preserve the response and clear its phase.
rm -f "$repo_state/notification_id" "$repo_state/notification_target" \
  "$repo_state/notification_delivered" "$repo_state/notification_delivered_pane_identity" \
  "$worktree/.sergeant-notification"
rm -rf "$repo_state/notifications"
printf 'needs_input\n' > "$repo_state/status"
printf 'needs_input\n' > "$worktree/.sergeant-status"
printf 'worker replacement journal is unreadable; reconciliation required\n' \
  > "$repo_state/diagnostic"
rm -f "$repo_state/tmux_session" "$repo_state/window_name"
incomplete_output="$(printf 'stored without relaunch metadata' | PATH="$fake_bin:$PATH" \
  TMUX_LOG="$TEST_ROOT/incomplete-metadata.log" \
  TD_LOG="$TEST_ROOT/incomplete-metadata-td.log" \
  TD_RESPONSE_FILE="$worktree/.sergeant-response" PANE_ALIVE=0 \
  EXPECTED_WORKER="$repo_state" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-respond" task-1 app)"
[[ "$incomplete_output" == *'no live local pane and relaunch metadata is incomplete'* ]]
[[ "$(cat "$repo_state/response")" == 'stored without relaunch metadata' ]]
[[ "$(cat "$worktree/.sergeant-response")" == 'stored without relaunch metadata' ]]
[[ ! -e "$repo_state/replacement_phase" ]]
[[ ! -e "$repo_state/diagnostic" ]]
printf 'sgt\n' > "$repo_state/tmux_session"
printf 'task/app\n' > "$repo_state/window_name"
rm -f "$repo_state/response" "$repo_state/response_generation" "$repo_state/response_id" \
  "$repo_state/response_td_recorded" "$repo_state/notification_id" \
  "$repo_state/notification_target" "$repo_state/replacement_phase" \
  "$worktree/.sergeant-response" "$worktree/.sergeant-response-generation" \
  "$worktree/.sergeant-response-id" "$worktree/.sergeant-notification"

set +e
output="$(SERGEANT_FLEET="$fleet" "$ROOT_DIR/bin/sgt-respond" task-1 app 'argv body rejected' 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *'reads the response from standard input'* ]]
[[ ! -e "$repo_state/response" && ! -e "$worktree/.sergeant-response" ]]

rm -f "$repo_state/worktree_git_pointer" "$repo_state/worktree_git_dir" \
  "$repo_state/.sergeant-intent.md" "$repo_state/intent_revision" \
  "$worktree/.sergeant-intent.md"
printf 'response-test\n' > "$repo_state/branch"
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/legacy.log" TD_LOG="$TEST_ROOT/legacy-td.log" \
  TD_RESPONSE_FILE="$worktree/.sergeant-response" PANE_ALIVE=1 EXPECTED_WORKER="$repo_state" \
  SERGEANT_FLEET="$fleet" respond 'legacy response' >/dev/null
[[ -s "$repo_state/worktree_git_pointer" && -s "$repo_state/worktree_git_dir" ]]
cmp -s "$fleet/task-1/.sergeant-intent.md" "$repo_state/.sergeant-intent.md"
cmp -s "$fleet/task-1/.sergeant-intent.md" "$worktree/.sergeant-intent.md"
cmp -s "$fleet/task-1/intent_revision" "$repo_state/intent_revision"
grep -Fq 'branch=response-test' "$repo_state/legacy-response-migration"
grep -Fq "worktree=$worktree" "$repo_state/legacy-response-migration"
rm -f "$repo_state/response" "$repo_state/response_id" "$repo_state/response_generation" \
  "$repo_state/notification_id" "$repo_state/notification_delivered" \
  "$worktree/.sergeant-response" "$worktree/.sergeant-response-id" \
  "$worktree/.sergeant-response-generation" "$worktree/.sergeant-notification"

replacement_source="$TEST_ROOT/replacement-source"
replacement_worktree="$TEST_ROOT/replacement-worktree"
replacement_state="$fleet/task-1/replacement"
mkdir -p "$replacement_source" "$replacement_state"
git -C "$replacement_source" init -q
git -C "$replacement_source" config user.name Test
git -C "$replacement_source" config user.email test@example.invalid
touch "$replacement_source/README.md"
git -C "$replacement_source" add README.md
git -C "$replacement_source" commit -qm fixture
git -C "$replacement_source" worktree add -q -b response-test "$replacement_worktree"
cat > "$config_dir/evil.yaml" <<EOF
repos:
  - name: replacement
    path: $replacement_source
EOF
printf '%s\n' "$replacement_worktree" > "$replacement_state/worktree"
printf 'response-test\n' > "$replacement_state/branch"
printf 'needs_input\n' > "$replacement_state/status"
printf 'needs_input\n' > "$replacement_worktree/.sergeant-status"
printf '1\n' > "$replacement_worktree/.sergeant-gate-generation"
cat > "$replacement_worktree/.sergeant-brief.md" <<EOF
**Task ID:** task-1
**Project:** evil
**Repo:** replacement
**Branch:** response-test
**Worktree:** $replacement_worktree
**Fleet state:** $replacement_state/
EOF
set +e
replacement_output="$(printf 'replacement response' | PATH="$fake_bin:$PATH" \
  TMUX_LOG="$TEST_ROOT/replacement.log" TD_LOG="$TEST_ROOT/replacement-td.log" \
  TD_RESPONSE_FILE="$replacement_worktree/.sergeant-response" PANE_ALIVE=0 \
  EXPECTED_WORKER="$replacement_state" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-respond" task-1 replacement 2>&1)"
replacement_status=$?
set -e
[[ "$replacement_status" -ne 0 && "$replacement_output" == *'owned checkout'* ]]
[[ ! -e "$replacement_state/worktree_git_pointer" && \
   ! -e "$replacement_state/.sergeant-intent.md" && \
   ! -e "$replacement_worktree/.sergeant-response" ]]

for newline_case in zero one multiple; do
  expected_response="$TEST_ROOT/response-$newline_case"
  case "$newline_case" in
    zero) printf 'multiline approval\ncode block end' > "$expected_response" ;;
    one) printf 'multiline approval\ncode block end\n' > "$expected_response" ;;
    multiple) printf 'multiline approval\ncode block end\n\n\n' > "$expected_response" ;;
  esac
  rm -f "$repo_state/response" "$repo_state/response_id" "$repo_state/response_generation" \
    "$repo_state/notification_id" "$repo_state/notification_delivered" \
    "$worktree/.sergeant-response" "$worktree/.sergeant-response-id" \
    "$worktree/.sergeant-response-generation" "$worktree/.sergeant-notification"
  printf 'needs_input\n' > "$repo_state/status"
  printf 'needs_input\n' > "$worktree/.sergeant-status"
  PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/newline-$newline_case.log" \
    TD_LOG="$TEST_ROOT/newline-$newline_case-td.log" \
    TD_RESPONSE_FILE="$worktree/.sergeant-response" PANE_ALIVE=1 \
    EXPECTED_WORKER="$repo_state" SERGEANT_FLEET="$fleet" \
    "$ROOT_DIR/bin/sgt-respond" task-1 app < "$expected_response" >/dev/null
  cmp -s "$expected_response" "$repo_state/response"
  cmp -s "$expected_response" "$worktree/.sergeant-response"

  rm -f "$worktree/.sergeant-response"
  printf 'orphaned\n' > "$repo_state/status"
  printf 'orphaned\n' > "$worktree/.sergeant-status"
  PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/replay-$newline_case.log" \
    TD_LOG="$TEST_ROOT/replay-$newline_case-td.log" \
    TD_RESPONSE_FILE="$worktree/.sergeant-response" PANE_ALIVE=1 \
    EXPECTED_WORKER="$repo_state" SERGEANT_FLEET="$fleet" \
    "$ROOT_DIR/bin/sgt-respond" task-1 app < "$expected_response" >/dev/null
  cmp -s "$expected_response" "$repo_state/response"
  cmp -s "$expected_response" "$worktree/.sergeant-response"
done

response_tmp="$TEST_ROOT/response-tmp"
mkdir -p "$response_tmp"
for newline_case in zero one multiple; do
  expected_response="$TEST_ROOT/response-$newline_case"
  tty_input="$TEST_ROOT/tty-input-$newline_case"
  cp "$expected_response" "$tty_input"
  printf '\004\004' >> "$tty_input"
  rm -f "$repo_state/response" "$repo_state/response_id" "$repo_state/response_generation" \
    "$repo_state/notification_id" "$repo_state/notification_delivered" \
    "$worktree/.sergeant-response" "$worktree/.sergeant-response-id" \
    "$worktree/.sergeant-response-generation" "$worktree/.sergeant-notification"
  printf 'needs_input\n' > "$repo_state/status"
  printf 'needs_input\n' > "$worktree/.sergeant-status"
  PATH="$fake_bin:$PATH" TMPDIR="$response_tmp" \
    TMUX_LOG="$TEST_ROOT/tty-$newline_case.log" \
    TD_LOG="$TEST_ROOT/tty-$newline_case-td.log" \
    TD_RESPONSE_FILE="$worktree/.sergeant-response" PANE_ALIVE=1 \
    EXPECTED_WORKER="$repo_state" SERGEANT_FLEET="$fleet" \
    run_in_pty "$ROOT_DIR/bin/sgt-respond" task-1 app \
    < "$tty_input" >/dev/null
  cmp -s "$expected_response" "$repo_state/response"
  cmp -s "$expected_response" "$worktree/.sergeant-response"
  if compgen -G "$response_tmp/sgt-response.*" >/dev/null; then
    printf 'TTY response input temporary file was retained: %s\n' "$newline_case" >&2
    exit 1
  fi
done

empty_response="$TEST_ROOT/empty-response"
printf '\004\004' > "$empty_response"
rm -f "$repo_state/response" "$repo_state/response_id" "$repo_state/response_generation" \
  "$worktree/.sergeant-response" "$worktree/.sergeant-response-id" \
  "$worktree/.sergeant-response-generation"
set +e
PATH="$fake_bin:$PATH" TMPDIR="$response_tmp" TMUX_LOG="$TEST_ROOT/tty-empty.log" \
  TD_LOG="$TEST_ROOT/tty-empty-td.log" TD_RESPONSE_FILE="$worktree/.sergeant-response" \
  PANE_ALIVE=1 EXPECTED_WORKER="$repo_state" SERGEANT_FLEET="$fleet" \
  run_in_pty "$ROOT_DIR/bin/sgt-respond" task-1 app \
  < "$empty_response" >/dev/null
tty_empty_status=$?
set -e
[[ "$tty_empty_status" -ne 0 ]]
[[ ! -e "$repo_state/response" && ! -e "$worktree/.sergeant-response" ]]
if compgen -G "$response_tmp/sgt-response.*" >/dev/null; then
  printf 'empty TTY response retained a temporary file\n' >&2
  exit 1
fi

rm -f "$repo_state/response" "$repo_state/response_id" "$repo_state/response_generation" \
  "$repo_state/notification_id" "$repo_state/notification_delivered" \
  "$worktree/.sergeant-response" "$worktree/.sergeant-response-id" \
  "$worktree/.sergeant-response-generation" "$worktree/.sergeant-notification"
printf 'needs_input\n' > "$repo_state/status"
printf 'needs_input\n' > "$worktree/.sergeant-status"

# shellcheck disable=SC2016
# Literal metacharacters verify response data is never evaluated.
response='Use option A; $(touch should-not-exist)'
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/live.log" TD_LOG="$TEST_ROOT/td.log" \
  REQUIRE_LOCK_RELEASE=1 LOCK_HELD_MARKER="$TEST_ROOT/lock-held" \
  TD_RESPONSE_FILE="$worktree/.sergeant-response" PANE_ALIVE=1 EXPECTED_WORKER="$repo_state" SERGEANT_FLEET="$fleet" \
  respond "$response" >/dev/null
[[ "$(cat "$repo_state/response")" == "$response" ]]
[[ "$(cat "$worktree/.sergeant-response")" == "$response" ]]
[[ "$(cat "$repo_state/pane")" == "%42" ]]
[[ "$(cat "$repo_state/notification_delivered")" == "$(cat "$repo_state/notification_id")" ]]
[[ "$(cat "$repo_state/notification_id")" == "$(cat "$repo_state/response_id")" ]]
grep -Fq 'kind=response' "$worktree/.sergeant-notification"
if grep -Fq "$response" "$TEST_ROOT/live.log"; then
  printf 'response body leaked into tmux process arguments\n' >&2
  exit 1
fi
[[ ! -e "$ROOT_DIR/should-not-exist" ]]
grep -Fq 'log td-123' "$TEST_ROOT/td.log"
grep -Fq -- '--decision' "$TEST_ROOT/td.log"
grep -Eq 'response-id=[a-f0-9]{32}' "$TEST_ROOT/td.log"
[[ "$(cat "$repo_state/response_id")" =~ ^[a-f0-9]{32}$ ]]
[[ "$(cat "$worktree/.sergeant-response-id")" == "$(cat "$repo_state/response_id")" ]]
[[ "$(cat "$repo_state/response_generation")" == "1" ]]
[[ "$(cat "$worktree/.sergeant-response-generation")" == "1" ]]
[[ -e "$TEST_ROOT/lock-held" ]]
if grep -Fq 'sha256=' "$TEST_ROOT/td.log"; then
  printf 'response-derived digest leaked into td\n' >&2
  exit 1
fi
if grep -Fq 'Use option A' "$TEST_ROOT/td.log"; then
  printf 'raw response leaked into td\n' >&2
  exit 1
fi
set +e
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/duplicate.log" TD_LOG="$TEST_ROOT/duplicate-td.log" \
TD_RESPONSE_FILE="$worktree/.sergeant-response" PANE_ALIVE=1 EXPECTED_WORKER="$repo_state" SERGEANT_FLEET="$fleet" \
  respond 'Use option B' >/dev/null 2>&1
duplicate_status=$?
set -e
[[ "$duplicate_status" -ne 0 ]]
[[ "$(cat "$repo_state/response")" == "$response" ]]
[[ "$(cat "$worktree/.sergeant-response")" == "$response" ]]
if [[ -e "$TEST_ROOT/duplicate-td.log" ]]; then
  printf 'duplicate response should not log a new td decision\n' >&2
  exit 1
fi

rm -f "$worktree/.sergeant-response" "$repo_state/response"
mkdir "$repo_state/response.lock"
printf '%s\n' "$$" > "$repo_state/response.lock/pid"
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/locked.log" TD_LOG="$TEST_ROOT/locked-td.log" \
TD_RESPONSE_FILE="$worktree/.sergeant-response" PANE_ALIVE=1 EXPECTED_WORKER="$repo_state" SERGEANT_FLEET="$fleet" \
  respond 'serialized response' >/dev/null &
locked_pid=$!
sleep 0.05
[[ ! -e "$worktree/.sergeant-response" && ! -e "$repo_state/response" ]]
rm "$repo_state/response.lock/pid"
rmdir "$repo_state/response.lock"
wait "$locked_pid"
[[ "$(cat "$worktree/.sergeant-response")" == 'serialized response' ]]

rm -f "$worktree/.sergeant-response" "$repo_state/response"
printf 'done\n' > "$worktree/.sergeant-status"
printf 'done\n' > "$repo_state/status"
set +e
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/late.log" TD_LOG="$TEST_ROOT/late-td.log" \
TD_RESPONSE_FILE="$worktree/.sergeant-response" PANE_ALIVE=1 EXPECTED_WORKER="$repo_state" SERGEANT_FLEET="$fleet" \
  respond 'late response' >/dev/null 2>&1
late_status=$?
set -e
[[ "$late_status" -ne 0 ]]
[[ ! -e "$worktree/.sergeant-response" && ! -e "$repo_state/response" ]]

printf 'in_progress\n' > "$worktree/.sergeant-status"
printf 'in_progress\n' > "$repo_state/status"
set +e
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/active.log" TD_LOG="$TEST_ROOT/active-td.log" \
TD_RESPONSE_FILE="$worktree/.sergeant-response" PANE_ALIVE=1 EXPECTED_WORKER="$repo_state" SERGEANT_FLEET="$fleet" \
  respond 'active response' >/dev/null 2>&1
active_status=$?
set -e
[[ "$active_status" -ne 0 ]]
[[ ! -e "$worktree/.sergeant-response" && ! -e "$repo_state/response" ]]

printf 'needs_input\n' > "$worktree/.sergeant-status"
printf 'needs_input\n' > "$repo_state/status"

rm -f "$worktree/.sergeant-response"
set +e
live_mismatch_output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/live-mismatch.log" \
  TD_LOG="$TEST_ROOT/live-mismatch-td.log" TD_RESPONSE_FILE="$worktree/.sergeant-response" \
  PANE_ALIVE=1 PANE_IDENTITY="0|%42|4242|123456|different-live-worker" \
  EXPECTED_WORKER="$repo_state" SERGEANT_FLEET="$fleet" \
  respond 'refuse live identity mismatch' 2>&1)"
live_mismatch_status=$?
set -e
[[ "$live_mismatch_status" -ne 0 ]]
[[ "$live_mismatch_output" == *'live but its identity does not match'* ]]
if grep -Fq 'new-window' "$TEST_ROOT/live-mismatch.log" 2>/dev/null; then
  printf 'live identity mismatch launched a replacement pane\n' >&2
  exit 1
fi
rm -f "$worktree/.sergeant-response" "$worktree/.sergeant-response-generation" \
  "$worktree/.sergeant-response-id" "$repo_state/response" \
  "$repo_state/response_generation" "$repo_state/response_id"
printf 'stale recycle receipt\n' > "$repo_state/worker_recycled"

PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/dead.log" TD_LOG="$TEST_ROOT/td.log" \
TD_RESPONSE_FILE="$worktree/.sergeant-response" PANE_ALIVE=1 \
  PANE_IDENTITY="1|%42|4242|123456|bash sgt-interactive-worker:$repo_state" \
  EXPECTED_WORKER="$repo_state" SERGEANT_FLEET="$fleet" \
  respond 'resume dead worker' >/dev/null
[[ "$(cat "$repo_state/pane")" == "%99" ]]
grep -Fq 'new-window -P -F #{pane_id} -t sgt: -n task/app' "$TEST_ROOT/dead.log"
grep -Fq "$ROOT_DIR/bin/sgt-interactive-worker" "$TEST_ROOT/dead.log"
[[ "$(cat "$repo_state/notification_delivered")" == "$(cat "$repo_state/notification_id")" ]]
[[ "$(cat "$repo_state/notification_id")" != "$(cat "$repo_state/response_id")" ]]
[[ "$(cat "$repo_state/notification_delivered_pane_identity")" == 0\|%99\|9999\|654321\|* ]]
[[ ! -e "$repo_state/worker_recycled" ]]

relaunch_response_id="$(cat "$repo_state/response_id")"
stale_notification_id="$(cat "$repo_state/notification_id")"
stale_nonce="$(cat "$repo_state/notification_target")"
printf 'orphaned\n' > "$repo_state/status"
printf 'orphaned\n' > "$worktree/.sergeant-status"
printf '%s\n' "$stale_nonce" \
  > "$repo_state/notifications/$stale_notification_id/action_lease"
rm -f "$worktree/.sergeant-response"
set +e
lease_output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/lease-block.log" \
  TD_LOG="$TEST_ROOT/lease-block-td.log" TD_RESPONSE_FILE="$worktree/.sergeant-response" \
  PANE_ALIVE=0 EXPECTED_WORKER="$repo_state" SERGEANT_FLEET="$fleet" \
  respond 'resume dead worker' 2>&1)"
lease_status=$?
set -e
[[ "$lease_status" -ne 0 && "$lease_output" == *'action lease belongs to the prior supervisor'* ]]
[[ "$(cat "$repo_state/notification_id")" == "$stale_notification_id" ]]
printf '%s\n' "$stale_notification_id|$stale_nonce" \
  > "$repo_state/notifications/$stale_notification_id/targets/$stale_nonce/completed"
printf '%s\n' "$stale_notification_id" > "$repo_state/notification_delivered"
printf '0|%%99|9999|654321|stale-pane\n' > "$repo_state/notification_delivered_pane_identity"
printf '%s|%s\n' "$stale_notification_id" \
  "$(cat "$repo_state/notifications/$stale_notification_id/targets/$stale_nonce/pane_identity")" \
  > "$worktree/.sergeant-notification-ack"
rm -f "$worktree/.sergeant-response"
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/crash-relaunch.log" \
  TD_LOG="$TEST_ROOT/crash-relaunch-td.log" TD_RESPONSE_FILE="$worktree/.sergeant-response" \
  PANE_ALIVE=1 NEW_PANE=%100 REQUIRE_FRESH_ACK=1 REQUIRE_TARGET=1 STALE_SUPERVISOR_ACK=1 \
  REQUIRE_REVOKED_BEFORE_NOTIFICATION=1 \
  DELIVER_COUNT_FILE="$TEST_ROOT/crash-relaunch-delivery-count" DELIVER_AFTER=3 \
  PANE_IDENTITY="1|%99|9999|654321|dead-pane" EXPECTED_WORKER="$repo_state" \
  SERGEANT_FLEET="$fleet" respond 'resume dead worker' >/dev/null
[[ "$(cat "$repo_state/response_id")" == "$relaunch_response_id" ]]
[[ "$(cat "$repo_state/notification_id")" != "$stale_notification_id" ]]
[[ "$(cat "$repo_state/pane")" == %100 ]]
[[ "$(cat "$repo_state/notification_delivered")" == "$(cat "$repo_state/notification_id")" ]]
[[ "$(cat "$repo_state/notification_delivered_pane_identity")" == 0\|%100\|9999\|654321\|* ]]
new_notif_id="$(cat "$repo_state/notification_id")"
new_nonce="$(cat "$repo_state/notification_target")"
[[ "$(cat "$repo_state/notifications/$new_notif_id/targets/$new_nonce/pane_identity")" == 0\|%100\|9999\|654321\|* ]]
[[ "$(cat "$TEST_ROOT/crash-relaunch-delivery-count")" -ge 3 ]]
[[ ! -e "$TEST_ROOT/crash-relaunch-td.log" ]]
[[ "$(cat "$worktree/.sergeant-response")" == 'resume dead worker' ]]
grep -Fq '%99' \
  "$repo_state/notifications/$stale_notification_id/superseded_target_pane_identity"

printf 'needs_input\n' > "$repo_state/status"
printf 'needs_input\n' > "$worktree/.sergeant-status"
rm -f "$worktree/.sergeant-response" "$repo_state/response" \
  "$repo_state/response_id" "$repo_state/response_generation"
replacement_nonce="dddddddddddddddddddddddddddddddd"
target_race_hook="printf '%s\\n' '$replacement_nonce' > \"\$repo_dir/notification_target\""
set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/relaunch-target-race.log" \
  TD_LOG="$TEST_ROOT/relaunch-target-race-td.log" TD_RESPONSE_FILE="$worktree/.sergeant-response" \
  PANE_ALIVE=1 PANE_IDENTITY="1|%42|4242|123456|dead-pane" NEW_PANE=%101 \
  SGT_TEST_HOOKS=1 _SGT_POST_MV_HOOK="$target_race_hook" \
  EXPECTED_WORKER="$repo_state" SERGEANT_FLEET="$fleet" \
  respond 'relaunch target race' 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 ]]
[[ "$output" == *'notification target race detected during relaunch'* ]]
[[ "$(cat "$repo_state/status")" == 'orphaned' ]]
[[ "$(cat "$worktree/.sergeant-status")" == 'orphaned' ]]
grep -Fq 'notification target race detected during relaunch' "$repo_state/diagnostic"
grep -Fq 'kill-pane -t %101' "$TEST_ROOT/relaunch-target-race.log"
[[ "$(cat "$repo_state/pane")" == '%100' ]]
[[ "$(cat "$repo_state/pane_identity")" == 0\|%100\|9999\|654321\|* ]]
[[ "$(cat "$repo_state/notification_target")" == "$replacement_nonce" ]]
[[ ! -e "$repo_state/notification_target_pane_identity" ]]
race_notification_id="$(cat "$repo_state/notification_id")"
race_target_count="$(find "$repo_state/notifications/$race_notification_id/targets" -mindepth 1 \
  -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
[[ "$race_target_count" == "0" ]]
[[ "$(cat "$worktree/.sergeant-response")" == 'relaunch target race' ]]
[[ ! -d "$repo_state/response.lock" ]]

rm "$worktree/.sergeant-response" "$repo_state/response"
cat > "$fake_bin/td" <<'EOF'
#!/usr/bin/env bash
exit 19
EOF
chmod +x "$fake_bin/td"
set +e
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/td-failure-tmux.log" PANE_ALIVE=1 \
SERGEANT_FLEET="$fleet" respond 'must not publish' >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]]
[[ ! -e "$worktree/.sergeant-response" && ! -e "$repo_state/response" ]]
if compgen -G "$worktree/.sergeant-response.tmp.*" >/dev/null; then
  printf 'atomic response temporary file was retained\n' >&2
  exit 1
fi
cat > "$fake_bin/td" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TD_LOG"
EOF
chmod +x "$fake_bin/td"

printf 'needs_input\n' > "$repo_state/status"
printf 'needs_input\n' > "$worktree/.sergeant-status"
rm -f "$worktree/.sergeant-response" "$repo_state/response"
set +e
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/relaunch-fail.log" TD_LOG="$TEST_ROOT/relaunch-fail-td.log" PANE_ALIVE=0 FAIL_WINDOW=1 \
SERGEANT_FLEET="$fleet" respond 'relaunch fails' >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]]
[[ "$(cat "$worktree/.sergeant-status")" == 'orphaned' ]]
grep -Fq 'tmux failed to relaunch worker supervisor' "$repo_state/diagnostic"

cat > "$fake_bin/td" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TD_LOG"
EOF
chmod +x "$fake_bin/td"
printf 'needs_input\n' > "$repo_state/status"
printf 'needs_input\n' > "$worktree/.sergeant-status"
rm -f "$worktree/.sergeant-response" "$repo_state/response" "$repo_state/response_id"
set +e
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/empty-pane.log" TD_LOG="$TEST_ROOT/empty-pane-td.log" \
PANE_ALIVE=0 EMPTY_WINDOW=1 SERGEANT_FLEET="$fleet" \
  respond 'empty pane' >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]]
[[ "$(cat "$worktree/.sergeant-status")" == 'orphaned' ]]
grep -Fq 'tmux returned no pane for relaunched worker supervisor' "$repo_state/diagnostic"
grep -Fq 'handoff td-123' "$TEST_ROOT/empty-pane-td.log"

printf 'orphaned\n' > "$repo_state/status"
printf 'orphaned\n' > "$worktree/.sergeant-status"
rm -f "$worktree/.sergeant-gate-generation" "$worktree/.sergeant-response" \
  "$worktree/.sergeant-response-generation" "$repo_state/response" \
  "$repo_state/response_generation" "$repo_state/response_id"
set +e
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/orphan-no-gate.log" \
  TD_LOG="$TEST_ROOT/orphan-no-gate-td.log" PANE_ALIVE=0 FAIL_WINDOW=1 \
  SERGEANT_FLEET="$fleet" respond 'recover orphan without gate' >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]]
[[ "$(cat "$worktree/.sergeant-gate-generation")" == '1' ]]
[[ "$(cat "$repo_state/response_generation")" == '1' ]]

original_worktree="$worktree"
for invalid_path in '' "$TEST_ROOT/missing-worktree"; do
  printf '%s\n' "$invalid_path" > "$repo_state/worktree"
  rm -f "$original_worktree/.sergeant-gate-generation"
  set +e
  PATH="$fake_bin:$PATH" REAL_MV="$real_mv" TMUX_LOG="$TEST_ROOT/invalid-worktree.log" \
    TD_LOG="$TEST_ROOT/invalid-worktree-td.log" PANE_ALIVE=0 SERGEANT_FLEET="$fleet" \
    respond 'must reject invalid worktree' >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 && ! -e "$original_worktree/.sergeant-gate-generation" ]]
done
ln -s "$original_worktree" "$TEST_ROOT/stale-worktree-link"
printf '%s\n' "$TEST_ROOT/stale-worktree-link" > "$repo_state/worktree"
rm -f "$original_worktree/.sergeant-gate-generation"
set +e
PATH="$fake_bin:$PATH" REAL_MV="$real_mv" TMUX_LOG="$TEST_ROOT/stale-worktree.log" \
  TD_LOG="$TEST_ROOT/stale-worktree-td.log" PANE_ALIVE=0 SERGEANT_FLEET="$fleet" \
  respond 'must reject stale worktree ownership' >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 && ! -e "$original_worktree/.sergeant-gate-generation" ]]
printf '%s\n' "$original_worktree" > "$repo_state/worktree"
printf '1\n' > "$original_worktree/.sergeant-gate-generation"

printf 'needs_input\n' > "$repo_state/status"
printf 'needs_input\n' > "$worktree/.sergeant-status"
rm -f "$worktree/.sergeant-response" "$worktree/.sergeant-response-generation" \
  "$repo_state/response" "$repo_state/response_generation" "$repo_state/response_id"
printf '\nSilent drift.\n' >> "$worktree/.sergeant-intent.md"
set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/intent-drift.log" TD_LOG="$TEST_ROOT/intent-drift-td.log" \
  PANE_ALIVE=0 SERGEANT_FLEET="$fleet" \
  respond 'must not resume drifted intent' 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *'canonical intent revision mismatch'* ]] || {
  printf 'recovery did not reject silent intent drift: %s\n' "$output" >&2
  exit 1
}
[[ ! -e "$worktree/.sergeant-response" && ! -e "$repo_state/response" ]] || {
  printf 'recovery published a response after intent drift\n' >&2
  exit 1
}

printf 'orphaned\n' > "$repo_state/status"
printf 'orphaned\n' > "$worktree/.sergeant-status"
cp "$fleet/task-1/.sergeant-intent.md" "$worktree/.sergeant-intent.md"
rm -f "$worktree/.sergeant-gate-generation" "$worktree/.git"
git -C "$worktree" init -q
set +e
PATH="$fake_bin:$PATH" REAL_MV="$real_mv" TMUX_LOG="$TEST_ROOT/replaced-worktree.log" \
  TD_LOG="$TEST_ROOT/replaced-worktree-td.log" PANE_ALIVE=0 SERGEANT_FLEET="$fleet" \
  respond 'must reject replaced checkout' >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 && ! -e "$worktree/.sergeant-gate-generation" ]]

printf 'sgt-respond resumes workers: ok\n'
