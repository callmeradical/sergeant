#!/usr/bin/env bash
# Regression test for Deloitte support #38: _sgt_response_lock_acquire wrote
# its candidate ownership file directly into the caller-supplied directory
# with no guarantee that directory existed, so a caller passing a directory
# that does not yet exist (or no longer exists) failed with an opaque
# "No such file or directory" -- and since nothing about retrying creates
# the directory either, every retry reproduced the identical failure.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# shellcheck source=../bin/_sgt-response-lock.sh
source "$ROOT/bin/_sgt-response-lock.sh"

missing="$TEST_ROOT/does-not-exist-yet"
[[ ! -e "$missing" ]]

_sgt_response_lock_acquire "$missing" || {
  printf 'FAIL: acquiring a response lock in a not-yet-existing directory failed\n' >&2
  exit 1
}
[[ -d "$missing" ]] || {
  printf 'FAIL: the target directory was not created\n' >&2
  exit 1
}
[[ -e "$missing/response.lock" ]] || {
  printf 'FAIL: the lock itself was not created inside it\n' >&2
  exit 1
}
_sgt_response_lock_release

printf '_sgt_response_lock_acquire creates a missing target directory: ok\n'

# A directory that already exists is completely unaffected (mkdir -p is a
# no-op) -- confirms this is additive, not a behavior change for the common
# case every existing caller already relies on.
present="$TEST_ROOT/already-present"
mkdir -p "$present"
printf 'sentinel\n' > "$present/unrelated-file"
_sgt_response_lock_acquire "$present" || {
  printf 'FAIL: acquiring a response lock in an already-existing directory failed\n' >&2
  exit 1
}
[[ -f "$present/unrelated-file" ]] || {
  printf 'FAIL: an unrelated existing file in the target directory was disturbed\n' >&2
  exit 1
}
_sgt_response_lock_release

printf '_sgt_response_lock_acquire leaves an already-existing directory untouched: ok\n'
