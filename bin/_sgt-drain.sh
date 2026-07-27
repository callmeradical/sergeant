#!/usr/bin/env bash
# _sgt-drain.sh — Drain state helpers sourced by sgt-* scripts.
# Source this file; do not execute it directly.
#
# Provides the legacy config-based drain seam and the durable admission API.
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
  if [[ -n "${SERGEANT_DRAIN_DIR:-}" ]]; then
    printf '%s\n' "$SERGEANT_DRAIN_DIR"
  else
    printf '%s\n' "${SERGEANT_CONFIG:-$HOME/.config/sergeant}/drain"
  fi
}

_sgt_drain_dir() {
  _sgt_drain_state_dir
}

_sgt_drain_lock_file() {
  printf '%s/admission.lock\n' "$(_sgt_drain_state_dir)"
}

_sgt_drain_global_file() {
  if [[ -n "${SERGEANT_DRAIN_DIR:-}" ]]; then
    printf '%s/global/drain\n' "$(_sgt_drain_state_dir)"
  else
    printf '%s/global\n' "$(_sgt_drain_state_dir)"
  fi
}

_sgt_drain_project_file() {
  local project="$1"
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

_sgt_drain_write() {
  local file="$1" reason="$2" actor="$3" deadline="${4:-}"
  local dir temporary
  dir="$(dirname "$file")"
  mkdir -p "$dir"
  temporary="$(mktemp "${file}.tmp.XXXXXX")"
  {
    printf 'reason=%s\n' "$reason"
    printf 'actor=%s\n' "$actor"
    printf 'created_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [[ -z "$deadline" ]] || printf 'deadline=%s\n' "$deadline"
  } > "$temporary"
  mv "$temporary" "$file"
}

_sgt_drain_read_field() {
  local file="$1" field="$2"
  grep -m1 "^${field}=" "$file" 2>/dev/null | cut -d= -f2- || true
}

_sgt_drain_is_drained() {
  [[ -f "$1" ]]
}

_sgt_drain_clear() {
  rm -f "$1"
}

_sgt_drain_with_lock() {
  local body="$1" lock_file
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

_sgt_drain_lock_acquire_fd() {
  local fd="$1" lock_file
  lock_file="$(_sgt_drain_lock_file)"
  mkdir -p "$(dirname "$lock_file")"
  eval "exec ${fd}>\"\$lock_file\""
  flock -w "${SERGEANT_DRAIN_LOCK_TIMEOUT_SECS:-10}" "$fd"
}

_sgt_drain_lock_release_fd() {
  eval "exec $1>&-" 2>/dev/null || true
}

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

_sgt_drain_global_active() {
  _sgt_drain_is_drained "$(_sgt_drain_global_file)"
}

_sgt_drain_project_active() {
  local project="$1"
  [[ -n "$project" ]] && _sgt_drain_is_drained "$(_sgt_drain_project_file "$project")"
}
