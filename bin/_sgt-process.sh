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
  fields="$(_sgt_process_stat_fields "$1")" || return 1
  printf '%s\n' "${fields%% *}"
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
    value="$(stat -f '%d:%i' "/dev/fd/$fd" 2>/dev/null || true)"
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
