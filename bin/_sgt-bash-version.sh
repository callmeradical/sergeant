#!/usr/bin/env bash
# Shared minimum-version check for Sergeant's Bash entry points.

_sgt_bash_version_supported() {
  local major="$1"
  local minor="$2"
  (( major > 3 || (major == 3 && minor >= 2) ))
}

_sgt_require_bash_version() {
  local major="$1"
  local minor="$2"
  if _sgt_bash_version_supported "$major" "$minor"; then
    return 0
  fi
  printf 'ERROR: Sergeant requires Bash 3.2 or newer; found %s.%s. Install or activate a supported Bash and ensure it appears first on PATH.\n' \
    "$major" "$minor" >&2
  return 1
}

_sgt_require_running_bash() {
  _sgt_require_bash_version "${BASH_VERSINFO[0]:-0}" "${BASH_VERSINFO[1]:-0}"
}
