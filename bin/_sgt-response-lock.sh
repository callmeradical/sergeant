#!/usr/bin/env bash
# Shared serialization for response publication and consumption.

_SGT_RESPONSE_LOCK_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/_sgt-bash-version.sh
source "$_SGT_RESPONSE_LOCK_SCRIPT_DIR/_sgt-bash-version.sh"
_sgt_require_running_bash || return 1

_sgt_response_lock_acquire() {
  local repo_state="$1"
  local lock_path="$repo_state/response.lock"
  local candidate="$repo_state/.response.lock.$$.$RANDOM.$RANDOM"
  local candidate_name="${candidate##*/}"
  local owner current_owner interval
  interval="${SGT_RESPONSE_LOCK_INTERVAL:-0.01}"

  if ! printf '%s\n' "$$" > "$candidate"; then
    printf 'ERROR: Could not create response lock candidate: %s\n' "$candidate" >&2
    return 1
  fi

  while true; do
    if [[ -d "$lock_path" ]]; then
      owner="$(cat "$lock_path/pid" 2>/dev/null || true)"
      if [[ -z "$owner" ]]; then
        if [[ -n "$(ls -A "$lock_path" 2>/dev/null)" ]]; then
          rm -f "$candidate"
          printf 'ERROR: Response lock directory has no valid owner: %s\n' "$lock_path" >&2
          return 1
        fi
        if [[ -z "$(find "$lock_path" -prune -mmin +0 -print 2>/dev/null)" ]]; then
          sleep "$interval"
          continue
        fi
      else
        if [[ ! "$owner" =~ ^[0-9]+$ ]]; then
          rm -f "$candidate"
          printf 'ERROR: Response lock directory has an invalid owner: %s\n' "$lock_path" >&2
          return 1
        fi
        if kill -0 "$owner" 2>/dev/null; then
          sleep "$interval"
          continue
        fi
      fi

      current_owner="$(cat "$lock_path/pid" 2>/dev/null || true)"
      if [[ "$current_owner" != "$owner" ]]; then
        continue
      fi
      if [[ -n "$owner" ]] && ! rm -f "$lock_path/pid"; then
        rm -f "$candidate"
        printf 'ERROR: Could not remove stale response lock owner: %s\n' "$lock_path/pid" >&2
        return 1
      fi
      if ! rmdir "$lock_path" 2>/dev/null; then
        rm -f "$candidate"
        printf 'ERROR: Could not recover response lock directory: %s\n' "$lock_path" >&2
        return 1
      fi
      continue
    fi

    if [[ -e "$lock_path" || -L "$lock_path" ]]; then
      owner="$(cat "$lock_path" 2>/dev/null || readlink "$lock_path" 2>/dev/null || true)"
      if [[ ! "$owner" =~ ^[0-9]+$ ]]; then
        rm -f "$candidate"
        printf 'ERROR: Response lock has an invalid owner: %s\n' "$lock_path" >&2
        return 1
      fi
      if kill -0 "$owner" 2>/dev/null; then
        sleep "$interval"
        continue
      fi
      current_owner="$(cat "$lock_path" 2>/dev/null || readlink "$lock_path" 2>/dev/null || true)"
      if [[ "$current_owner" == "$owner" ]]; then
        if ! rm -f "$lock_path"; then
          rm -f "$candidate"
          printf 'ERROR: Could not remove stale response lock: %s\n' "$lock_path" >&2
          return 1
        fi
      fi
      continue
    fi

    if ln "$candidate" "$lock_path" 2>/dev/null; then
      if [[ "$lock_path" -ef "$candidate" ]]; then
        rm -f "$candidate"
        _SGT_RESPONSE_LOCK_DIR="$lock_path"
        return 0
      fi
      rm -f "$lock_path/$candidate_name"
    elif [[ ! -e "$lock_path" && ! -L "$lock_path" ]]; then
      rm -f "$candidate"
      printf 'ERROR: Could not create response lock: %s\n' "$lock_path" >&2
      return 1
    fi
  done
}

_sgt_response_lock_release() {
  [[ -n "${_SGT_RESPONSE_LOCK_DIR:-}" ]] || return 0
  local owner
  owner="$(cat "$_SGT_RESPONSE_LOCK_DIR" 2>/dev/null || true)"
  if [[ "$owner" == "$$" ]]; then
    if ! rm -f "$_SGT_RESPONSE_LOCK_DIR"; then
      printf 'ERROR: Could not release response lock: %s\n' "$_SGT_RESPONSE_LOCK_DIR" >&2
      _SGT_RESPONSE_LOCK_DIR=""
      return 1
    fi
  fi
  _SGT_RESPONSE_LOCK_DIR=""
}
