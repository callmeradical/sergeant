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
#           _sgt_drain_lock_file, _sgt_drain_lock_dir,
#           _sgt_drain_host_id, _sgt_drain_lock_acquire_fd,
#           _sgt_drain_lock_release_fd,
#           _sgt_drain_check_admission_locked,
#           _sgt_drain_run_locked, _sgt_drain_with_lock,
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
# These functions implement the drain-admission lock used by sgt-respond and
# sgt-dispatch to serialize the "read drain state → start new pane" window so a
# concurrent sgt-drain cannot slip in between, and by sgt-drain itself to
# read-then-write drain state atomically.
#
# Outcome contract — shared by _sgt_drain_lock_acquire_fd, _sgt_drain_run_locked
# and _sgt_drain_with_lock.  Callers can tell all three cases apart:
#
#   0  acquired     the lock is held        SGT_DRAIN_LOCK_STATE=acquired
#   2  timeout      another owner holds it  SGT_DRAIN_LOCK_STATE=timeout
#   3  unavailable  no usable lock location SGT_DRAIN_LOCK_STATE=unavailable
#
# A nonzero return ALWAYS means the lock is not held.  No path returns success
# without exclusion, so a caller can never proceed silently unlocked.
#
# Exclusion is an atomically created lock DIRECTORY, not flock(1).  flock is
# absent from macOS system installs and limited on BusyBox, and guarding it with
# `command -v flock` previously meant the whole lock silently degraded to a
# no-op.  mkdir(2) is atomic everywhere Sergeant runs, needs no extra
# prerequisite, and mirrors the reclaimable lock already used by sgt-wake.
#
# Usage pattern (mirroring sgt-respond):
#   _sgt_drain_lock_acquire_fd N [purpose]        # 0 = held; 2/3 = not held
#   _sgt_drain_check_admission_locked [project]   # 0 = admit, 1 = draining
#   ... spawn new pane ...
#   _sgt_drain_lock_release_fd N                  # release

# _sgt_drain_lock_dir
#
# Prints the path of the lock directory that provides the actual exclusion.
_sgt_drain_lock_dir() {
  printf '%s.d\n' "$(_sgt_drain_lock_file)"
}

# _sgt_drain_host_id
#
# Prints a stable host identifier.  Owner liveness can only be verified on the
# host that recorded the lock, so the host is part of the lock record.
_sgt_drain_host_id() {
  local host
  host="$(uname -n 2>/dev/null || true)"
  [[ -n "$host" ]] || host="unknown-host"
  printf '%s\n' "$host"
}

# _sgt_drain_process_start <pid>
#
# Prints the process start time, used to detect PID reuse.
_sgt_drain_process_start() {
  ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//;s/ *$//'
}

# _sgt_drain_lock_write_owner <lock_dir> <purpose>
#
# Records proven owner state INSIDE the held lock, so a later contender can
# decide whether the lock is live or safely reclaimable.  Written only after
# the lock directory was created, so the contents always describe the holder.
_sgt_drain_lock_write_owner() {
  local lock_dir="$1" purpose="$2" temporary
  temporary="$lock_dir/owner.tmp.$$"
  {
    printf 'owner_pid=%s\n'      "$$"
    printf 'owner_start=%s\n'    "$(_sgt_drain_process_start "$$")"
    printf 'owner_host=%s\n'     "$(_sgt_drain_host_id)"
    printf 'owner_user=%s\n'     "${USER:-$(id -un 2>/dev/null || printf 'unknown')}"
    printf 'owner_purpose=%s\n'  "$purpose"
    printf 'created_at=%s\n'     "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'created_epoch=%s\n'  "$(date +%s)"
  } > "$temporary" 2>/dev/null || return 1
  mv "$temporary" "$lock_dir/owner" 2>/dev/null || return 1
  return 0
}

# _sgt_drain_lock_owner_is_gone <lock_dir>
#
# Returns 0 only when the recorded owner is PROVABLY gone: same host, and the
# pid is either absent or has been reused by a different process.  Anything
# unverifiable — a foreign host, a missing or malformed record — returns 1 so
# a live lock is never stolen.
_sgt_drain_lock_owner_is_gone() {
  local lock_dir="$1" owner_file="$1/owner"
  local pid host recorded_start actual_start
  [[ -f "$owner_file" ]] || return 1
  host="$(_sgt_drain_read_field "$owner_file" owner_host)"
  [[ "$host" == "$(_sgt_drain_host_id)" ]] || return 1
  pid="$(_sgt_drain_read_field "$owner_file" owner_pid)"
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  # kill -0 also fails with EPERM for a live process owned by another user, so
  # confirm absence with ps before declaring the owner gone.
  if ! kill -0 "$pid" 2>/dev/null && ! ps -p "$pid" >/dev/null 2>&1; then
    return 0
  fi
  recorded_start="$(_sgt_drain_read_field "$owner_file" owner_start)"
  if [[ -n "$recorded_start" ]]; then
    actual_start="$(_sgt_drain_process_start "$pid")"
    [[ "$actual_start" == "$recorded_start" ]] || return 0
  fi
  return 1
}

# _sgt_drain_lock_reclaim <lock_dir>
#
# Reclaims a lock proven stale.  The directory is renamed first: rename is
# atomic, so exactly one contender wins the reclamation and the loser keeps
# waiting instead of deleting the winner's fresh lock.
_sgt_drain_lock_reclaim() {
  local lock_dir="$1" quarantine
  quarantine="${lock_dir}.stale.$$"
  rm -rf "$quarantine" 2>/dev/null || true
  mv "$lock_dir" "$quarantine" 2>/dev/null || return 1
  rm -rf "$quarantine" 2>/dev/null || true
  return 0
}

# _sgt_drain_lock_report_timeout <lock_dir>
#
# Reports who holds the lock, for how long, and why, plus the exact recovery
# command — an undiagnosable "could not acquire lock" is not actionable.
_sgt_drain_lock_report_timeout() {
  local lock_dir="$1" owner_file="$1/owner"
  local pid user host purpose created epoch age
  local waited="${SERGEANT_DRAIN_LOCK_TIMEOUT_SECS:-10}"
  if [[ -f "$owner_file" ]]; then
    pid="$(_sgt_drain_read_field "$owner_file" owner_pid)"
    user="$(_sgt_drain_read_field "$owner_file" owner_user)"
    host="$(_sgt_drain_read_field "$owner_file" owner_host)"
    purpose="$(_sgt_drain_read_field "$owner_file" owner_purpose)"
    created="$(_sgt_drain_read_field "$owner_file" created_at)"
    epoch="$(_sgt_drain_read_field "$owner_file" created_epoch)"
    age="unknown"
    case "$epoch" in
      ''|*[!0-9]*) : ;;
      *) age="$(( $(date +%s) - epoch ))s" ;;
    esac
    printf 'ERROR: could not acquire drain admission lock after %ss: held by owner_pid=%s user=%s host=%s purpose=%s since=%s age=%s\n' \
      "$waited" "$pid" "$user" "$host" "$purpose" "$created" "$age" >&2
    printf 'ERROR: retry when that process finishes, or if it is gone remove the stale lock: rm -rf %s\n' \
      "$lock_dir" >&2
  else
    printf 'ERROR: could not acquire drain admission lock after %ss: %s exists with no owner record (purpose unknown)\n' \
      "$waited" "$lock_dir" >&2
    printf 'ERROR: if no drain, dispatch, or respond command is running, remove it: rm -rf %s\n' \
      "$lock_dir" >&2
  fi
}

# _sgt_drain_lock_acquire_fd <fd> [purpose]
#
# Acquires the drain admission lock and attaches <fd> to the lock file so the
# documented release-by-fd pattern keeps working.  See the outcome contract
# above: 0 = acquired, 2 = timeout, 3 = unavailable.
_sgt_drain_lock_acquire_fd() {
  local fd="${1:?_sgt_drain_lock_acquire_fd requires an fd}"
  local purpose="${2:-}"
  local lock_file lock_dir state_dir deadline

  SGT_DRAIN_LOCK_STATE="unavailable"
  case "$fd" in
    ''|*[!0-9]*)
      printf 'ERROR: invalid drain admission lock fd: %s\n' "$fd" >&2
      return 3
      ;;
  esac
  [[ -n "$purpose" ]] || purpose="${0##*/}"
  purpose="$(printf '%s' "$purpose" | tr -d '\n\r')"

  lock_file="$(_sgt_drain_lock_file)"
  lock_dir="$(_sgt_drain_lock_dir)"
  state_dir="$(dirname "$lock_file")"
  if ! mkdir -p "$state_dir" 2>/dev/null || [[ ! -w "$state_dir" ]]; then
    printf 'ERROR: drain admission lock unavailable: %s is not writable\n' "$state_dir" >&2
    return 3
  fi

  deadline=$(( $(date +%s) + ${SERGEANT_DRAIN_LOCK_TIMEOUT_SECS:-10} ))
  while :; do
    if mkdir "$lock_dir" 2>/dev/null; then
      if ! _sgt_drain_lock_write_owner "$lock_dir" "$purpose"; then
        rm -rf "$lock_dir" 2>/dev/null || true
        printf 'ERROR: drain admission lock unavailable: cannot record owner in %s\n' \
          "$lock_dir" >&2
        return 3
      fi
      # shellcheck disable=SC1083
      eval "exec ${fd}>\"\$lock_file\"" 2>/dev/null || true
      eval "_SGT_DRAIN_LOCK_HELD_${fd}=1"
      SGT_DRAIN_LOCK_STATE="acquired"
      return 0
    fi
    if _sgt_drain_lock_owner_is_gone "$lock_dir" && _sgt_drain_lock_reclaim "$lock_dir"; then
      continue
    fi
    if [[ $(date +%s) -ge $deadline ]]; then
      # shellcheck disable=SC2034  # Read by callers as part of the outcome contract.
      SGT_DRAIN_LOCK_STATE="timeout"
      _sgt_drain_lock_report_timeout "$lock_dir"
      return 2
    fi
    sleep 0.1 2>/dev/null || sleep 1
  done
}

# _sgt_drain_lock_release_fd <fd>
#
# Releases the lock and closes <fd>.  Removes the lock directory only when this
# process actually acquired it through <fd>, so a failed acquisition can never
# release someone else's lock.  Idempotent.
_sgt_drain_lock_release_fd() {
  local fd="${1:?_sgt_drain_lock_release_fd requires an fd}"
  local held lock_dir
  case "$fd" in
    ''|*[!0-9]*) return 0 ;;
  esac
  eval "held=\${_SGT_DRAIN_LOCK_HELD_${fd}:-}"
  # shellcheck disable=SC1083
  eval "exec ${fd}>&-" 2>/dev/null || true
  if [[ "$held" == "1" ]]; then
    lock_dir="$(_sgt_drain_lock_dir)"
    rm -rf "$lock_dir" 2>/dev/null || true
    eval "unset _SGT_DRAIN_LOCK_HELD_${fd}"
  fi
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

# Internal fd used by the command-running lock wrappers below.
_SGT_DRAIN_LOCK_INTERNAL_FD=200

# _sgt_drain_run_locked <command> [args...]
#
# Runs a command with its arguments while holding the admission lock, then
# releases it and returns the command's exit status.  Prefer this over
# _sgt_drain_with_lock: arguments are passed as argv, so caller-supplied text
# (a drain reason, a path) is never re-parsed by the shell.
#
# Returns the lock outcome (2 timeout, 3 unavailable) when the lock could not be
# acquired, and does NOT run the command in that case.
_sgt_drain_run_locked() {
  local rc=0 acquired=0
  [[ $# -ge 1 ]] || return 0
  _sgt_drain_lock_acquire_fd "$_SGT_DRAIN_LOCK_INTERNAL_FD" "${0##*/}" || acquired=$?
  [[ $acquired -eq 0 ]] || return $acquired
  "$@" || rc=$?
  _sgt_drain_lock_release_fd "$_SGT_DRAIN_LOCK_INTERNAL_FD"
  return $rc
}

# _sgt_drain_with_lock <body>
#
# Runs <body> (a shell string) while holding the admission lock, sharing the
# outcome contract above.  Retained for callers that must evaluate a shell
# string; never pass untrusted or caller-supplied text through it — use
# _sgt_drain_run_locked instead.
_sgt_drain_with_lock() {
  local body="${1:?_sgt_drain_with_lock requires a body}"
  _sgt_drain_run_locked eval "$body"
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
  _sgt_drain_run_locked rm -f "$drain_file"
}

# _sgt_drain_remove_project <project>
#
# Removes the per-project drain file under an advisory flock.  The project
# name must already be validated by the caller.
_sgt_drain_remove_project() {
  local project="${1:?_sgt_drain_remove_project requires a project name}"
  local drain_file
  drain_file="$(_sgt_drain_project_file "$project")"
  _sgt_drain_run_locked rm -f "$drain_file"
}
