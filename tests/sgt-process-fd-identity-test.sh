#!/usr/bin/env bash
# Regression test: _sgt_fd_identity's non-Linux fallback stat-ed the *path*
# /dev/fd/$fd rather than the fd itself. On macOS, /dev/fd is backed by the
# synthetic fdesc filesystem, which preserves the real file's inode but
# reports its own, different device number -- so every comparison against an
# identity recorded from the real path failed unconditionally on macOS,
# regardless of whether the fd genuinely pointed at the expected file. This
# is the sole caller's (_sgt_validate_inherited_worker_marker,
# bin/_sgt-lib.sh:1392) exact failure mode: every dispatched interactive
# worker on macOS was rejected as "worker process marker conflicts with
# durable launch ownership" immediately after launch.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# shellcheck source=../bin/_sgt-process.sh
source "$ROOT_DIR/bin/_sgt-process.sh"

testfile="$TEST_ROOT/marker"
printf 'fixture\n' > "$testfile"
expected="$(stat -f '%d:%i' "$testfile" 2>/dev/null || stat -Lc '%d:%i' "$testfile")"

exec 198< "$testfile"
got="$(_sgt_fd_identity 198)"
exec 198<&-

[[ "$got" == "$expected" ]] || {
  printf 'FAIL: _sgt_fd_identity reported %s for an fd genuinely open on a file whose real identity is %s\n' \
    "$got" "$expected" >&2
  exit 1
}

printf '_sgt_fd_identity reports the real file identity for a genuinely owned fd: ok\n'

# A closed fd must fail closed, not report a stale or fabricated identity.
exec 199< "$testfile"
exec 199<&-
set +e
closed_result="$(_sgt_fd_identity 199 2>/dev/null)"
closed_status=$?
set -e
[[ "$closed_status" -ne 0 && -z "$closed_result" ]] || {
  printf 'FAIL: _sgt_fd_identity should fail closed for a closed fd, got status=%s result=%s\n' \
    "$closed_status" "$closed_result" >&2
  exit 1
}

printf '_sgt_fd_identity fails closed for a closed fd: ok\n'
