#!/usr/bin/env bash
# Shared high-resolution process birth identity adapter.

_sgt_process_start_token() {
  local pid="$1" token
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  if [[ -r "/proc/$pid/stat" ]]; then
    token="$(awk '{ print $22 }' "/proc/$pid/stat" 2>/dev/null)" || return 1
    [[ "$token" =~ ^[0-9]+$ ]] || return 1
    printf 'proc:%s\n' "$token"
  else
    token="$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]][[:space:]]*/ /g')" || return 1
    [[ -n "$token" ]] || return 1
    printf 'ps:%s\n' "$token"
  fi
}
