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
