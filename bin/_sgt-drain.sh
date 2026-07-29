#!/usr/bin/env bash
# _sgt-drain.sh — Drain state helpers sourced by sgt-* scripts.
# Source this file; do not execute it directly.
#
# Provides: _sgt_is_drained, _sgt_drain_state_dir,
#           _sgt_drain_global_file, _sgt_drain_project_file,
#           _sgt_drain_is_drained (file-path variant),
#           _sgt_drain_write, _sgt_drain_global_active,
#           _sgt_drain_project_active,
#           _sgt_drain_clear,
#           _sgt_drain_lock_acquire_fd, _sgt_drain_lock_release_fd,
#           _sgt_drain_check_admission_locked,
#           _sgt_drain_write, _sgt_drain_global_active,
#           _sgt_drain_project_active
#
# Drain state location: $SERGEANT_CONFIG/drain/
#   Global drain:  $SERGEANT_CONFIG/drain/global
#   Project drain: $SERGEANT_CONFIG/drain/<project>
#
# Drain file format (plain text, key=value lines):
#   reason=<text>     optional
#   actor=<text>      optional
#   created=<ISO-8601 timestamp>  always present

[[ "${SGT_DRAIN_LIB_LOADED:-}" == "1" ]] && return 0
SGT_DRAIN_LIB_LOADED=1

_sgt_drain_state_dir() {
  if [[ -n "${SERGEANT_DRAIN_DIR:-}" ]]; then
    printf '%s\n' "$SERGEANT_DRAIN_DIR"
  else
    printf '%s\n' "${SERGEANT_CONFIG:-$HOME/.config/sergeant}/drain"
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
  local project="${1:-}" drain_dir
  drain_dir="$(_sgt_drain_state_dir)"
  [[ -f "$drain_dir/global" ]] && return 0
  if [[ -n "$project" && "$project" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    [[ -f "$drain_dir/$project" ]] && return 0
  fi
  return 1
}

# ── Drain admission lock helpers ──────────────────────────────────────────────
#
# These three functions implement the advisory drain-admission lock used by
# sgt-respond (and other relaunchers) to serialize the "read drain state →
# start new pane" window so a concurrent sgt-drain cannot slip in between.
#
# The lock is a flock(2) held on the drain-state directory itself.  sgt-drain
# does not need to acquire the lock because it only appends/removes files; the
# concern is purely the read-then-relaunch race in sgt-respond.
#
# Usage pattern (mirroring sgt-respond):
#   exec <N>>/dev/null            # open the fd; real users point it at the dir
#   _sgt_drain_lock_acquire_fd N  # flock; returns 0 on success
#   _sgt_drain_check_admission_locked [project]   # 0 = admit, 1 = draining
#   ... spawn new pane ...
#   _sgt_drain_lock_release_fd N  # release by closing the fd

# _sgt_drain_lock_acquire_fd <fd>
#
# Acquires an exclusive advisory lock on the drain state directory, attaching
# it to file descriptor <fd>.  The caller must have opened <fd> before calling
# (e.g. exec N>/path/to/lockfile).  Returns 0 on success.
#
# Falls back gracefully if flock(1) is unavailable (non-Linux or minimal
# installs): the function still returns 0 so that sgt-respond is not blocked
# merely because flock is absent — the drain-state file check in
# _sgt_drain_check_admission_locked remains the authoritative gate.
_sgt_drain_lock_acquire_fd() {
  local fd="${1:?_sgt_drain_lock_acquire_fd requires an fd}"
  local drain_dir
  drain_dir="$(_sgt_drain_state_dir)"
  mkdir -p "$drain_dir" 2>/dev/null || true
  if command -v flock >/dev/null 2>&1; then
    # Re-open the fd pointed at the drain dir so flock targets the right inode.
    # shellcheck disable=SC1083
    eval "exec ${fd}>>\"${drain_dir}\"" 2>/dev/null || true
    flock --exclusive "$fd" 2>/dev/null || true
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
#
# Equivalent to _sgt_is_drained but intended for use inside the lock window.
_sgt_drain_check_admission_locked() {
  local project="${1:-}"
  _sgt_is_drained "$project" && return 1
  return 0
}

# ── File-path helpers used by sgt-undrain and sgt-interactive-worker ──────────

# _sgt_drain_global_file
#
# Prints the path to the global drain file.
_sgt_drain_global_file() {
  printf '%s/global\n' "$(_sgt_drain_state_dir)"
}

# _sgt_drain_project_file <project>
#
# Prints the path to the per-project drain file.
_sgt_drain_project_file() {
  printf '%s/%s\n' "$(_sgt_drain_state_dir)" "${1:?_sgt_drain_project_file requires a project name}"
}

# _sgt_drain_is_drained <drain_file>
#
# File-path variant: returns 0 if the given drain file exists, 1 otherwise.
# Used by sgt-interactive-worker which already resolved the file path.
_sgt_drain_is_drained() {
  [[ -f "${1:?_sgt_drain_is_drained requires a drain file path}" ]]
}

# _sgt_drain_write <drain_file> <reason> <actor>
#
# Creates a drain file atomically using a tmp+mv pattern.  The caller must
# have already resolved the drain file path (e.g. via _sgt_drain_global_file
# or _sgt_drain_project_file).  reason and actor are optional free-text fields
# recorded in the drain file for human inspection; drain activation is based
# solely on file existence.
_sgt_drain_write() {
  local drain_file="${1:?_sgt_drain_write requires a drain file path}"
  local reason="${2:-}"
  local actor="${3:-}"
  local tmp
  mkdir -p "$(dirname "$drain_file")" 2>/dev/null || true
  tmp="${drain_file}.tmp.$$"
  {
    [[ -n "$reason" ]] && printf 'reason=%s\n' "$reason"
    [[ -n "$actor" ]] && printf 'actor=%s\n' "$actor"
    printf 'created=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$tmp"
  mv "$tmp" "$drain_file"
}

# _sgt_drain_global_active
#
# Returns 0 (true) when a global drain file is present, 1 otherwise.
# Convenience wrapper around _sgt_drain_state_dir for callers that do not
# need the explicit file-path variants.
_sgt_drain_global_active() {
  [[ -f "$(_sgt_drain_state_dir)/global" ]]
}

# _sgt_drain_project_active <project>
#
# Returns 0 (true) when a per-project drain file is present for <project>,
# 1 otherwise.  The project name must already be validated by the caller
# (match [A-Za-z0-9][A-Za-z0-9._-]*).
_sgt_drain_project_active() {
  local project="${1:?_sgt_drain_project_active requires a project name}"
  [[ "$project" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  [[ -f "$(_sgt_drain_state_dir)/$project" ]]
}

# _sgt_drain_clear <drain_file>
#
# Removes the drain file if it exists.  Idempotent.
_sgt_drain_clear() {
  rm -f "${1:?_sgt_drain_clear requires a drain file path}"
}

# _sgt_drain_remove_global
#
# Removes the global drain file under an advisory flock.  Safe to call when
# no drain is active (idempotent).
_sgt_drain_remove_global() {
  local drain_dir lockfile
  drain_dir="$(_sgt_drain_state_dir)"
  mkdir -p "$drain_dir" 2>/dev/null || true
  lockfile="${drain_dir}/.lock"
  if command -v flock >/dev/null 2>&1; then
    (
      exec 9>>"$lockfile"
      flock --exclusive 9 2>/dev/null || true
      rm -f "${drain_dir}/global"
    )
  else
    rm -f "${drain_dir}/global"
  fi
}

# _sgt_drain_remove_project <project>
#
# Removes the per-project drain file under an advisory flock.  The project
# name must already be validated by the caller.
# _sgt_drain_write <drain_file> [reason] [actor]
#
# Writes a drain signal file at the given path.  Creates parent directories as
# needed.  The file format matches that produced by sgt-drain.
_sgt_drain_write() {
  local drain_file="${1:?_sgt_drain_write requires a drain file path}"
  local reason="${2:-}"
  local actor="${3:-}"
  local temporary drain_dir
  drain_dir="$(dirname "$drain_file")"
  mkdir -p "$drain_dir" 2>/dev/null || true
  temporary="${drain_file}.tmp.$$"
  {
    [[ -z "$reason" ]] || printf 'reason=%s\n' "$reason"
    [[ -z "$actor" ]] || printf 'actor=%s\n' "$actor"
    printf 'created=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$temporary"
  mv "$temporary" "$drain_file"
}

# _sgt_drain_global_active
#
# Returns 0 (true) if a global drain is currently active.
_sgt_drain_global_active() {
  [[ -f "$(_sgt_drain_global_file)" ]]
}

# _sgt_drain_project_active <project>
#
# Returns 0 (true) if a project-specific drain is currently active.
_sgt_drain_project_active() {
  local project="${1:?_sgt_drain_project_active requires a project name}"
  [[ -f "$(_sgt_drain_project_file "$project")" ]]
}

_sgt_drain_remove_project() {
  local project="${1:?_sgt_drain_remove_project requires a project name}"
  local drain_dir lockfile
  drain_dir="$(_sgt_drain_state_dir)"
  mkdir -p "$drain_dir" 2>/dev/null || true
  lockfile="${drain_dir}/.lock"
  if command -v flock >/dev/null 2>&1; then
    (
      exec 9>>"$lockfile"
      flock --exclusive 9 2>/dev/null || true
      rm -f "${drain_dir}/${project}"
    )
  else
    rm -f "${drain_dir}/${project}"
  fi
}
