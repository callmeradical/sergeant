#!/usr/bin/env bash
# _sgt-drain.sh — Drain state helpers sourced by sgt-* scripts.
# Source this file; do not execute it directly.
#
# Provides: _sgt_is_drained, _sgt_drain_state_dir,
#           _sgt_drain_global_file, _sgt_drain_project_file,
#           _sgt_drain_is_drained (file-path variant),
#           _sgt_drain_clear, _sgt_drain_with_lock,
#           _sgt_drain_lock_acquire_fd, _sgt_drain_lock_release_fd,
#           _sgt_drain_check_admission_locked
#
# Drain state location: $SERGEANT_CONFIG/drain/
#   Global drain:  $SERGEANT_CONFIG/drain/global
#   Project drain: $SERGEANT_CONFIG/drain/<project>
#
# Drain file format (plain text, two lines):
#   reason=<text>
#   created=<ISO-8601 timestamp>

[[ "${SGT_DRAIN_LIB_LOADED:-}" == "1" ]] && return 0
SGT_DRAIN_LIB_LOADED=1

_sgt_drain_state_dir() {
  printf '%s\n' "${SERGEANT_CONFIG:-$HOME/.config/sergeant}/drain"
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

# _sgt_drain_clear <drain_file>
#
# Removes the drain file if it exists.  Idempotent.
_sgt_drain_clear() {
  rm -f "${1:?_sgt_drain_clear requires a drain file path}"
}

# _sgt_drain_with_lock <shell_command_string>
#
# Runs <shell_command_string> (eval'd) while holding an exclusive flock on the
# drain state directory.  Used by sgt-undrain so that drain removal is
# serialised against concurrent sgt-respond relaunch windows.
_sgt_drain_with_lock() {
  local cmd="${1:?_sgt_drain_with_lock requires a command}"
  local drain_dir lockfile
  drain_dir="$(_sgt_drain_state_dir)"
  mkdir -p "$drain_dir" 2>/dev/null || true
  lockfile="${drain_dir}/.lock"
  if command -v flock >/dev/null 2>&1; then
    (
      exec 9>>"$lockfile"
      flock --exclusive 9 2>/dev/null || true
      eval "$cmd"
    )
  else
    eval "$cmd"
  fi
}
