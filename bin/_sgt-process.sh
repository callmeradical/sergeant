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

_sgt_process_start() {
  ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//;s/ *$//'
}
