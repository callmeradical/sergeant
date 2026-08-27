#!/usr/bin/env bash
# Portable process identity adapter. Linux names the session column `sid`;
# Darwin/BSD name it `sess`. Callers never invoke either spelling directly.

_sgt_process_session_id() {
  local pid="$1" value
  value="$(ps -o sid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    value="$(ps -o sess= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  fi
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "$value"
}

_sgt_process_table() {
  local output
  output="$(ps -axo pid=,ppid=,sid= 2>/dev/null || true)"
  if [[ -z "$output" ]]; then
    output="$(ps -axo pid=,ppid=,sess= 2>/dev/null || true)"
  fi
  [[ -n "$output" ]] || return 1
  printf '%s\n' "$output"
}

_sgt_process_stat_fields() {
  local pid="$1" proc_root stat rest state ppid pgid sid starttime
  proc_root="${SGT_PROC_ROOT:-/proc}"
  if [[ ! -r "$proc_root/$pid/stat" && -n "${SGT_PROC_ROOT:-}" ]]; then
    proc_root=/proc
  fi
  [[ -r "$proc_root/$pid/stat" ]] || return 1
  stat="$(cat "$proc_root/$pid/stat" 2>/dev/null)" || return 1
  rest="${stat##*) }"
  # shellcheck disable=SC2086  # /proc stat fields are intentionally positional.
  set -- $rest
  [[ $# -ge 20 ]] || return 1
  state="$1"; ppid="$2"; pgid="$3"; sid="$4"; starttime="${20}"
  [[ "$state" =~ ^[A-Zt]$ && "$ppid" =~ ^[0-9]+$ && "$pgid" =~ ^[0-9]+$ &&
    "$sid" =~ ^[0-9]+$ && "$starttime" =~ ^[0-9]+$ ]] || return 1
  printf 'linux:%s %s %s %s %s\n' "$starttime" "$ppid" "$pgid" "$sid" "$state"
}

_sgt_process_identity() {
  local fields
  if [[ "${SGT_TEST_HOOKS:-}" == 1 && \
    "${SGT_TEST_PROCESS_IDENTITY_UNAVAILABLE:-}" == 1 ]]; then
    return 1
  fi
  fields="$(_sgt_process_stat_fields "$1")" || return 1
  printf '%s\n' "${fields%% *}"
}

_sgt_process_identity_record() {
  local pid="$1" identity platform
  identity="$(_sgt_process_identity "$pid" 2>/dev/null || true)"
  if [[ -n "$identity" ]]; then
    printf '%s\n' "$identity"
    return 0
  fi
  if [[ "${SGT_TEST_HOOKS:-}" == 1 && \
    -n "${SGT_TEST_PROCESS_PLATFORM:-}" ]]; then
    platform="$SGT_TEST_PROCESS_PLATFORM"
  else
    platform="$(uname -s 2>/dev/null || true)"
  fi
  [[ "$platform" == Darwin ]] || return 1
  if [[ "${SGT_TEST_HOOKS:-}" != 1 || \
    "${SGT_TEST_PROCESS_ASSUME_LIVE:-}" != 1 ]]; then
    kill -0 "$pid" 2>/dev/null || return 1
  fi
  printf 'platform:Darwin:no-exact-process-birth\n'
}

_sgt_process_identity_record_is_portable() {
  [[ "$1" == platform:Darwin:no-exact-process-birth ]]
}

_sgt_process_state() {
  local fields
  fields="$(_sgt_process_stat_fields "$1")" || return 1
  printf '%s\n' "${fields##* }"
}

_sgt_fd_identity() {
  local fd="$1" value
  value="$(stat -Lc '%d:%i' "/proc/$$/fd/$fd" 2>/dev/null || true)"
  if [[ -z "$value" ]]; then
    # `stat -f '%d:%i' "/dev/fd/$fd"` looked like an equivalent non-Linux
    # fallback, but it stats the *path* /dev/fd/$fd, which on macOS resolves
    # through the synthetic fdesc filesystem: the inode passes through
    # correctly but the reported device number is fdesc's own, not the real
    # underlying file's -- so this always disagreed with an identity recorded
    # from the real path (`stat -f '%d:%i'` on the file itself), failing
    # every comparison unconditionally on macOS. A real fstat(2) on the fd
    # itself (bypassing /dev/fd entirely) reports the true device, matching
    # what _sgt-verify-owned-fd.py already does correctly in Python.
    value="$(python3 -c '
import os, sys
try:
    st = os.fstat(int(sys.argv[1]))
except (OSError, ValueError):
    raise SystemExit(1)
print(f"{st.st_dev}:{st.st_ino}")
' "$fd" 2>/dev/null || true)"
  fi
  [[ "$value" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  printf '%s\n' "$value"
}

# _sgt_worker_marker_holders <repo-state>
#
# Lists exact live marker holders. A nonzero result means holder absence could
# not be proved (including unreadable same-UID post-launch fd tables).
_sgt_worker_marker_holders() {
  local repo_dir="$1" history="$1/worker_process_markers" platform_record=""
  local current_marker history_digest
  if [[ ( -e "$repo_dir/worker_process_marker" || \
    -L "$repo_dir/worker_process_marker" ) && \
    ! -e "$history" && ! -L "$history" ]]; then
    printf 'worker process marker exists without durable history: %s\n' "$repo_dir" >&2
    return 1
  fi
  if [[ -s "$repo_dir/worker_process_marker_platform" ]]; then
    platform_record="$(_sgt_read_owned_file \
      "$repo_dir/worker_process_marker_platform" 2>/dev/null || true)"
    [[ "$platform_record" == Darwin:no-exact-process-birth ]] || {
      printf 'unsupported worker marker platform evidence: %s\n' \
        "${platform_record:-unreadable}" >&2
      return 1
    }
  fi
  [[ ! -L "$history" ]] || {
    printf 'worker process marker history is a symlink: %s\n' "$history" >&2
    return 1
  }
  [[ ! -e "$history" || -f "$history" ]] || {
    printf 'worker process marker history is not a regular file: %s\n' "$history" >&2
    return 1
  }
  [[ -f "$history" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 1
  if [[ -e "$repo_dir/worker_process_marker" || \
    -L "$repo_dir/worker_process_marker" ]]; then
    current_marker="$(_sgt_read_owned_file \
      "$repo_dir/worker_process_marker" 2>/dev/null || true)"
    history_digest="$(_sgt_marker_history_digest \
      "$history" "$current_marker" 2>/dev/null || true)"
    [[ -n "$current_marker" && "$history_digest" =~ ^[0-9a-f]{64}$ ]] || {
      printf 'current worker process marker is absent from valid durable history\n' >&2
      return 1
    }
  fi
  if [[ -n "$platform_record" ]]; then
    python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_sgt-process-token.py" \
      portable-holders "$history"
  else
    python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_sgt-process-token.py" \
      holders "$history"
  fi
}

# _sgt_retire_worker_marker_holders <repo-state> [phase-file]
#
# Retires every capability holder through pidfds and returns only after a fresh
# scan proves none remain. Successful retirement also compacts closed marker
# generations so an inode reused by an unrelated file is never retained.
_sgt_retire_worker_marker_holders() {
  local repo_dir="$1" phase="${2:-/dev/null}" history holders platform_record=""
  local current_marker history_digest
  history="$repo_dir/worker_process_markers"
  if [[ ( -e "$repo_dir/worker_process_marker" || \
    -L "$repo_dir/worker_process_marker" ) && \
    ! -e "$history" && ! -L "$history" ]]; then
    printf 'worker process marker exists without durable history: %s\n' "$repo_dir" >&2
    return 1
  fi
  if [[ -s "$repo_dir/worker_process_marker_platform" ]]; then
    platform_record="$(_sgt_read_owned_file \
      "$repo_dir/worker_process_marker_platform" 2>/dev/null || true)"
    [[ "$platform_record" == Darwin:no-exact-process-birth ]] || {
      printf 'unsupported worker marker platform evidence: %s\n' \
        "${platform_record:-unreadable}" >&2
      return 1
    }
  fi
  [[ ! -L "$history" ]] || {
    printf 'worker process marker history is a symlink: %s\n' "$history" >&2
    return 1
  }
  [[ ! -e "$history" || -f "$history" ]] || {
    printf 'worker process marker history is not a regular file: %s\n' "$history" >&2
    return 1
  }
  [[ -f "$history" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 1
  if [[ -e "$repo_dir/worker_process_marker" || \
    -L "$repo_dir/worker_process_marker" ]]; then
    current_marker="$(_sgt_read_owned_file \
      "$repo_dir/worker_process_marker" 2>/dev/null || true)"
    history_digest="$(_sgt_marker_history_digest \
      "$history" "$current_marker" 2>/dev/null || true)"
    [[ -n "$current_marker" && "$history_digest" =~ ^[0-9a-f]{64}$ ]] || {
      printf 'current worker process marker is absent from valid durable history\n' >&2
      return 1
    }
  fi
  if [[ -n "$platform_record" ]]; then
    holders="$(python3 \
      "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_sgt-process-token.py" \
      portable-holders "$history")" || return 1
    if [[ -n "$holders" ]]; then
      printf 'portable worker marker holders remain live; no PID was signalled: %s\n' \
        "$(tr '\n' ' ' <<< "$holders")" >&2
      return 1
    fi
    return 0
  fi
  [[ -f "$phase" && ! -L "$phase" ]] || phase=/dev/null
  python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_sgt-process-token.py" \
    retire "$history" "$phase"
}

_sgt_marker_history_digest() {
  local history="$1" marker="${2:-}"
  command -v python3 >/dev/null 2>&1 || return 1
  if [[ -n "$marker" ]]; then
    python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_sgt-marker-history.py" \
      "$history" "$marker"
  else
    python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_sgt-marker-history.py" \
      "$history"
  fi
}

# _sgt_terminate_verified_pid <pid> <recorded_start> [wait_deciseconds=50]
#
# The PID-identity-checked SIGTERM-then-poll-then-SIGKILL escalation shared by
# sgt-drain-force and bin/sgt-stop-all (openspec/changes/dispatch-admission-control):
# verifies the live process's exact start-time identity matches
# <recorded_start> before signaling at all, so a PID recycled by an unrelated
# process is never killed. Polls for exit up to wait_deciseconds (default 50 =
# 5s) after SIGTERM, escalating to SIGKILL only if still alive.
#
# Returns:
#   0  identity verified; process is gone (either it exited on its own or was
#      signaled and confirmed gone/killed)
#   1  identity unproven (pid not alive, or recorded/actual start mismatch) —
#      no signal was sent
_sgt_terminate_verified_pid() {
  local pid="$1" recorded_start="$2" wait_deciseconds="${3:-50}"
  local actual_start waited=0
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 0
  actual_start="$(_sgt_process_identity "$pid" 2>/dev/null || true)"
  [[ -n "$recorded_start" && -n "$actual_start" && \
    "$actual_start" == "$recorded_start" ]] || return 1
  kill -TERM "$pid" 2>/dev/null || return 0
  while [[ "$waited" -lt "$wait_deciseconds" ]]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    waited=$((waited + 1))
  done
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
  return 0
}
