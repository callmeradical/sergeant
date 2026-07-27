#!/usr/bin/env bash
# _sgt-drain.sh — Drain admission helpers sourced by sgt-dispatch, sgt-respond, and sgt-worker.
# Source this file; do not execute it directly.

[[ "${SGT_DRAIN_LIB_LOADED:-}" == "1" ]] && return 0
SGT_DRAIN_LIB_LOADED=1

_SGT_DRAIN_LIB_DIR="${_SGT_DRAIN_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

_SGT_DRAIN_DIR="${SERGEANT_DRAIN_DIR:-$HOME/.local/share/sergeant/drain}"

# ── State helpers ─────────────────────────────────────────────────────────────

_sgt_drain_global_dir() {
  echo "$_SGT_DRAIN_DIR/global"
}

_sgt_drain_project_dir() {
  local project="$1"
  echo "$_SGT_DRAIN_DIR/projects/$project"
}

_sgt_drain_generation_file() {
  echo "$_SGT_DRAIN_DIR/generation"
}

# Atomically increment drain generation.
_sgt_drain_bump_generation() {
  local gen_file
  gen_file="$(_sgt_drain_generation_file)"
  mkdir -p "$(dirname "$gen_file")"
  local current=0
  if [[ -f "$gen_file" ]]; then
    current="$(tr -d '\n' < "$gen_file" 2>/dev/null || echo 0)"
    [[ "$current" =~ ^[0-9]+$ ]] || current=0
  fi
  local tmp
  tmp="$(mktemp "${gen_file}.tmp.XXXXXX")"
  printf '%s\n' "$((current + 1))" > "$tmp"
  mv "$tmp" "$gen_file"
}

# Return 0 if global drain is active (reason file exists and is readable).
_sgt_drain_global_active() {
  [[ -f "$_SGT_DRAIN_DIR/global/reason" ]]
}

# Return 0 if project drain is active.
_sgt_drain_project_active() {
  local project="$1"
  [[ -n "$project" ]] && [[ -f "$_SGT_DRAIN_DIR/projects/$project/reason" ]]
}

# ── Admission lock ─────────────────────────────────────────────────────────────
# Admission lock serialises drain-set writes against dispatch/relaunch checks.
# Both drain creation and the admission check must acquire this lock.
#
# Usage: _sgt_drain_lock_acquire; ...; _sgt_drain_lock_release
# The lock is held on fd 9 in the calling process.

_SGT_DRAIN_LOCK_FD=9
_SGT_DRAIN_LOCK_FILE=""

_sgt_drain_lock_acquire() {
  _SGT_DRAIN_LOCK_FILE="$_SGT_DRAIN_DIR/admission.lock"
  mkdir -p "$_SGT_DRAIN_DIR"
  # Open fd 9 for writing to the lock file.
  eval "exec ${_SGT_DRAIN_LOCK_FD}>\"\$_SGT_DRAIN_LOCK_FILE\""
  if ! flock -w 10 "$_SGT_DRAIN_LOCK_FD"; then
    eval "exec ${_SGT_DRAIN_LOCK_FD}>&-"
    return 1
  fi
  return 0
}

_sgt_drain_lock_release() {
  eval "exec ${_SGT_DRAIN_LOCK_FD}>&-" 2>/dev/null || true
}

# ── Admission check ────────────────────────────────────────────────────────────
# Check whether dispatch or relaunch for <project> is admitted.
# Returns 0 if admitted; returns 1 (with error on stderr) if drained.
#
# Must be called while holding the admission lock.

_sgt_drain_check_admission() {
  local project="${1:-}"
  if _sgt_drain_global_active; then
    local reason
    reason="$(tr -d '\n' < "$_SGT_DRAIN_DIR/global/reason" 2>/dev/null || echo "")"
    local actor=""
    [[ -f "$_SGT_DRAIN_DIR/global/actor" ]] && actor="$(tr -d '\n' < "$_SGT_DRAIN_DIR/global/actor" 2>/dev/null || true)"
    if [[ -n "$actor" ]]; then
      printf 'ERROR: dispatch rejected: global drain is active (reason: %s, actor: %s)\n' \
        "${reason:-unspecified}" "$actor" >&2
    else
      printf 'ERROR: dispatch rejected: global drain is active (reason: %s)\n' \
        "${reason:-unspecified}" >&2
    fi
    return 1
  fi
  if [[ -n "$project" ]] && _sgt_drain_project_active "$project"; then
    local reason
    reason="$(tr -d '\n' < "$_SGT_DRAIN_DIR/projects/$project/reason" 2>/dev/null || echo "")"
    local actor=""
    [[ -f "$_SGT_DRAIN_DIR/projects/$project/actor" ]] && \
      actor="$(tr -d '\n' < "$_SGT_DRAIN_DIR/projects/$project/actor" 2>/dev/null || true)"
    if [[ -n "$actor" ]]; then
      printf 'ERROR: dispatch rejected: project drain is active for %s (reason: %s, actor: %s)\n' \
        "$project" "${reason:-unspecified}" "$actor" >&2
    else
      printf 'ERROR: dispatch rejected: project drain is active for %s (reason: %s)\n' \
        "$project" "${reason:-unspecified}" >&2
    fi
    return 1
  fi
  return 0
}

# ── Convenience: lock + check + unlock in one call ─────────────────────────────
# Exits the calling script with an error message if drain is active.
# Intended for use at dispatch/relaunch admission boundaries.

_sgt_drain_admit_or_die() {
  local project="${1:-}"
  if ! _sgt_drain_lock_acquire; then
    printf 'ERROR: cannot acquire drain admission lock\n' >&2
    return 1
  fi
  if ! _sgt_drain_check_admission "$project"; then
    _sgt_drain_lock_release
    return 1
  fi
  _sgt_drain_lock_release
  return 0
}

# ── Read current drain generation ─────────────────────────────────────────────

_sgt_drain_current_generation() {
  local gen_file
  gen_file="$(_sgt_drain_generation_file)"
  if [[ -f "$gen_file" ]]; then
    tr -d '\n' < "$gen_file" 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

# ── Fast-path drain check (no lock) ───────────────────────────────────────────
# For use inside worker polling loops where acquiring the full admission lock
# on every iteration would be too expensive.  These functions do a plain file-
# existence check; they fail-open (return 1 = not drained) rather than fail-
# closed because they are not used for admission gates.

_sgt_drain_global_active() {
  _sgt_drain_is_drained "$(_sgt_drain_global_file)"
}

_sgt_drain_project_active() {
  local project="$1"
  [[ -n "$project" ]] && _sgt_drain_is_drained "$(_sgt_drain_project_file "$project")"
}
