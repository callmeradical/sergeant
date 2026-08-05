#!/usr/bin/env bash
# Shared serialization and archive format for response publication and consumption.

_SGT_RESPONSE_LOCK_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/_sgt-bash-version.sh
source "$_SGT_RESPONSE_LOCK_SCRIPT_DIR/_sgt-bash-version.sh"
_sgt_require_running_bash || return 1

# ── Response archive format ──────────────────────────────────────────────────
# A consumed response is recorded as a directory of four fields: `body` (the
# exact response transport), `gate_generation`, `applied_status`, and `proof`
# (the worker's .sergeant-response-applied record).  sgt-ack-response publishes
# these entries, sgt-cleanup validates them before retiring fleet state, and
# sgt-cleanup's retirement archive reuses the same field names for the fields it
# can prove.  Every reader parses the format through the helpers below so the
# format has exactly one definition.
_SGT_RESPONSE_ARCHIVE_FIELDS="body gate_generation applied_status proof"

# Print the single value of one `key=value` field, or fail when the key is
# missing, empty, or recorded more than once.
_sgt_response_archive_field() {
  local key="$1" record_file="$2"

  awk -F= -v key="$key" '
    $1 == key { count++; value = substr($0, length(key) + 2) }
    END { if (count == 1 && value != "") print value; else exit 1 }
  ' "$record_file"
}

# A retired handshake records the same fields, so an archive entry also has to
# prove it is not one: sgt-cleanup marks a retirement archive with this file, and
# an entry carrying it is never an acknowledgement no matter where it is found.
_SGT_RESPONSE_RETIRED_MARKER="retired"

# Every canonical field of an archive entry is present as a regular file, and the
# entry does not claim to be a retirement.
_sgt_response_archive_entry_complete() {
  local entry="$1" field

  [[ -d "$entry" && ! -L "$entry" ]] || return 1
  [[ ! -e "$entry/$_SGT_RESPONSE_RETIRED_MARKER" && \
    ! -L "$entry/$_SGT_RESPONSE_RETIRED_MARKER" ]] || return 1
  for field in $_SGT_RESPONSE_ARCHIVE_FIELDS; do
    [[ -f "$entry/$field" && ! -L "$entry/$field" ]] || return 1
  done
}

# A complete entry whose recorded proof binds the same response identity,
# gate generation, and applied status as the entry itself.
#
# Every field must be present and non-empty.  An empty `applied_status` beside a
# `proof` with no `status=` line would otherwise compare equal as "" == "" and let
# an entry that records no applied status at all pass as a complete
# acknowledgement, so the three proof lookups must succeed rather than default to
# empty and both entry fields are range-checked.
_sgt_response_archive_entry_matches() {
  local entry="$1" response_id="$2" gate_generation="$3"
  local applied_status entry_generation proof_generation proof_id proof_status

  [[ -n "$response_id" && "$gate_generation" =~ ^[1-9][0-9]*$ ]] || return 1
  _sgt_response_archive_entry_complete "$entry" || return 1
  applied_status="$(cat "$entry/applied_status")" || return 1
  entry_generation="$(cat "$entry/gate_generation")" || return 1
  [[ -n "$applied_status" && "$entry_generation" == "$gate_generation" ]] || return 1
  proof_id="$(_sgt_response_archive_field response_id "$entry/proof")" || return 1
  proof_generation="$(_sgt_response_archive_field gate_generation "$entry/proof")" || return 1
  proof_status="$(_sgt_response_archive_field status "$entry/proof")" || return 1
  [[ "$proof_id" == "$response_id" && "$proof_generation" == "$gate_generation" && \
    "$proof_status" == "$applied_status" ]]
}

_sgt_response_lock_acquire() {
  local repo_state="$1"
  local lock_name="${2:-response.lock}"
  local lock_path="$repo_state/$lock_name"
  local candidate="$repo_state/.$lock_name.$$.$RANDOM.$RANDOM"
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
      if [[ -z "$owner" ]]; then
        # Lock file disappeared between the -e check and the read (TOCTOU: just released).
        # Retry; the next iteration will find the file gone and attempt ln.
        continue
      fi
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

# Release the caller-owned response lock.
# Success, or discovering that another PID owns the lock, clears
# _SGT_RESPONSE_LOCK_DIR. If removing our own lock fails, preserve
# _SGT_RESPONSE_LOCK_DIR and return non-zero so callers can retry without
# spinning on their own live PID.
_sgt_response_lock_release() {
  [[ -n "${_SGT_RESPONSE_LOCK_DIR:-}" ]] || return 0
  local owner
  owner="$(cat "$_SGT_RESPONSE_LOCK_DIR" 2>/dev/null || true)"
  if [[ "$owner" == "$$" ]]; then
    if ! rm -f "$_SGT_RESPONSE_LOCK_DIR"; then
      printf 'ERROR: Could not release response lock: %s\n' "$_SGT_RESPONSE_LOCK_DIR" >&2
      return 1
    fi
  fi
  _SGT_RESPONSE_LOCK_DIR=""
}
