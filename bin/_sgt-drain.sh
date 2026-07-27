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
#   _sgt_drain_is_drained    — test drain state (fails closed on malformed/expired)
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
# Fields: reason, actor, created_at, deadline (optional).

_sgt_drain_write() {
  local file="$1" reason="$2" actor="$3" deadline="${4:-}"
  local dir tmp
  dir="$(dirname "$file")"
  mkdir -p "$dir"
  tmp="${file}.tmp.$$.$RANDOM"
  {
    printf 'reason=%s\n' "$reason"
    printf 'actor=%s\n' "$actor"
    printf 'created_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ -n "$deadline" ]]; then
      printf 'deadline=%s\n' "$deadline"
    fi
  } > "$tmp"
  mv "$tmp" "$file"
}

# ── Read / validate ───────────────────────────────────────────────────────────
# _sgt_drain_is_drained <file>
#
# Returns 0 (drained / fail-closed) when:
#   — the file exists with any content (even malformed)
#   — the deadline field is present and expired
# Returns 1 (not drained) when:
#   — the file does not exist
#
# Malformed files and expired deadlines both fail CLOSED (no auto-undrain).

_sgt_drain_is_drained() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  # File exists → drained.
  # Expired deadline check: if a valid deadline exists AND is in the future,
  # the drain is still active.  If deadline is missing, malformed, or in the
  # past, fail closed (still drained).
  return 0
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
  local lock_file global_file project_file result
  lock_file="$(_sgt_drain_lock_file)"
  global_file="$(_sgt_drain_global_file)"
  project_file="$(_sgt_drain_project_file "$project")"

  mkdir -p "$(dirname "$lock_file")"

  result="$(
    (
      flock -x -w 10 200 || { printf 'lock_failed\n'; exit 1; }
      if _sgt_drain_is_drained "$global_file"; then
        printf 'global\n'
      elif _sgt_drain_is_drained "$project_file"; then
        printf 'project\n'
      else
        printf 'admitted\n'
      fi
    ) 200>"$lock_file"
  )"

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
      printf 'ERROR: dispatch rejected: drain admission lock failed\n' >&2
      return 1
      ;;
  esac
}
