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
owner_record="$(_sgt_response_lock_record_for_pid "$$")"
printf '%s\n' "$owner_record" > "$lockfile1"
_SGT_RESPONSE_LOCK_DIR="$lockfile1"
_SGT_RESPONSE_LOCK_OWNER_RECORD="$owner_record"

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

# Bare scalar PID records are legacy/ambiguous for every public helper.  Even
# when the scalar names this process, it proves neither birth identity nor this
# acquisition and must never be reported live, reclaimed, or released.
lockdir8="$TEST_ROOT/state-8"
mkdir -p "$lockdir8"
printf '%s\n' "$$" > "$lockdir8/response.lock"
scalar_record="$(cat "$lockdir8/response.lock")"
if _sgt_response_lock_record_live "$scalar_record"; then
  printf 'FAIL case8: scalar PID was accepted as a live owner\n' >&2
  exit 1
fi
_sgt_response_lock_reclaim "$lockdir8"
[[ "$(cat "$lockdir8/response.lock")" == "$$" ]] || {
  printf 'FAIL case8: scalar PID was reclaimed by this process\n' >&2
  exit 1
}
_SGT_RESPONSE_LOCK_DIR="$lockdir8/response.lock"
_SGT_RESPONSE_LOCK_OWNER_RECORD=""
_sgt_response_lock_release
[[ "$(cat "$lockdir8/response.lock")" == "$$" ]] || {
  printf 'FAIL case8: scalar PID was released without an exact owner record\n' >&2
  exit 1
}

# Same PID and process birth are insufficient without the exact acquisition
# nonce. Exercise both supported lock layouts through held/reclaim, then prove
# the immutable current acquisition is still reclaimable.
for layout in file directory; do
  lockdir9="$TEST_ROOT/state-9-$layout"
  mkdir -p "$lockdir9"
  exact_record="$(_sgt_response_lock_record_for_pid "$$")"
  if [[ "$layout" == file ]]; then
    record_path="$lockdir9/response.lock"
  else
    mkdir "$lockdir9/response.lock"
    record_path="$lockdir9/response.lock/pid"
  fi
  for variant in different missing; do
    case "$variant" in
      different)
        forged_nonce=ffffffffffffffffffffffffffffffff
        [[ "$exact_record" != *"nonce=$forged_nonce"* ]] || forged_nonce=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
        forged_record="$(printf '%s\n' "$exact_record" | sed "s/^nonce=.*/nonce=$forged_nonce/")"
        ;;
      missing) forged_record="$(printf '%s\n' "$exact_record" | sed '/^nonce=/d')" ;;
    esac
    [[ "$forged_record" != "$exact_record" ]]
    printf '%s\n' "$forged_record" > "$record_path"
    _SGT_RESPONSE_LOCK_DIR=""
    _SGT_RESPONSE_LOCK_OWNER_RECORD="$exact_record"
    if _sgt_response_lock_held_by_this_process "$lockdir9"; then
      printf 'FAIL case9: %s %s nonce was reported as this acquisition\n' "$variant" "$layout" >&2
      exit 1
    fi
    _sgt_response_lock_reclaim "$lockdir9"
    [[ "$(cat "$record_path")" == "$forged_record" ]] || {
      printf 'FAIL case9: %s %s nonce was reclaimed\n' "$variant" "$layout" >&2
      exit 1
    }
  done

  printf '%s\n' "$exact_record" > "$record_path"
  _SGT_RESPONSE_LOCK_DIR=""
  _SGT_RESPONSE_LOCK_OWNER_RECORD="$exact_record"
  _sgt_response_lock_held_by_this_process "$lockdir9" || {
    printf 'FAIL case9: exact %s acquisition was not recognized\n' "$layout" >&2
    exit 1
  }
  _sgt_response_lock_reclaim "$lockdir9"
  [[ ! -e "$lockdir9/response.lock" ]] || {
    printf 'FAIL case9: exact %s acquisition was not reclaimed\n' "$layout" >&2
    exit 1
  }
done

# A live owner whose birth token cannot be read is unverifiable, not stale.  A
# contender must fail closed without replacing its exact acquisition record.
sleep 30 & live_owner=$!
live_owner_start="$(_sgt_process_start_token "$live_owner")"
lockdir10="$TEST_ROOT/state-10"
mkdir -p "$lockdir10"
printf 'pid=%s\nstart=%s\nnonce=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' \
  "$live_owner" "$live_owner_start" > "$lockdir10/response.lock"
birth_probe_record="$(cat "$lockdir10/response.lock")"
_sgt_process_start_token() {
  local pid="$1" token
  [[ "$pid" != "$live_owner" ]] || return 1
  token="$(awk '{ print $22 }' "/proc/$pid/stat" 2>/dev/null)" || return 1
  [[ "$token" =~ ^[0-9]+$ ]] || return 1
  printf 'proc:%s\n' "$token"
}
if SGT_RESPONSE_LOCK_TIMEOUT=1 _sgt_response_lock_acquire "$lockdir10" \
    2> "$TEST_ROOT/case10.err"; then
  printf 'RECLAIMED_LIVE_OWNER_WHEN_BIRTH_PROBE_FAILED\n' >&2
  exit 1
fi
[[ "$(cat "$lockdir10/response.lock")" == "$birth_probe_record" ]] || {
  printf 'RECLAIMED_LIVE_OWNER_WHEN_BIRTH_PROBE_FAILED\n' >&2
  exit 1
}
kill "$live_owner" 2>/dev/null || true
wait "$live_owner" 2>/dev/null || true

# Second-resolution `ps lstart` text is not an exact process-birth identity.
# The Darwin/BSD path must leave exact ownership unverifiable and let the
# portable marker/pane protocol decide liveness instead.
mkdir -p "$TEST_ROOT/darwin-ps-bin"
cat > "$TEST_ROOT/darwin-ps-bin/ps" <<'PS'
#!/usr/bin/env bash
printf 'Thu Aug 13 12:34:56 2026\n'
PS
chmod +x "$TEST_ROOT/darwin-ps-bin/ps"
if PATH="$TEST_ROOT/darwin-ps-bin:$PATH" bash -c \
    'source "$1"; _sgt_process_start_token 99999999' _ \
    "$ROOT_DIR/bin/_sgt-process-identity.sh" > "$TEST_ROOT/darwin-token"; then
  printf 'DARWIN_LSTART_PROMOTED_TO_EXACT_IDENTITY: %s\n' \
    "$(cat "$TEST_ROOT/darwin-token")" >&2
  exit 1
fi

# Legacy ps:* lock records were produced from second-resolution lstart text.
# They can never prove PID reuse, so even a mismatching live record remains
# unverifiable and must not be reclaimed by a new exact-token producer.
lockdir11="$TEST_ROOT/state-11"
mkdir -p "$lockdir11"
printf 'pid=%s\nstart=ps:Thu Aug 13 12:34:56 2026\nnonce=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' \
  "$$" > "$lockdir11/response.lock"
legacy_ps_record="$(cat "$lockdir11/response.lock")"
if SGT_RESPONSE_LOCK_TIMEOUT=1 _sgt_response_lock_acquire "$lockdir11" \
    2> "$TEST_ROOT/case11.err"; then
  printf 'RECLAIMED_LIVE_LEGACY_PS_OWNER\n' >&2
  exit 1
fi
[[ "$(cat "$lockdir11/response.lock")" == "$legacy_ps_record" ]] || {
  printf 'RECLAIMED_LIVE_LEGACY_PS_OWNER\n' >&2
  exit 1
}

printf 'sgt-response-lock-release: ok\n'
