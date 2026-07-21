#!/usr/bin/env bash
# Shared serialization for response publication and consumption.

_sgt_response_lock_acquire() {
  local repo_state="$1"
  local lock_dir="$repo_state/response.lock"
  local owner

  while ! mkdir "$lock_dir" 2>/dev/null; do
    owner="$(cat "$lock_dir/pid" 2>/dev/null || true)"
    if [[ -n "$owner" ]] && ! kill -0 "$owner" 2>/dev/null; then
      rm -f "$lock_dir/pid"
      rmdir "$lock_dir" 2>/dev/null || true
      continue
    fi
    sleep "${SGT_RESPONSE_LOCK_INTERVAL:-0.01}"
  done

  printf '%s\n' "$BASHPID" > "$lock_dir/pid"
  _SGT_RESPONSE_LOCK_DIR="$lock_dir"
}

_sgt_response_lock_release() {
  [[ -n "${_SGT_RESPONSE_LOCK_DIR:-}" ]] || return 0
  local owner
  owner="$(cat "$_SGT_RESPONSE_LOCK_DIR/pid" 2>/dev/null || true)"
  if [[ "$owner" == "$BASHPID" ]]; then
    rm -f "$_SGT_RESPONSE_LOCK_DIR/pid"
    rmdir "$_SGT_RESPONSE_LOCK_DIR" 2>/dev/null || true
  fi
  _SGT_RESPONSE_LOCK_DIR=""
}
