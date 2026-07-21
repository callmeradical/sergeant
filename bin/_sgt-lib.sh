#!/usr/bin/env bash
# _sgt-lib.sh — Shared helpers sourced by all sgt-* scripts.
# Source this file; do not execute it directly.
#
# Provides: _die, _info, _require_*, _resolve_path, and the SGT_* env vars.

[[ "${SGT_LIB_LOADED:-}" == "1" ]] && return 0
SGT_LIB_LOADED=1

# ── Configurable env vars ─────────────────────────────────────────────────────

SERGEANT_CONFIG="${SERGEANT_CONFIG:-$HOME/.config/sergeant}"
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
_require_treehouse() {
  command -v treehouse &>/dev/null || _die "treehouse is required: install from https://github.com/kunchenguid/treehouse"
}
