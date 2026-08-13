#!/usr/bin/env bash
# Shared high-resolution process birth identity adapter.

_sgt_process_start_token() {
  local pid="$1" token
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  if [[ "${SGT_TEST_HOOKS:-}" == 1 &&
        "${SGT_TEST_PROCESS_START_UNAVAILABLE:-}" == 1 ]]; then
    return 1
  fi
  if [[ -r "/proc/$pid/stat" ]]; then
    token="$(awk '{ print $22 }' "/proc/$pid/stat" 2>/dev/null)" || return 1
    [[ "$token" =~ ^[0-9]+$ ]] || return 1
    printf 'proc:%s\n' "$token"
  else
    # `ps lstart` is only second-resolution.  Two processes born within the
    # same second can therefore share it, so it is never exact ownership proof.
    # Platforms without /proc use the portable marker/pane evidence path and
    # must fail closed anywhere an exact process-birth token is required.
    return 1
  fi
}

# Classify one PID from a successful complete process-table snapshot.
#   0: present, 1: proven absent, 2: probe failed or returned malformed data.
# A targeted `ps -p` commonly returns the same nonzero status for both absence
# and operational errors, so ownership fencing must not use it as a death probe.
_sgt_process_pid_presence() {
  local pid="$1" snapshot line seen=false saw_valid=false parse_status=0
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 2
  snapshot="$(mktemp "${TMPDIR:-/tmp}/sgt-pid-snapshot.XXXXXX")" || return 2
  if ps -A -o pid= > "$snapshot" 2>/dev/null; then
    :
  elif ps -axo pid= > "$snapshot" 2>/dev/null; then
    :
  else
    rm -f "$snapshot"
    return 2
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//[[:space:]]/}"
    [[ -z "$line" ]] && continue
    if [[ ! "$line" =~ ^[1-9][0-9]*$ ]]; then
      parse_status=2
      break
    fi
    saw_valid=true
    [[ "$line" == "$pid" ]] && seen=true
  done < "$snapshot"
  rm -f "$snapshot"
  [[ "$parse_status" -eq 0 && "$saw_valid" == true ]] || return 2
  [[ "$seen" == true ]] && return 0
  return 1
}
