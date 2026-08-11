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

# A live PID with a different process-birth identity is stale, not a live owner.
lockdir5="$TEST_ROOT/state-5"
mkdir -p "$lockdir5"
printf 'pid=%s\nstart=proc:0\nnonce=11111111111111111111111111111111\n' "$$" \
  > "$lockdir5/response.lock"
SGT_RESPONSE_LOCK_TIMEOUT=1 _sgt_response_lock_acquire "$lockdir5"
grep -Fxq "start=$(_sgt_process_start_token "$$")" "$lockdir5/response.lock" || {
  printf 'FAIL case5: reused PID claim was not replaced with exact birth identity\n' >&2
  exit 1
}
_sgt_response_lock_release

# Waiting for a genuinely live owner is bounded.
lockdir6="$TEST_ROOT/state-6"
mkdir -p "$lockdir6"
_sgt_response_lock_record_for_pid "$$" > "$lockdir6/response.lock"
if SGT_RESPONSE_LOCK_TIMEOUT=1 SGT_RESPONSE_LOCK_INTERVAL=0.01 \
    _sgt_response_lock_acquire "$lockdir6" 2> "$TEST_ROOT/case6.err"; then
  printf 'FAIL case6: live competing owner was reclaimed\n' >&2
  exit 1
fi
grep -Fq 'Timed out waiting for response lock' "$TEST_ROOT/case6.err"

# New-format records are an exact schema. Extra fields or renamed keys are
# ambiguous and must be rejected without reclaiming a possibly live owner.
for malformed in extra wrong_key; do
  lockdir7="$TEST_ROOT/state-7-$malformed"
  mkdir -p "$lockdir7"
  valid_record="$(_sgt_response_lock_record_for_pid "$$")"
  case "$malformed" in
    extra) printf '%s\nextra=value\n' "$valid_record" > "$lockdir7/response.lock" ;;
    wrong_key) printf '%s\n' "$valid_record" | sed 's/^nonce=/claim=/' > "$lockdir7/response.lock" ;;
  esac
  before_record="$(cat "$lockdir7/response.lock")"
  if SGT_RESPONSE_LOCK_TIMEOUT=1 _sgt_response_lock_acquire "$lockdir7" 2>/dev/null; then
    printf 'FAIL case7: malformed lock %s was accepted\n' "$malformed" >&2
    exit 1
  fi
  [[ "$(cat "$lockdir7/response.lock")" == "$before_record" ]] || {
    printf 'FAIL case7: malformed lock %s was reclaimed\n' "$malformed" >&2
    exit 1
  }
done

printf 'sgt-response-lock-release: ok\n'
