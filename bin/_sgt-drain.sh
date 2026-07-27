#!/usr/bin/env bash
# _sgt-drain.sh — Durable drain-state module and atomic dispatch admission seam.
# Source this file; do not execute it directly.
#
# Provides:
#   _sgt_drain_dir           — canonical drain state root
#   _sgt_drain_lock_file     — admission lock path
#   _sgt_drain_global_file   — global drain record path
#   _sgt_drain_project_file  — project drain record path
#   _sgt_drain_write         — write drain record atomically
#   _sgt_drain_read_field    — extract a named field from a drain file
#   _sgt_drain_is_drained    — test drain state (fails closed on malformed)
#   _sgt_drain_with_lock     — run a callback while holding the admission lock
#   _sgt_drain_check_admission  — acquire lock, check drain, return 0 if admitted
#   _sgt_drain_clear         — remove a drain record

[[ "${SGT_DRAIN_LIB_LOADED:-}" == "1" ]] && return 0
SGT_DRAIN_LIB_LOADED=1

# ── Paths ─────────────────────────────────────────────────────────────────────

_sgt_drain_dir() {
  echo "${SERGEANT_DRAIN_DIR:-${HOME}/.local/share/sergeant/drains}"
}

_sgt_drain_lock_file() {
  echo "$(_sgt_drain_dir)/admission.lock"
}

_sgt_drain_global_file() {
  echo "$(_sgt_drain_dir)/global/drain"
}

_sgt_drain_project_file() {
  local project="$1"
  echo "$(_sgt_drain_dir)/projects/$project/drain"
}

# ── Write ─────────────────────────────────────────────────────────────────────
# _sgt_drain_write <file> <reason> <actor> [<deadline>]
#
# Atomically writes a drain record to <file>.
# Fields: reason, actor, created_at, deadline (optional metadata — stored but
# not used to auto-expire; drains persist until explicit undrain).

_sgt_drain_write() {
  local file="$1" reason="$2" actor="$3" deadline="${4:-}"
  local dir tmp
  dir="$(dirname "$file")"
  mkdir -p "$dir"
  tmp="$(mktemp "${file}.tmp.XXXXXX")"
  {
    printf 'reason=%s\n' "$reason"
    printf 'actor=%s\n' "$actor"
    printf 'created_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ -n "$deadline" ]]; then
      printf 'deadline=%s\n' "$deadline"
    fi
  } > "$tmp"
  mv "$tmp" "$file"
}

# ── Read field ────────────────────────────────────────────────────────────────
# _sgt_drain_read_field <file> <field>
#
# Extracts the value of a named field (key=value) from a drain record.
# Returns empty string if the field is absent.

_sgt_drain_read_field() {
  local file="$1" field="$2"
  grep -m1 "^${field}=" "$file" 2>/dev/null | cut -d= -f2- || true
}

# ── Test ──────────────────────────────────────────────────────────────────────
# _sgt_drain_is_drained <file>
#
# Returns 0 (drained / fail-closed) when the file exists, regardless of content.
# Returns 1 (not drained) only when the file does not exist.
#
# Drain records persist until explicit undrain — they do not auto-expire.
# The deadline field is stored metadata for operator reference only.
# Malformed files (any content) also fail closed.

_sgt_drain_is_drained() {
  local file="$1"
  [[ -f "$file" ]]
}

# ── Lock helper ───────────────────────────────────────────────────────────────
# _sgt_drain_with_lock <callback_body>
#
# Acquires the exclusive admission lock and executes <callback_body> as a
# command string inside the lock subshell, printing its stdout.
# Exits 1 with an error message if the lock cannot be acquired.

_sgt_drain_with_lock() {
  local body="$1"
  local lock_file
  lock_file="$(_sgt_drain_lock_file)"
  mkdir -p "$(dirname "$lock_file")"
  (
    flock -x -w "${SERGEANT_DRAIN_LOCK_TIMEOUT_SECS:-10}" 200 || {
      printf 'ERROR: could not acquire drain admission lock\n' >&2
      exit 1
    }
    eval "$body"
  ) 200>"$lock_file"
}

# ── Clear ─────────────────────────────────────────────────────────────────────
# _sgt_drain_clear <file>
#
# Removes the drain record if it exists.  No-op if not present.

_sgt_drain_clear() {
  local file="$1"
  rm -f "$file"
}

# ── Admission check ───────────────────────────────────────────────────────────
# _sgt_drain_check_admission <project>
#
# Acquires the exclusive admission lock, checks both the global and
# project-specific drain records, and returns:
#   0 — admitted (dispatch may proceed)
#   1 — rejected (global or project drain is active)
#
# Rejection message is printed to stderr.
# Fails closed on lock acquisition failure.

_sgt_drain_check_admission() {
  local project="$1"
  local global_file project_file result
  global_file="$(_sgt_drain_global_file)"
  project_file="$(_sgt_drain_project_file "$project")"

  result="$(_sgt_drain_with_lock "
    if _sgt_drain_is_drained \"$global_file\"; then
      printf 'global\n'
    elif _sgt_drain_is_drained \"$project_file\"; then
      printf 'project\n'
    else
      printf 'admitted\n'
    fi
  ")"

  case "$result" in
    global)
      printf 'ERROR: dispatch rejected: global drain is active\n' >&2
      return 1
      ;;
    project)
      printf 'ERROR: dispatch rejected: project drain is active for %s\n' "$project" >&2
      return 1
      ;;
    admitted)
      return 0
      ;;
    *)
      printf 'ERROR: dispatch rejected: drain admission check failed\n' >&2
      return 1
      ;;
  esac
}

# ── Fast-path drain check (no lock) ───────────────────────────────────────────
# For use inside worker polling loops where acquiring the full admission lock
# on every iteration would be too expensive. These functions do a plain file-
# existence check; they fail-open (return 1 = not drained) rather than fail-
# closed because they are not used for admission gates.

_sgt_drain_global_active() {
  _sgt_drain_is_drained "$(_sgt_drain_global_file)"
}

_sgt_drain_project_active() {
  local project="$1"
  [[ -n "$project" ]] && _sgt_drain_is_drained "$(_sgt_drain_project_file "$project")"
}
