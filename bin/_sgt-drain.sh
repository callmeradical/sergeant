#!/usr/bin/env bash
# _sgt-drain.sh — Drain state helpers sourced by sgt-* scripts.
# Source this file; do not execute it directly.
#
# Provides: _sgt_is_drained, _sgt_drain_state_dir
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
