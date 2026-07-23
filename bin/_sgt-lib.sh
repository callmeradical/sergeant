#!/usr/bin/env bash
# _sgt-lib.sh — Shared helpers sourced by all sgt-* scripts.
# Source this file; do not execute it directly.
#
# Provides: _die, _info, _require_*, _resolve_path, and the SGT_* env vars.

_SGT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/_sgt-bash-version.sh
source "$_SGT_LIB_DIR/_sgt-bash-version.sh"
_sgt_require_running_bash || return 1

[[ "${SGT_LIB_LOADED:-}" == "1" ]] && return 0
SGT_LIB_LOADED=1

# ── Configurable env vars ─────────────────────────────────────────────────────

SERGEANT_CONFIG="${SERGEANT_CONFIG:-$HOME/.config/sergeant}"
# shellcheck disable=SC2034  # Shared default consumed by sourced scripts.
FLEET_DIR="${SERGEANT_FLEET:-$HOME/.local/share/sergeant/fleet}"
# Auto-detect the running agent from environment signals, then allow override.
# Detection order:
#   1. SERGEANT_AGENT env var — explicit override always wins
#   2. OPENCODE / OPENCODE_PID — set by opencode when running a session
#   3. CLAUDE_CODE_SESSION_ID — set by Claude Code when running a session
#   4. Fallback: opencode
_sgt_detect_agent() {
  if [[ -n "${SERGEANT_AGENT:-}" ]]; then
    echo "$SERGEANT_AGENT"
  elif [[ -n "${OPENCODE:-}" || -n "${OPENCODE_PID:-}" ]]; then
    echo "opencode"
  elif [[ -n "${CLAUDE_CODE_SESSION_ID:-}" || -n "${CLAUDE_CODE_SESSION_NAME:-}" ]]; then
    echo "claude"
  else
    echo "opencode"
  fi
}

# shellcheck disable=SC2034  # Shared default consumed by sourced scripts.
AGENT_CMD="${SERGEANT_AGENT:-$(_sgt_detect_agent)}"

# ── Global config (dev_root) ──────────────────────────────────────────────────

DEV_ROOT="$HOME/Dev"  # sensible default

_sgt_load_global_config() {
  local cfg="$SERGEANT_CONFIG/config.yaml"
  if [[ -f "$cfg" ]] && command -v yq &>/dev/null; then
    local dr
    dr="$(yq '.dev_root // ""' "$cfg" 2>/dev/null | tr -d '\n')"
    if [[ -n "$dr" && "$dr" != "null" ]]; then
      DEV_ROOT="${dr/#\~/$HOME}"
    fi
  fi
}

_sgt_load_global_config

# ── Path resolution ───────────────────────────────────────────────────────────
# Absolute paths (/...) and home-relative paths (~...) pass through unchanged.
# Everything else is resolved relative to DEV_ROOT.
#
# Examples (DEV_ROOT=~/Dev):
#   ~/Dev/smith/ascend-arch-smith   → /Users/you/Dev/smith/ascend-arch-smith
#   smith/ascend-arch-smith         → /Users/you/Dev/smith/ascend-arch-smith
#   /opt/repos/myapp                → /opt/repos/myapp

_resolve_path() {
  local p="$1"
  if [[ "$p" == /* ]]; then
    echo "$p"
  elif [[ "$p" == ~* ]]; then
    echo "${p/#\~/$HOME}"
  else
    echo "$DEV_ROOT/$p"
  fi
}

_sgt_is_git_repo() {
  local path="$1"
  git -C "$path" rev-parse --git-dir >/dev/null 2>&1
}

# ── Common helpers ────────────────────────────────────────────────────────────

_die()  { echo "ERROR: $*" >&2; exit 1; }
_info() { echo "  $*"; }

# ── Agent command builder ─────────────────────────────────────────────────────
# _sgt_agent_run_cmd <agent> <message>
#
# Returns the shell command string to launch a non-interactive agent session
# with <message> as the first prompt, using the correct flags for each agent.
#
# Supported agents:
#   opencode   → opencode run --auto "<message>"
#   claude     → claude --dangerously-skip-permissions "<message>"
#   (default)  → <agent> run --auto "<message>"   (opencode-style fallback)

_sgt_agent_run_cmd() {
  local agent="$1"
  local message="$2"
  local bin
  bin="$(basename "$agent")"

  case "$bin" in
    claude)
      # claude: pass message as positional arg with dangerously-skip-permissions
      # to bypass all permission dialogs in autonomous mode.
      printf '%s --dangerously-skip-permissions %q' "$agent" "$message"
      ;;
    opencode|oc|*)
      # opencode (and unknown agents): use `run --auto` for non-interactive mode.
      printf '%s run --auto %q' "$agent" "$message"
      ;;
  esac
}

# ── Wiki integration ──────────────────────────────────────────────────────────
# _sgt_wiki_write <title> <type> <description> <tags> <body>
#
# Writes an OKF document to ~/wiki/.captures/ via the write.sh script.
# Never fatal — wiki failures are silently swallowed.
#
# Args:
#   $1  title        — document title (e.g. "Dispatched fix/add-oauth to smith")
#   $2  type         — OKF type (e.g. "activity", "session", "decision")
#   $3  description  — one-line summary
#   $4  tags         — comma-separated (e.g. "sergeant,smith,dispatch")
#   $5  body         — markdown body text

_SGT_WIKI_SCRIPT="${HOME}/.opencode/skills/write-to-wiki/scripts/write.sh"
_SGT_WIKI_ROOT="${WIKI_ROOT:-${HOME}/wiki/.captures}"

_sgt_wiki_write() {
  local title="$1" type="$2" description="$3" tags="$4" body="$5"
  [[ -x "$_SGT_WIKI_SCRIPT" ]] || return 0
  [[ "${SGT_WIKI_DISABLED:-0}" == "1" ]] && return 0
  bash "$_SGT_WIKI_SCRIPT" \
    --title "$title" \
    --type "$type" \
    --description "$description" \
    --tags "$tags" \
    --wiki-root "$_SGT_WIKI_ROOT" \
    "$body" 2>/dev/null || true
}

_require_yq() {
  command -v yq &>/dev/null || _die "yq is required: brew install yq"
}
_require_tmux() {
  command -v tmux &>/dev/null || _die "tmux is required: brew install tmux"
}
_require_git() {
  command -v git &>/dev/null || _die "git is required"
}
_sgt_td_normalize_version() {
  printf '%s\n' "${1#v}"
}
_sgt_td_supported_semver() {
  [[ "$1" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[[:alnum:]]+([.-][[:alnum:]]+)*)?$ ]]
}
_sgt_td_supported_version_output() {
  local td_version="$1"
  local line
  local -a lines=()
  local start end current_version update_current_version available_version install_version install_target

  while IFS= read -r line || [[ -n "$line" ]]; do
    lines+=("$line")
  done <<< "$td_version"

  start=0
  end=$((${#lines[@]} - 1))
  while (( start <= end )) && [[ "${lines[$start]}" =~ ^[[:blank:]]*$ ]]; do
    start=$((start + 1))
  done
  while (( end >= start )) && [[ "${lines[$end]}" =~ ^[[:blank:]]*$ ]]; do
    end=$((end - 1))
  done

  (( start <= end )) || return 1

  if (( start == end )); then
    [[ "${lines[$start]}" =~ ^[[:blank:]]*td[[:blank:]]+version[[:blank:]]+([^[:blank:]]+)[[:blank:]]*$ ]] || return 1
    _sgt_td_supported_semver "${BASH_REMATCH[1]}"
    return
  fi

  (( end - start == 3 )) || return 1
  [[ "${lines[$((start + 1))]}" =~ ^[[:blank:]]*$ ]] || return 1
  [[ "${lines[$start]}" =~ ^[[:blank:]]*td[[:blank:]]+version[[:blank:]]+([^[:blank:]]+)[[:blank:]]*$ ]] || return 1
  current_version="${BASH_REMATCH[1]}"
  _sgt_td_supported_semver "$current_version" || return 1
  [[ "${lines[$((start + 2))]}" =~ ^[[:blank:]]*Update[[:blank:]]+available:[[:blank:]]+([^[:blank:]]+)[[:blank:]]+→[[:blank:]]+([^[:blank:]]+)[[:blank:]]*$ ]] || return 1
  update_current_version="${BASH_REMATCH[1]}"
  available_version="${BASH_REMATCH[2]}"
  _sgt_td_supported_semver "$update_current_version" || return 1
  _sgt_td_supported_semver "$available_version" || return 1
  [[ "${lines[$((start + 3))]}" =~ ^[[:blank:]]*Run:[[:blank:]]+go[[:blank:]]+install[[:blank:]]+-ldflags[[:blank:]]+\"-X[[:blank:]]+main\.Version=([^[:blank:]\"]+)\"[[:blank:]]+github\.com/marcus/td@([^[:blank:]]+)[[:blank:]]*$ ]] || return 1
  install_version="${BASH_REMATCH[1]}"
  install_target="${BASH_REMATCH[2]}"
  _sgt_td_supported_semver "$install_version" || return 1
  _sgt_td_supported_semver "$install_target" || return 1

  [[ "$(_sgt_td_normalize_version "$current_version")" == "$(_sgt_td_normalize_version "$update_current_version")" ]] || return 1
  [[ "$(_sgt_td_normalize_version "$available_version")" == "$(_sgt_td_normalize_version "$install_version")" ]] || return 1
  [[ "$(_sgt_td_normalize_version "$available_version")" == "$(_sgt_td_normalize_version "$install_target")" ]]
}
_require_marcus_td() {
  local install_hint="Install it with 'brew install marcus/tap/td' or 'go install github.com/marcus/td@latest'."
  if ! command -v td &>/dev/null; then
    _die "td is missing. Required implementation: github.com/marcus/td. $install_hint"
  fi

  local td_path td_version create_help
  td_path="$(command -v td)"
  td_version="$(td --version 2>&1 || true)"
  [[ -n "$td_version" ]] || td_version="version unknown"
  create_help="$(td create --help 2>&1 || true)"

  if ! _sgt_td_supported_version_output "$td_version" || \
     [[ "$create_help" != *"--description"* || "$create_help" != *"--json"* || "$create_help" != *"--work-dir"* ]]; then
    _die "Unsupported td detected at $td_path: $td_version. Required implementation: github.com/marcus/td with create/json/work-dir support. $install_hint"
  fi
}
_require_treehouse() {
  command -v treehouse &>/dev/null || _die "treehouse is required: install from https://github.com/kunchenguid/treehouse"
}
