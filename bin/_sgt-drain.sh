#!/usr/bin/env bash
# _sgt-drain.sh — Drain state helpers sourced by sgt-* scripts.
# Source this file; do not execute it directly.
#
# Provides: _sgt_is_drained, _sgt_drain_state_dir,
#           _sgt_drain_global_file, _sgt_drain_project_file,
#           _sgt_drain_is_drained (file-path variant),
#           _sgt_drain_write, _sgt_drain_global_active,
#           _sgt_drain_project_active,
#           _sgt_drain_clear, _sgt_drain_read_field,
#           _sgt_drain_lock_file, _sgt_drain_lock_acquire_fd,
#           _sgt_drain_lock_release_fd,
#           _sgt_drain_check_admission_locked,
#           _sgt_drain_with_lock, _sgt_drain_check_admission,
#           _sgt_drain_remove_global, _sgt_drain_remove_project
#
# Drain state location: $SERGEANT_CONFIG/drain/
#   Global drain:  $SERGEANT_CONFIG/drain/global
#   Project drain: $SERGEANT_CONFIG/drain/<project>
#
# Drain file format (plain text, key=value lines):
#   reason=<text>     optional
#   actor=<text>      optional
#   created_at=<ISO-8601 timestamp>  always present

[[ "${SGT_DRAIN_LIB_LOADED:-}" == "1" ]] && return 0
SGT_DRAIN_LIB_LOADED=1

_sgt_drain_state_dir() {
  if [[ -n "${SERGEANT_DRAIN_DIR:-}" ]]; then
    printf '%s\n' "$SERGEANT_DRAIN_DIR"
  else
    printf '%s\n' "${SERGEANT_CONFIG:-$HOME/.config/sergeant}/drain"
  fi
}

# _sgt_drain_dir — alias for _sgt_drain_state_dir
_sgt_drain_dir() {
  _sgt_drain_state_dir
}

# _sgt_drain_lock_file
#
# Prints the path to the drain admission lock file.
_sgt_drain_lock_file() {
  printf '%s/admission.lock\n' "$(_sgt_drain_state_dir)"
}

# _sgt_drain_global_file
#
# Prints the path to the global drain file.
# When SERGEANT_DRAIN_DIR is set uses a subdirectory layout.
_sgt_drain_global_file() {
  if [[ -n "${SERGEANT_DRAIN_DIR:-}" ]]; then
    printf '%s/global/drain\n' "$(_sgt_drain_state_dir)"
  else
    printf '%s/global\n' "$(_sgt_drain_state_dir)"
  fi
}

# _sgt_drain_project_file <project>
#
# Prints the path to the per-project drain file.
# When SERGEANT_DRAIN_DIR is set uses a subdirectory layout.
_sgt_drain_project_file() {
  local project="${1:?_sgt_drain_project_file requires a project name}"
  if [[ -n "${SERGEANT_DRAIN_DIR:-}" ]]; then
    printf '%s/projects/%s/drain\n' "$(_sgt_drain_state_dir)" "$project"
  else
    printf '%s/%s\n' "$(_sgt_drain_state_dir)" "$project"
  fi
}

# _sgt_drain_read_project_from_brief <task_dir>
#
# Extracts and validates the project name from the fleet brief.md file
# ($task_dir/brief.md).  Sets the global SGT_PROJECT variable.
# If the file is absent or the name is invalid, SGT_PROJECT is left empty.
_sgt_drain_read_project_from_brief() {
  local task_dir="$1" project
  # shellcheck disable=SC2034  # SGT_PROJECT is consumed by sourcing scripts.
  SGT_PROJECT=""
  [[ -f "$task_dir/brief.md" ]] || return 0
  project="$(sed -n 's/^Project:[[:space:]]*//p' "$task_dir/brief.md")"
  [[ "$project" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 0
  # shellcheck disable=SC2034  # SGT_PROJECT is consumed by sourcing scripts.
  SGT_PROJECT="$project"
}

# _sgt_is_drained <project>
#
# Returns 0 (true) if a global drain or a matching project drain is active.
# Returns 1 (false) otherwise — admission proceeds normally.
#
# A project name of "" or a name that does not match [A-Za-z0-9][A-Za-z0-9._-]*
# is treated as absent; only the global drain is checked in that case.
_sgt_is_drained() {
  local project="${1:-}"
  _sgt_drain_is_drained "$(_sgt_drain_global_file)" && return 0
  if [[ -n "$project" && "$project" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    _sgt_drain_is_drained "$(_sgt_drain_project_file "$project")" && return 0
  fi
  return 1
}

# ── Drain admission lock helpers ──────────────────────────────────────────────
#
# These functions implement the advisory drain-admission lock used by
# sgt-respond (and other relaunchers) to serialize the "read drain state →
# start new pane" window so a concurrent sgt-drain cannot slip in between.
#
# Usage pattern (mirroring sgt-respond):
#   exec <N>>/dev/null            # open the fd; real users point it at the dir
#   _sgt_drain_lock_acquire_fd N  # flock; returns 0 on success
#   _sgt_drain_check_admission_locked [project]   # 0 = admit, 1 = draining
#   ... spawn new pane ...
#   _sgt_drain_lock_release_fd N  # release by closing the fd

# _sgt_drain_lock_acquire_fd <fd>
#
# Acquires an exclusive advisory lock on the drain admission lock file,
# attaching it to file descriptor <fd>.  Returns 0 on success.
#
# Falls back gracefully if flock(1) is unavailable (non-Linux or minimal
# installs): the function still returns 0 so that sgt-respond is not blocked
# merely because flock is absent — the drain-state file check in
# _sgt_drain_check_admission_locked remains the authoritative gate.
_sgt_drain_lock_acquire_fd() {
  local fd="${1:?_sgt_drain_lock_acquire_fd requires an fd}"
  local lock_file
  lock_file="$(_sgt_drain_lock_file)"
  mkdir -p "$(dirname "$lock_file")" 2>/dev/null || true
  if command -v flock >/dev/null 2>&1; then
    # shellcheck disable=SC1083
    eval "exec ${fd}>\"${lock_file}\"" 2>/dev/null || true
    # BusyBox flock does not support -w; poll with -n for portability.
    local _deadline=$(( $(date +%s) + ${SERGEANT_DRAIN_LOCK_TIMEOUT_SECS:-10} ))
    until flock -n "$fd" 2>/dev/null; do
      [[ $(date +%s) -lt $_deadline ]] || break
      sleep 0.1 2>/dev/null || sleep 1
    done
  fi
  return 0
}

# _sgt_drain_lock_release_fd <fd>
#
# Releases the advisory lock by closing <fd>.  Safe to call even if
# _sgt_drain_lock_acquire_fd was a no-op (flock unavailable).
_sgt_drain_lock_release_fd() {
  local fd="${1:?_sgt_drain_lock_release_fd requires an fd}"
  # shellcheck disable=SC1083
  eval "exec ${fd}>&-" 2>/dev/null || true
  return 0
}

# _sgt_drain_check_admission_locked [project]
#
# Must be called while the drain admission lock is held (after a successful
# _sgt_drain_lock_acquire_fd).  Returns 0 if admission is allowed (no active
# drain), 1 if a drain is active.
_sgt_drain_check_admission_locked() {
  local project="${1:-}"
  if _sgt_drain_is_drained "$(_sgt_drain_global_file)"; then
    printf 'ERROR: dispatch rejected: global drain is active\n' >&2
    return 1
  fi
  if [[ -n "$project" ]] && _sgt_drain_is_drained "$(_sgt_drain_project_file "$project")"; then
    printf 'ERROR: dispatch rejected: project drain is active for %s\n' "$project" >&2
    return 1
  fi
  return 0
}

# _sgt_drain_with_lock <body>
#
# Runs <body> (a shell string) inside an exclusive flock on the admission lock.
# Used by sgt-drain to atomically read-then-write drain state.
_sgt_drain_with_lock() {
  local body="$1" lock_file
  lock_file="$(_sgt_drain_lock_file)"
  mkdir -p "$(dirname "$lock_file")"
  (
    # BusyBox flock does not support -w; poll with -n for portability.
    local _dl=$(( $(date +%s) + ${SERGEANT_DRAIN_LOCK_TIMEOUT_SECS:-10} ))
    until flock -x -n 200 2>/dev/null; do
      if [[ $(date +%s) -ge $_dl ]]; then
        printf 'ERROR: could not acquire drain admission lock\n' >&2
        exit 1
      fi
      sleep 0.1 2>/dev/null || sleep 1
    done
    eval "$body"
  ) 200>"$lock_file"
}

# _sgt_drain_check_admission <project>
#
# Unlocked version: runs inside _sgt_drain_with_lock.  Returns 0 if admitted,
# 1 if a global or project drain is active (prints an error to stderr).
_sgt_drain_check_admission() {
  local project="$1" result
  result="$(_sgt_drain_with_lock "
    if _sgt_drain_is_drained \"$(_sgt_drain_global_file)\"; then
      printf 'global\\n'
    elif _sgt_drain_is_drained \"$(_sgt_drain_project_file "$project")\"; then
      printf 'project\\n'
    else
      printf 'admitted\\n'
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
    admitted) return 0 ;;
    *)
      printf 'ERROR: dispatch rejected: drain admission check failed\n' >&2
      return 1
      ;;
  esac
}

# ── File-path helpers ─────────────────────────────────────────────────────────

# _sgt_drain_is_drained <drain_file>
#
# File-path variant: returns 0 if the given drain file exists, 1 otherwise.
# Used by sgt-interactive-worker which already resolved the file path.
_sgt_drain_is_drained() {
  [[ -f "${1:?_sgt_drain_is_drained requires a drain file path}" ]]
}

# _sgt_drain_read_field <drain_file> <field>
#
# Reads a single field value from a drain file.  Returns empty string if the
# file is absent or the field is not present.
_sgt_drain_read_field() {
  local file="$1" field="$2"
  grep -m1 "^${field}=" "$file" 2>/dev/null | cut -d= -f2- || true
}

# _sgt_drain_write <drain_file> [reason] [actor] [deadline]
#
# Creates a drain file atomically using a tmp+mv pattern.  The caller must
# have already resolved the drain file path (e.g. via _sgt_drain_global_file
# or _sgt_drain_project_file).  reason, actor, and deadline are optional fields
# recorded in the drain file for human inspection; drain activation is based
# solely on file existence.
_sgt_drain_write() {
  local drain_file="${1:?_sgt_drain_write requires a drain file path}"
  local reason="${2:-}"
  local actor="${3:-}"
  local deadline="${4:-}"
  local temporary
  mkdir -p "$(dirname "$drain_file")" 2>/dev/null || true
  temporary="$(mktemp "${drain_file}.tmp.XXXXXX")"
  {
    [[ -z "$reason" ]] || printf 'reason=%s\n' "$reason"
    [[ -z "$actor" ]] || printf 'actor=%s\n' "$actor"
    printf 'created_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [[ -z "$deadline" ]] || printf 'deadline=%s\n' "$deadline"
  } > "$temporary"
  mv "$temporary" "$drain_file"
}

# _sgt_drain_clear <drain_file>
#
# Removes the drain file if it exists.  Idempotent.
_sgt_drain_clear() {
  rm -f "${1:?_sgt_drain_clear requires a drain file path}"
}

# _sgt_drain_global_active
#
# Returns 0 (true) when a global drain file is present, 1 otherwise.
_sgt_drain_global_active() {
  _sgt_drain_is_drained "$(_sgt_drain_global_file)"
}

# _sgt_drain_project_active <project>
#
# Returns 0 (true) when a per-project drain file is present for <project>,
# 1 otherwise.
_sgt_drain_project_active() {
  local project="${1:?_sgt_drain_project_active requires a project name}"
  [[ -n "$project" ]] && _sgt_drain_is_drained "$(_sgt_drain_project_file "$project")"
}

# _sgt_drain_remove_global
#
# Removes the global drain file under an advisory flock.  Safe to call when
# no drain is active (idempotent).
_sgt_drain_remove_global() {
  local drain_file
  drain_file="$(_sgt_drain_global_file)"
  _sgt_drain_with_lock "rm -f \"$drain_file\""
}

# _sgt_drain_remove_project <project>
#
# Removes the per-project drain file under an advisory flock.  The project
# name must already be validated by the caller.
_sgt_drain_remove_project() {
  local project="${1:?_sgt_drain_remove_project requires a project name}"
  local drain_file
  drain_file="$(_sgt_drain_project_file "$project")"
  _sgt_drain_with_lock "rm -f \"$drain_file\""
}
