#!/usr/bin/env bash
# Regression: _sgt_response_lock_release must preserve _SGT_RESPONSE_LOCK_DIR and
# return a non-zero exit code when rm fails, so that callers can retry the release
# rather than continuing with a live-PID leftover lock.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'chmod -R u+rwx "$TEST_ROOT" 2>/dev/null || true; rm -rf "$TEST_ROOT"' EXIT

# shellcheck source=bin/_sgt-response-lock.sh
source "$ROOT_DIR/bin/_sgt-response-lock.sh"

# ── Case 1: failed rm preserves _SGT_RESPONSE_LOCK_DIR ────────────────────────
# Make the parent directory non-writable so rm -f fails with EACCES.

lockdir1="$TEST_ROOT/state-1"
mkdir -p "$lockdir1"
lockfile1="$lockdir1/response.lock"
printf '%s\n' "$$" > "$lockfile1"
_SGT_RESPONSE_LOCK_DIR="$lockfile1"

chmod 555 "$lockdir1"
set +e
_sgt_response_lock_release
release_status1=$?
set -e
chmod 755 "$lockdir1"

[[ "$release_status1" -ne 0 ]] || {
  printf 'FAIL case1: release returned 0 when rm should have failed\n' >&2
  exit 1
}
[[ -n "${_SGT_RESPONSE_LOCK_DIR:-}" ]] || {
  printf 'FAIL case1: _SGT_RESPONSE_LOCK_DIR was cleared after a failed rm\n' >&2
  exit 1
}
[[ -f "$lockfile1" ]] || {
  printf 'FAIL case1: lock file was removed despite rm failure\n' >&2
  exit 1
}

# ── Case 2: retry succeeds after permissions restored ─────────────────────────
# _SGT_RESPONSE_LOCK_DIR must be cleared and the file removed on success.

_sgt_response_lock_release
[[ -z "${_SGT_RESPONSE_LOCK_DIR:-}" ]] || {
  printf 'FAIL case2: _SGT_RESPONSE_LOCK_DIR not cleared after successful retry\n' >&2
  exit 1
}
[[ ! -f "$lockfile1" ]] || {
  printf 'FAIL case2: lock file still present after successful release\n' >&2
  exit 1
}

# ── Case 3: release is a no-op when no lock is held ───────────────────────────
_SGT_RESPONSE_LOCK_DIR=""
_sgt_response_lock_release
[[ -z "${_SGT_RESPONSE_LOCK_DIR:-}" ]] || {
  printf 'FAIL case3: _SGT_RESPONSE_LOCK_DIR set after no-op release\n' >&2
  exit 1
}

# ── Case 4: release skips if owner PID does not match ─────────────────────────
# If another PID wrote the lock, we must not remove it.
lockdir4="$TEST_ROOT/state-4"
mkdir -p "$lockdir4"
lockfile4="$lockdir4/response.lock"
printf '%s\n' "0"  > "$lockfile4"   # PID 0 — never our $$
_SGT_RESPONSE_LOCK_DIR="$lockfile4"
_sgt_response_lock_release
[[ -f "$lockfile4" ]] || {
  printf 'FAIL case4: release removed a lock owned by another PID\n' >&2
  exit 1
}
[[ -z "${_SGT_RESPONSE_LOCK_DIR:-}" ]] || {
  printf 'FAIL case4: _SGT_RESPONSE_LOCK_DIR not cleared after non-owner skip\n' >&2
  exit 1
}

printf 'sgt-response-lock-release: ok\n'
