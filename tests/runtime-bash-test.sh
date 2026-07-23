#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

minimum_bash="${SGT_MINIMUM_BASH:-/bin/bash}"
# shellcheck disable=SC2016
version="$($minimum_bash -c 'printf "%s.%s\n" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"')"
if [[ "$version" != "3.2" ]]; then
  printf 'runtime Bash regression requires Bash 3.2, found %s at %s\n' "$version" "$minimum_bash" >&2
  exit 1
fi

set +e
# shellcheck disable=SC2016
unsupported_output="$($minimum_bash -c \
  'source "$1/bin/_sgt-bash-version.sh"; _sgt_require_bash_version 3 1' _ "$ROOT_DIR" 2>&1)"
unsupported_status=$?
set -e
if [[ "$unsupported_status" -eq 0 ]]; then
  printf 'Bash 3.1 was incorrectly accepted\n' >&2
  exit 1
fi
if [[ "$unsupported_output" != *'requires Bash 3.2 or newer; found 3.1'* ]] ||
   [[ "$unsupported_output" != *'ensure it appears first on PATH'* ]]; then
  printf 'unsupported Bash error was not actionable:\n%s\n' "$unsupported_output" >&2
  exit 1
fi

fleet="$TEST_ROOT/fleet"
repo_state="$fleet/task-1/app"
worktree="$TEST_ROOT/worktree"
mkdir -p "$repo_state" "$worktree"
printf '%s\n' "$worktree" > "$repo_state/worktree"
printf 'needs_input\n' > "$repo_state/status"
printf 'needs_input\n' > "$worktree/.sergeant-status"

SERGEANT_FLEET="$fleet" "$minimum_bash" "$ROOT_DIR/bin/sgt-respond" task-1 app 'Bash 3.2 response' >/dev/null
[[ "$(cat "$repo_state/response")" == 'Bash 3.2 response' ]]
[[ "$(cat "$worktree/.sergeant-response")" == 'Bash 3.2 response' ]]
[[ ! -e "$repo_state/response.lock" && ! -L "$repo_state/response.lock" ]]

failed_repo_state="$fleet/task-1/failed"
failed_worktree="$TEST_ROOT/failed-worktree"
mkdir -p "$failed_repo_state" "$failed_worktree"
printf '%s\n' "$failed_worktree" > "$failed_repo_state/worktree"
printf 'needs_input\n' > "$failed_repo_state/status"
printf 'needs_input\n' > "$failed_worktree/.sergeant-status"

set +e
# shellcheck disable=SC2016
SERGEANT_FLEET="$fleet" "$minimum_bash" -c '
  mktemp() { return 1; }
  script="$1"
  shift
  source "$script"
' _ "$ROOT_DIR/bin/sgt-respond" task-1 failed 'failed response' >/dev/null 2>&1
failed_status=$?
set -e
if [[ "$failed_status" -eq 0 ]]; then
  printf 'response publication unexpectedly succeeded\n' >&2
  exit 1
fi
[[ ! -e "$failed_repo_state/response" && ! -e "$failed_worktree/.sergeant-response" ]]
[[ ! -e "$failed_repo_state/response.lock" && ! -L "$failed_repo_state/response.lock" ]]

empty_repo_state="$fleet/task-1/empty-lock"
empty_worktree="$TEST_ROOT/empty-lock-worktree"
mkdir -p "$empty_repo_state/response.lock" "$empty_worktree"
touch -t 200001010000 "$empty_repo_state/response.lock"
printf '%s\n' "$empty_worktree" > "$empty_repo_state/worktree"
printf 'needs_input\n' > "$empty_repo_state/status"
printf 'needs_input\n' > "$empty_worktree/.sergeant-status"
SERGEANT_FLEET="$fleet" "$minimum_bash" "$ROOT_DIR/bin/sgt-respond" \
  task-1 empty-lock 'recover empty lock' >/dev/null
[[ "$(cat "$empty_repo_state/response")" == 'recover empty lock' ]]
[[ ! -e "$empty_repo_state/response.lock" && ! -L "$empty_repo_state/response.lock" ]]

dead_repo_state="$fleet/task-1/dead-lock"
dead_worktree="$TEST_ROOT/dead-lock-worktree"
mkdir -p "$dead_repo_state/response.lock" "$dead_worktree"
printf '99999999\n' > "$dead_repo_state/response.lock/pid"
printf '%s\n' "$dead_worktree" > "$dead_repo_state/worktree"
printf 'needs_input\n' > "$dead_repo_state/status"
printf 'needs_input\n' > "$dead_worktree/.sergeant-status"
SERGEANT_FLEET="$fleet" "$minimum_bash" "$ROOT_DIR/bin/sgt-respond" \
  task-1 dead-lock 'recover dead lock' >/dev/null
[[ "$(cat "$dead_repo_state/response")" == 'recover dead lock' ]]
[[ ! -e "$dead_repo_state/response.lock" && ! -L "$dead_repo_state/response.lock" ]]

stale_repo_state="$fleet/task-1/stale-lock"
stale_worktree="$TEST_ROOT/stale-lock-worktree"
mkdir -p "$stale_repo_state" "$stale_worktree"
ln -s 99999999 "$stale_repo_state/response.lock"
printf '%s\n' "$stale_worktree" > "$stale_repo_state/worktree"
printf 'needs_input\n' > "$stale_repo_state/status"
printf 'needs_input\n' > "$stale_worktree/.sergeant-status"
SERGEANT_FLEET="$fleet" "$minimum_bash" "$ROOT_DIR/bin/sgt-respond" \
  task-1 stale-lock 'recover stale lock' >/dev/null
[[ "$(cat "$stale_repo_state/response")" == 'recover stale lock' ]]
[[ ! -e "$stale_repo_state/response.lock" && ! -L "$stale_repo_state/response.lock" ]]

invalid_repo_state="$fleet/task-1/invalid-lock"
invalid_worktree="$TEST_ROOT/invalid-lock-worktree"
mkdir -p "$invalid_repo_state" "$invalid_worktree"
printf 'not a lock\n' > "$invalid_repo_state/response.lock"
printf '%s\n' "$invalid_worktree" > "$invalid_repo_state/worktree"
printf 'needs_input\n' > "$invalid_repo_state/status"
printf 'needs_input\n' > "$invalid_worktree/.sergeant-status"
set +e
invalid_output="$(SERGEANT_FLEET="$fleet" "$minimum_bash" "$ROOT_DIR/bin/sgt-respond" \
  task-1 invalid-lock 'invalid lock' 2>&1)"
invalid_status=$?
set -e
if [[ "$invalid_status" -eq 0 ]] || [[ "$invalid_output" != *'Response lock has an invalid owner'* ]]; then
  printf 'invalid lock path did not fail immediately and actionably\n' >&2
  exit 1
fi
[[ "$(cat "$invalid_repo_state/response.lock")" == 'not a lock' ]]
[[ ! -e "$invalid_repo_state/response" && ! -e "$invalid_worktree/.sergeant-response" ]]

watch_task="$fleet/task-2"
watch_worktree="$TEST_ROOT/watch-worktree"
mkdir -p "$watch_task/app" "$watch_worktree"
printf 'Brief: Bash 3.2 watch\n' > "$watch_task/brief.md"
printf '%s\n' "$watch_worktree" > "$watch_task/app/worktree"
printf 'done\n' > "$watch_worktree/.sergeant-status"
printf 'https://example.test/pr/1\n' > "$watch_worktree/.sergeant-result"

watch_output="$(SERGEANT_FLEET="$fleet" SERGEANT_WATCH_INTERVAL=0.01 \
  "$minimum_bash" "$ROOT_DIR/bin/sgt-watch" task-2)"
[[ "$watch_output" == *'All repos done.'* ]]

printf 'runtime paths support Bash 3.2: ok\n'
