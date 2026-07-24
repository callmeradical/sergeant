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
# Interactive worker dispatch supports persistent OpenCode, Goose, and Claude sessions.
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
_require_interactive_agent() {
  local agent_name
  agent_name="$(basename "$AGENT_CMD")"
  case "$agent_name" in
    opencode|oc|goose|claude) ;;
    *) _die "unsupported interactive agent: $AGENT_CMD (expected opencode, goose, or claude)" ;;
  esac
  command -v "$AGENT_CMD" &>/dev/null || _die "interactive agent not found: $AGENT_CMD"
  if [[ "$agent_name" == "goose" ]] && ! "$AGENT_CMD" session --help >/dev/null 2>&1; then
    _die "Goose does not support interactive sessions: expected 'goose session --help' to succeed"
  fi
}
_sgt_pane_identity() {
  local pane="$1"
  tmux display-message -p -t "$pane" \
    '#{pane_dead}|#{pane_id}|#{pane_pid}|#{pane_created}|#{pane_start_command}' 2>/dev/null
}
_sgt_read_owned_file() {
  local path="$1" before after mode value
  [[ -f "$path" && ! -L "$path" && -O "$path" ]] || return 1
  mode="$(stat -c '%a' -- "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null)" || \
    return 1
  [[ "$mode" =~ ^[0-7]+$ && "$mode" != *[2367][0-7] && "$mode" != *[0-7][2367] ]] || \
    return 1
  before="$(stat -c '%d:%i:%w:%s' -- "$path" 2>/dev/null || \
    stat -f '%d:%i:%B:%z' "$path" 2>/dev/null)" || return 1
  value="$(cat "$path")" || return 1
  after="$(stat -c '%d:%i:%w:%s' -- "$path" 2>/dev/null || \
    stat -f '%d:%i:%B:%z' "$path" 2>/dev/null)" || return 1
  [[ "$before" == "$after" ]] || return 1
  printf '%s\n' "$value"
}
_sgt_pane_identity_matches() {
  local pane="$1" repo_dir="$2" identity_name="${3:-pane_identity}" expected actual
  expected="$(_sgt_read_owned_file "$repo_dir/$identity_name" 2>/dev/null || true)"
  [[ -n "$expected" ]] || return 1
  actual="$(_sgt_pane_identity "$pane")" || return 1
  [[ "$actual" == "$expected" && "${actual%%|*}" == "0" ]]
}
_sgt_worker_command() {
  printf '%q %q %q %q' "$1" "$2" "$3" "$4"
}
_sgt_notification_target_create() {
  local repo_dir="$1" notification_id="$2" pane_identity="$3"
  local nonce target_dir temporary
  nonce="$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  target_dir="$repo_dir/notifications/$notification_id/targets/$nonce"
  mkdir -p "$target_dir" || return 1
  printf '%s\n' "$pane_identity" > "$target_dir/pane_identity" || return 1
  temporary="$repo_dir/notification_target.tmp.$$"
  printf '%s\n' "$nonce" > "$temporary" || return 1
  mv "$temporary" "$repo_dir/notification_target" || return 1
  printf '%s\n' "$pane_identity" > "$repo_dir/notification_target_pane_identity" || return 1
  printf '%s\n' "$nonce"
}
_sgt_publish_worker_notification() {
  local repo_dir="$1" worktree="$2" notification_id="$3" kind="$4" instruction="$5"
  local state_dir notification_state notification_tmp current_id current_ack current_delivered
  local proof_dir proof_tmp repo_tmp active_id current_ack_token current_delivered_identity current_target_identity

  [[ "$notification_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  state_dir="$repo_dir/notifications/$notification_id"
  notification_state="$state_dir/notification"
  mkdir -p "$state_dir" || return 1
  notification_tmp="$state_dir/notification.tmp.$$"
  {
    printf 'notification_id=%s\n' "$notification_id"
    printf 'kind=%s\n' "$kind"
    printf 'instruction=%s\n' "$instruction"
  } > "$notification_tmp"
  if [[ -f "$notification_state" ]] && cmp -s "$notification_tmp" "$notification_state"; then
    rm -f "$notification_tmp"
  else
    mv "$notification_tmp" "$notification_state" || {
      rm -f "$notification_tmp"
      return 1
    }
  fi

  current_id="$(cat "$repo_dir/notification_id" 2>/dev/null || true)"
  current_ack="$(cat "$worktree/.sergeant-notification-ack" 2>/dev/null || true)"
  current_delivered="$(cat "$repo_dir/notification_delivered" 2>/dev/null || true)"
  current_delivered_identity="$(cat "$repo_dir/notification_delivered_pane_identity" 2>/dev/null || true)"
  current_target_identity="$(cat "$repo_dir/notification_target_pane_identity" 2>/dev/null || true)"
  current_ack_token="$current_id|$current_target_identity"
  if [[ -n "$current_id" ]]; then
    proof_dir="$repo_dir/notifications/$current_id"
    mkdir -p "$proof_dir" || return 1
    if [[ "$current_ack" == "$current_ack_token" && ! -f "$proof_dir/acknowledged" ]]; then
      proof_tmp="$proof_dir/acknowledged.tmp.$$"
      printf '%s\n' "$current_ack_token" > "$proof_tmp"
      mv "$proof_tmp" "$proof_dir/acknowledged" || {
        rm -f "$proof_tmp"
        return 1
      }
    fi
    if [[ "$current_delivered" == "$current_id" && ! -f "$proof_dir/delivered" ]]; then
      proof_tmp="$proof_dir/delivered.tmp.$$"
      printf '%s\n' "$current_id" > "$proof_tmp"
      mv "$proof_tmp" "$proof_dir/delivered" || {
        rm -f "$proof_tmp"
        return 1
      }
    fi
    if [[ "$current_delivered" == "$current_id" && -n "$current_delivered_identity" &&
          ! -f "$proof_dir/delivered_pane_identity" ]]; then
      proof_tmp="$proof_dir/delivered_pane_identity.tmp.$$"
      printf '%s\n' "$current_delivered_identity" > "$proof_tmp"
      mv "$proof_tmp" "$proof_dir/delivered_pane_identity" || {
        rm -f "$proof_tmp"
        return 1
      }
    fi
    if [[ "$current_delivered" == "$current_id" && -n "$current_target_identity" &&
          ! -f "$proof_dir/target_pane_identity" ]]; then
      proof_tmp="$proof_dir/target_pane_identity.tmp.$$"
      printf '%s\n' "$current_target_identity" > "$proof_tmp"
      mv "$proof_tmp" "$proof_dir/target_pane_identity" || {
        rm -f "$proof_tmp"
        return 1
      }
    fi
  fi

  if [[ "$current_id" != "$notification_id" ]]; then
    repo_tmp="$repo_dir/notification_id.tmp.$$"
    printf '%s\n' "$notification_id" > "$repo_tmp"
    mv "$repo_tmp" "$repo_dir/notification_id" || {
      rm -f "$repo_tmp"
      return 1
    }
  fi
  if [[ "$current_id" != "$notification_id" ]]; then
    rm -f "$worktree/.sergeant-notification-accept"
  fi
  active_id="$(sed -n 's/^notification_id=//p' "$worktree/.sergeant-notification" 2>/dev/null || true)"
  if [[ "$active_id" != "$notification_id" ]]; then
    notification_tmp="$worktree/.sergeant-notification.tmp.$$"
    cp "$notification_state" "$notification_tmp" || return 1
    mv "$notification_tmp" "$worktree/.sergeant-notification" || {
      rm -f "$notification_tmp"
      return 1
    }
  fi
}
_sgt_wait_worker_notification() {
  local pane="$1" repo_dir="$2" notification_id="$3"
  local timeout="${SGT_NOTIFICATION_ACK_TIMEOUT:-60}" accepted attempt delivered expected_identity nonce pane_identity target_dir
  [[ "$timeout" =~ ^[0-9]+$ ]] || return 1

  attempt=0
  while :; do
    expected_identity="$(cat "$repo_dir/pane_identity" 2>/dev/null || true)"
    pane_identity="$(_sgt_pane_identity "$pane")" || return 1
    [[ -n "$expected_identity" && "$pane_identity" == "$expected_identity" &&
       "${pane_identity%%|*}" == 0 ]] || return 1
    nonce="$(cat "$repo_dir/notification_target" 2>/dev/null || true)"
    [[ "$nonce" =~ ^[a-f0-9]{32}$ ]] || return 1
    target_dir="$repo_dir/notifications/$notification_id/targets/$nonce"
    [[ "$(cat "$target_dir/pane_identity" 2>/dev/null || true)" == "$pane_identity" ]] || return 1
    delivered="$(cat "$target_dir/delivered" 2>/dev/null || true)"
    accepted="$(cat "$target_dir/accepted" 2>/dev/null || true)"
    [[ "$delivered" == "$notification_id|$nonce" && "$accepted" == "$notification_id|$nonce" ]] && return 0
    (( attempt >= timeout * 10 )) && return 1
    attempt=$((attempt + 1))
    sleep 0.1
  done
}
_sgt_worktree_is_validation_clean() {
  local worktree="$1" untracked
  git -C "$worktree" diff --quiet --ignore-submodules -- && \
    git -C "$worktree" diff --cached --quiet --ignore-submodules -- || return 1
  untracked="$(git -C "$worktree" ls-files --others --exclude-standard | \
    while IFS= read -r path; do
      case "$path" in
        .sergeant-*) ;;
        *) printf '%s\n' "$path" ;;
      esac
    done)"
  [[ -z "$untracked" ]]
}
_sgt_td_normalize_version() {
  printf '%s\n' "${1#v}"
}
_sgt_td_supported_semver() {
  [[ "$1" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[[:alnum:]]+([.-][[:alnum:]]+)*)?$ ]]
}
_sgt_td_supported_version_output() {
  # Accept Marcus td's plain version line or its exact three-line update notice.
  # Any unrelated or mixed output still fails before dispatch creates side effects.
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
