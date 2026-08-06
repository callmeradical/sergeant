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

# shellcheck source=bin/_sgt-drain.sh
source "$_SGT_LIB_DIR/_sgt-drain.sh"

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

# ── Interactive harness launch contract ──────────────────────────────────────
# One shared definition drives every harness-specific launch decision: the
# capability gate (_require_interactive_agent), pinned-tuple validation
# (_sgt_require_agent_model), and the base plus model argv and environment a
# worker actually executes (_sgt_resolve_agent_launch).  Adding a harness means
# adding exactly one line here; the only other harness-aware code left in the
# tree is the Goose interactive-session probe in _require_interactive_agent.
#
# Every value below is MEASURED on a host with that harness installed, never
# inferred from documentation alone.  A harness whose surface has not been
# measured is recorded as "unmeasured" and fails closed for a pin, which is a
# different statement from "the harness cannot do it".
#
# A contract is four space-separated fields:
#
#   1. model_transport — how a pinned provider/model reaches the harness.
#        argv-qualified  argv "--model <provider>/<model>".  OpenCode's help
#                        Options block: "-m, --model  model to use in the format
#                        of provider/model".
#        env-goose       env GOOSE_PROVIDER + GOOSE_MODEL.  "goose session"
#                        exposes no model or provider flag, so the environment is
#                        its only launch-time selector; this is legitimate
#                        because Sergeant controls the worker environment at
#                        spawn.
#        unmeasured      Sergeant has not measured this harness's launch-time
#                        model surface.  A pin fails closed because Sergeant
#                        cannot honor what it has not measured, NOT because the
#                        harness is known to lack the capability.  The verdict is
#                        about Sergeant's knowledge, so the diagnostic must not
#                        claim anything about the caller's host.
#
#   2. variant_transport — how a pinned variant reaches the harness.
#        agent-definition  the harness has no --variant flag, but it accepts
#                          "--agent <name>" at launch and its agent definitions
#                          carry a first-class "variant" field.  Sergeant writes
#                          a fleet-owned definition carrying the pinned model and
#                          variant and launches against it.  Measured: the harness
#                          does load such a definition and register the agent.
#                          TRANSPORT ONLY, NOT VERIFICATION.  The harness exposes
#                          no launch-time surface that reports which variant it
#                          resolved (its agent listing prints the same output for
#                          a bogus variant), so a launch on this transport records
#                          variant_verified=false.  Tracked separately; do not
#                          upgrade that field without a measured read-back.
#        unknown           no launch-time variant selector has been found for
#                          this harness.  A pinned variant fails closed naming
#                          the harness and this reason.
#        unmeasured        as above: not observed here, so not asserted either
#                          way.
#
#   3. provider_scope — which providers the harness can be pinned to.
#        any             the provider travels to the harness explicitly, so it is
#                        verifiable from the launch invocation itself.
#        unmeasured      the harness's provider surface has not been observed.
#
#   4. base_argv — the words that start a persistent interactive session, or "-"
#                  for none.  Interactive-only by construction: no contract may
#                  name a one-shot or non-interactive subcommand.
_sgt_harness_launch_contract() {
  case "$1" in
    opencode|oc) printf 'argv-qualified agent-definition any --dangerously-skip-permissions\n' ;;
    goose)       printf 'env-goose unknown any session\n' ;;
    claude)      printf 'unmeasured unmeasured unmeasured -\n' ;;
    *)           return 1 ;;
  esac
}

# The agent name Sergeant generates when it must carry a pinned variant through
# an agent definition.  Fixed so a resumed worker regenerates the same launch.
SGT_AGENT_VARIANT_AGENT_NAME="sgt-pinned"

# _sgt_write_opencode_agent_definition <path> <model> <variant>
# Writes the fleet-owned harness config that carries a pinned variant.  It lives
# in fleet state, never in the worktree, so a pinned variant cannot leave
# untracked files in the repository under review.
_sgt_write_opencode_agent_definition() {
  local path="$1" model="$2" variant="$3"
  local tmp="$path.tmp.$$"
  {
    printf '{\n'
    # shellcheck disable=SC2016  # Literal JSON key, not a shell expansion.
    printf '  "$schema": "https://opencode.ai/config.json",\n'
    printf '  "agent": {\n'
    printf '    "%s": {\n' "$SGT_AGENT_VARIANT_AGENT_NAME"
    printf '      "description": "Sergeant-pinned model and variant",\n'
    printf '      "mode": "primary",\n'
    printf '      "model": "%s",\n' "$model"
    printf '      "variant": "%s"\n' "$variant"
    printf '    }\n'
    printf '  }\n'
    printf '}\n'
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

# Canonical pinned tuple: provider/model[:variant].  The charsets are
# deliberately narrow so a recorded tuple can never carry a shell
# metacharacter, whitespace, or a credential into durable launch evidence.
# The pattern is held in a variable because Bash 3.2 rejects an inline
# alternation or group on the right-hand side of [[ =~ ]].
_SGT_AGENT_MODEL_RE='^([a-z0-9][a-z0-9-]*)/([A-Za-z0-9][A-Za-z0-9._-]*)(:([A-Za-z0-9][A-Za-z0-9._-]*))?$'

# The literal tuple that means "inherit the ambient harness default".  It is an
# internal sentinel, never an accepted user value; _sgt_is_agent_model_tuple is
# what a caller uses to validate raw user input before the sentinel is applied.
SGT_AGENT_MODEL_UNPINNED="unpinned"

# Every out-parameter below is initialised at library scope so no consumer can
# be reached in an unbound state under `set -u`, whatever order it is called in.
SGT_AGENT_MODEL_PROVIDER=""
SGT_AGENT_MODEL_ID=""
SGT_AGENT_MODEL_VARIANT=""
SGT_LAUNCH_MODEL_TRANSPORT="none"
SGT_LAUNCH_VARIANT_TRANSPORT="none"
SGT_LAUNCH_DEFINITION=""
SGT_LAUNCH_PROVIDER_SCOPE=""
SGT_LAUNCH_PROVIDER_VERIFIED="false"
SGT_LAUNCH_VARIANT_VERIFIED="false"
SGT_LAUNCH_BASE_ARGV=()
SGT_LAUNCH_MODEL_ARGV=()
SGT_LAUNCH_MODEL_ENV=()
SGT_LAUNCH_REJECT=""

# _sgt_is_agent_model_tuple <value>
# True only for a well-formed provider/model[:variant]. Use this to reject raw
# user input, including the internal unpinned sentinel.
_sgt_is_agent_model_tuple() {
  [[ "$1" =~ $_SGT_AGENT_MODEL_RE ]]
}

# _sgt_parse_agent_model <tuple>
# Returns 1 for a malformed tuple.  On success sets SGT_AGENT_MODEL_PROVIDER,
# SGT_AGENT_MODEL_ID, and SGT_AGENT_MODEL_VARIANT (empty when no variant).
_sgt_parse_agent_model() {
  SGT_AGENT_MODEL_PROVIDER=""
  SGT_AGENT_MODEL_ID=""
  SGT_AGENT_MODEL_VARIANT=""
  [[ "$1" =~ $_SGT_AGENT_MODEL_RE ]] || return 1
  SGT_AGENT_MODEL_PROVIDER="${BASH_REMATCH[1]}"
  SGT_AGENT_MODEL_ID="${BASH_REMATCH[2]}"
  SGT_AGENT_MODEL_VARIANT="${BASH_REMATCH[4]}"
}

# _sgt_resolve_agent_launch <harness> <tuple> [state-dir]
# Resolves everything a worker needs to launch a harness, so the coordinator and
# the worker fail closed from one decision and render one diagnostic through
# _sgt_agent_launch_reject_message.  Returns 1 and sets SGT_LAUNCH_REJECT when
# the harness cannot honor the tuple.
#
# <state-dir> is optional and is what separates validation from materialisation:
# without it the call only decides whether the tuple is honorable, so coordinator
# preflight stays free of side effects; with it a variant transport that needs a
# generated harness definition writes that definition into the given directory.
#
# This must be called directly, never in a command substitution: its results are
# out-parameters, and a subshell would discard every one of them.
#
# On return sets: SGT_LAUNCH_MODEL_TRANSPORT, SGT_LAUNCH_VARIANT_TRANSPORT,
# SGT_LAUNCH_PROVIDER_SCOPE, SGT_LAUNCH_PROVIDER_VERIFIED, SGT_LAUNCH_BASE_ARGV,
# SGT_LAUNCH_MODEL_ARGV, SGT_LAUNCH_MODEL_ENV, SGT_LAUNCH_DEFINITION,
# SGT_LAUNCH_REJECT, and the _sgt_parse_agent_model fields.
# shellcheck disable=SC2034  # Out-parameters consumed by sourced scripts.
_sgt_resolve_agent_launch() {
  local harness="$1" tuple="$2" state_dir="${3:-}" contract
  local model_transport variant_transport provider_scope base_argv
  SGT_LAUNCH_MODEL_TRANSPORT="none"
  SGT_LAUNCH_VARIANT_TRANSPORT="none"
  SGT_LAUNCH_PROVIDER_SCOPE=""
  SGT_LAUNCH_PROVIDER_VERIFIED="false"
  SGT_LAUNCH_VARIANT_VERIFIED="false"
  SGT_LAUNCH_BASE_ARGV=()
  SGT_LAUNCH_MODEL_ARGV=()
  SGT_LAUNCH_MODEL_ENV=()
  SGT_LAUNCH_DEFINITION=""
  SGT_LAUNCH_REJECT=""
  SGT_AGENT_MODEL_PROVIDER=""
  SGT_AGENT_MODEL_ID=""
  SGT_AGENT_MODEL_VARIANT=""

  if ! contract="$(_sgt_harness_launch_contract "$harness")"; then
    SGT_LAUNCH_REJECT="unsupported-harness"
    return 1
  fi
  # One decoder for the contract record, so field order is never re-derived
  # anywhere else.
  read -r model_transport variant_transport provider_scope base_argv <<< "$contract"
  SGT_LAUNCH_PROVIDER_SCOPE="$provider_scope"
  [[ "$base_argv" == "-" ]] || SGT_LAUNCH_BASE_ARGV=("$base_argv")

  [[ -n "$tuple" && "$tuple" != "$SGT_AGENT_MODEL_UNPINNED" ]] || return 0

  if ! _sgt_parse_agent_model "$tuple"; then
    SGT_LAUNCH_REJECT="malformed-tuple"
    return 1
  fi

  # A pin is only honorable on a transport that has actually been observed.
  if [[ "$model_transport" == "unmeasured" ]]; then
    SGT_LAUNCH_REJECT="model-transport-unmeasured"
    return 1
  fi
  if [[ "$provider_scope" != "any" && "$SGT_AGENT_MODEL_PROVIDER" != "$provider_scope" ]]; then
    SGT_LAUNCH_REJECT="provider-out-of-scope"
    return 1
  fi
  if [[ -n "$SGT_AGENT_MODEL_VARIANT" ]]; then
    case "$variant_transport" in
      unknown)    SGT_LAUNCH_REJECT="variant-transport-unknown"; return 1 ;;
      unmeasured) SGT_LAUNCH_REJECT="variant-transport-unmeasured"; return 1 ;;
    esac
  fi

  SGT_LAUNCH_MODEL_TRANSPORT="$model_transport"
  case "$model_transport" in
    argv-qualified)
      SGT_LAUNCH_MODEL_ARGV=(--model "$SGT_AGENT_MODEL_PROVIDER/$SGT_AGENT_MODEL_ID")
      # The provider travels in the argument, so the invocation proves it.
      SGT_LAUNCH_PROVIDER_VERIFIED="true"
      ;;
    env-goose)
      SGT_LAUNCH_MODEL_ENV=("GOOSE_PROVIDER=$SGT_AGENT_MODEL_PROVIDER" \
        "GOOSE_MODEL=$SGT_AGENT_MODEL_ID")
      SGT_LAUNCH_PROVIDER_VERIFIED="true"
      ;;
  esac

  [[ -n "$SGT_AGENT_MODEL_VARIANT" ]] || return 0
  SGT_LAUNCH_VARIANT_TRANSPORT="$variant_transport"
  case "$variant_transport" in
    agent-definition)
      # The harness has no --variant flag but does accept "--agent <name>", and
      # its agent definitions carry a variant field.  Launch against a
      # Sergeant-generated definition that pins both model and variant.
      SGT_LAUNCH_MODEL_ARGV=("${SGT_LAUNCH_MODEL_ARGV[@]+${SGT_LAUNCH_MODEL_ARGV[@]}}" \
        --agent "$SGT_AGENT_VARIANT_AGENT_NAME")
      [[ -n "$state_dir" ]] || return 0
      SGT_LAUNCH_DEFINITION="$state_dir/opencode-config.json"
      if ! _sgt_write_opencode_agent_definition "$SGT_LAUNCH_DEFINITION" \
        "$SGT_AGENT_MODEL_PROVIDER/$SGT_AGENT_MODEL_ID" "$SGT_AGENT_MODEL_VARIANT"; then
        SGT_LAUNCH_DEFINITION=""
        SGT_LAUNCH_REJECT="variant-definition-unwritable"
        return 1
      fi
      SGT_LAUNCH_MODEL_ENV=("${SGT_LAUNCH_MODEL_ENV[@]+${SGT_LAUNCH_MODEL_ENV[@]}}" \
        "OPENCODE_CONFIG=$SGT_LAUNCH_DEFINITION")
      ;;
  esac
}

# _sgt_agent_launch_reject_message <harness> <tuple> <reject-reason>
# Renders the diagnostic for a _sgt_resolve_agent_launch rejection.  Both the
# coordinator (which dies) and the worker (which records a fleet diagnostic) use
# this, so an operator sees one wording for one cause.  Every message names the
# harness and distinguishes "this harness cannot" from "this has not been
# observed here".
_sgt_agent_launch_reject_message() {
  local harness="$1" tuple="$2" reject="$3"
  case "$reject" in
    unsupported-harness)
      printf 'unsupported interactive agent: %s (expected opencode, goose, or claude)\n' \
        "$harness"
      ;;
    model-transport-unmeasured)
      printf 'Sergeant has not measured %s launch-time model pinning, so it cannot honor %s: dispatch without --model, or add a measured contract line for %s.\n' \
        "$harness" "$tuple" "$harness"
      ;;
    variant-transport-unknown)
      printf '%s has no known launch-time variant selector, so :%s in %s cannot be pinned: configure the variant in %s itself, or drop the variant.\n' \
        "$harness" "$SGT_AGENT_MODEL_VARIANT" "$tuple" "$harness"
      ;;
    variant-transport-unmeasured)
      printf 'Sergeant has not measured %s variant pinning, so it cannot honor :%s in %s: drop the variant, or add a measured contract line for %s.\n' \
        "$harness" "$SGT_AGENT_MODEL_VARIANT" "$tuple" "$harness"
      ;;
    variant-definition-unwritable)
      printf 'could not write the %s agent definition carrying variant :%s for %s\n' \
        "$harness" "$SGT_AGENT_MODEL_VARIANT" "$tuple"
      ;;
    provider-out-of-scope)
      printf '%s can only be pinned to provider %s, not %s: %s\n' \
        "$harness" "$SGT_LAUNCH_PROVIDER_SCOPE" "$SGT_AGENT_MODEL_PROVIDER" "$tuple"
      ;;
    *)
      printf 'model must be provider/model or provider/model:variant, with a [a-z0-9-] provider and [A-Za-z0-9._-] model: %s\n' \
        "$tuple"
      ;;
  esac
}

# _sgt_require_agent_model <harness> <tuple>
# Dies with an actionable diagnostic when a harness cannot honor a pinned
# tuple.  Callers must invoke this before creating any intent file, td task,
# worktree, or fleet state.
_sgt_require_agent_model() {
  local harness="$1" tuple="$2"
  _sgt_resolve_agent_launch "$harness" "$tuple" || \
    _die "$(_sgt_agent_launch_reject_message "$harness" "$tuple" "$SGT_LAUNCH_REJECT")"
}

# ── Global config (dev_root) ──────────────────────────────────────────────────

DEV_ROOT="$HOME/Dev"  # sensible default
SGT_DEFAULT_IDENTITY=""  # set from config.yaml default_identity

_sgt_load_global_config() {
  local cfg="$SERGEANT_CONFIG/config.yaml"
  if [[ -f "$cfg" ]] && command -v yq &>/dev/null; then
    local dr
    dr="$(yq '.dev_root // ""' "$cfg" 2>/dev/null | tr -d '\n')"
    if [[ -n "$dr" && "$dr" != "null" ]]; then
      DEV_ROOT="${dr/#\~/$HOME}"
    fi
    local di
    di="$(yq '.default_identity // ""' "$cfg" 2>/dev/null | tr -d '\n')"
    if [[ -n "$di" && "$di" != "null" ]]; then
      # shellcheck disable=SC2034  # sourced by dispatch, which consumes this global.
      SGT_DEFAULT_IDENTITY="$di"
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
  _sgt_harness_launch_contract "$agent_name" >/dev/null || \
    _die "unsupported interactive agent: $AGENT_CMD (expected opencode, goose, or claude)"
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

# A tmux pane id is always "%" followed by digits.  Held in a variable because
# Bash 3.2 mishandles some inline right-hand-side patterns in [[ =~ ]].
_SGT_TMUX_PANE_ID_RE='^%[0-9]+$'
_sgt_is_tmux_pane_id() {
  [[ "$1" =~ $_SGT_TMUX_PANE_ID_RE ]]
}

# _sgt_verify_pane_identity <pane-id>
# Prints the pane's exact identity only when the live tmux server confirms that
# the pane exists, is not dead, and reports back the very pane id that was
# asked for.  Returns 1 otherwise, so an absent, stale, or forged identity fails
# closed instead of being adopted.
_sgt_verify_pane_identity() {
  local pane="$1" identity
  identity="$(_sgt_pane_identity "$pane" || true)"
  [[ -n "$identity" && "${identity%%|*}" == "0" && \
     "${identity#*|}" == "$pane|"* ]] || return 1
  printf '%s\n' "$identity"
}

# Sergeant keeps at most one managed coordinator pane per tmux session, so an
# API-driven coordinator that dispatches repeatedly does not accumulate panes.
# shellcheck disable=SC2034  # Shared default consumed by sourced scripts.
SGT_MANAGED_COORDINATOR_WINDOW="sgt-coordinator"
# The managed coordinator pane runs a reader that echoes every line it receives
# and never executes it.  A tmux-injected notification therefore stays readable
# evidence for whoever attaches, and can never become a shell command in the
# coordinator's own pane.  Single-quoted so the loop body reaches tmux verbatim.
# shellcheck disable=SC2016  # Deliberately unexpanded: this string is sh source for tmux.
SGT_MANAGED_COORDINATOR_COMMAND='while IFS= read -r sgt_line; do printf "%s\n" "$sgt_line"; done; exec sleep 2147483647'

# Ownership token for the managed coordinator pane, set as a tmux pane option at
# creation and required before the pane is ever adopted.
#
# This is deliberately NOT pane_start_command: tmux renders that field quoted and
# backslash-escaped, so comparing it against the literal command can never match
# and every reuse would be refused.  A pane option round-trips exactly and is
# absent on a pane Sergeant did not create, which is precisely the question being
# asked.
SGT_MANAGED_COORDINATOR_OPTION='@sgt_coordinator'
SGT_MANAGED_COORDINATOR_MARKER='sergeant-managed-coordinator'

# _sgt_managed_coordinator_marker <pane>
# Prints the pane's Sergeant ownership marker, empty when it has none.
_sgt_managed_coordinator_marker() {
  tmux display-message -p -t "$1" "#{$SGT_MANAGED_COORDINATOR_OPTION}" 2>/dev/null
}

_sgt_managed_coordinator_pane() {
  local session="$1" window="$2" pane panes

  # Exact name match ("=" prefix): a substring match, or two windows sharing the
  # name, must not silently become "create another one".
  panes="$(tmux list-panes -t "$session:=$window" -F '#{pane_id}' 2>/dev/null || true)"
  if [[ -n "$panes" ]]; then
    # More than one pane in the managed window means someone split or reused it;
    # refuse rather than guess which pane is the coordinator.
    [[ "$(printf '%s\n' "$panes" | grep -c .)" == "1" ]] || return 1
    pane="$panes"
    _sgt_verify_pane_identity "$pane" >/dev/null || return 1
    # Adopt only a pane carrying Sergeant's own ownership marker.  Without this,
    # any window a user happened to name the same thing — a shell, an editor —
    # would become the coordinator target and an injected notification would run
    # in it.
    [[ "$(_sgt_managed_coordinator_marker "$pane")" == "$SGT_MANAGED_COORDINATOR_MARKER" ]] || \
      return 1
    printf '%s false\n' "$pane"
    return 0
  fi

  tmux new-session -d -s "$session" -n sergeant 2>/dev/null || true
  pane="$(tmux new-window -d -P -F '#{pane_id}' -t "$session:" -n "$window" \
    "$SGT_MANAGED_COORDINATOR_COMMAND" 2>/dev/null)" || return 1
  [[ -n "$pane" ]] || return 1
  # Stamp ownership before returning.  A pane that cannot be marked could never
  # be adopted later, so fail closed rather than leak an unadoptable window.
  if ! tmux set-option -p -t "$pane" "$SGT_MANAGED_COORDINATOR_OPTION" \
      "$SGT_MANAGED_COORDINATOR_MARKER" 2>/dev/null ||
     [[ "$(_sgt_managed_coordinator_marker "$pane")" != "$SGT_MANAGED_COORDINATOR_MARKER" ]]; then
    tmux kill-pane -t "$pane" 2>/dev/null || true
    return 1
  fi
  printf '%s true\n' "$pane"
}

_sgt_path_mode() {
  stat -c '%a' -- "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}
_sgt_fd_mode() {
  stat -L -c '%a' -- "$1" 2>/dev/null || stat -L -f '%Lp' "$1" 2>/dev/null
}
_sgt_legacy_identity_mode() {
  case "$1" in
    640|644|660|664) return 0 ;;
    *) return 1 ;;
  esac
}
_sgt_read_owned_file() {
  local path="$1" mode fd_mode value
  [[ -f "$path" && ! -L "$path" && -O "$path" ]] || return 1
  mode="$(_sgt_path_mode "$path")" || return 1
  [[ "$mode" == "600" ]] || return 1
  exec 9< "$path" || return 1
  fd_mode="$(_sgt_fd_mode /dev/fd/9)" || {
    exec 9<&-
    return 1
  }
  if [[ "$fd_mode" != "600" || ! -f /dev/fd/9 || ! -O /dev/fd/9 || \
    ! -f "$path" || -L "$path" || ! -O "$path" || ! "$path" -ef /dev/fd/9 ]]; then
    exec 9<&-
    return 1
  fi
  value="$(cat <&9)" || { exec 9<&-; return 1; }
  fd_mode="$(_sgt_fd_mode /dev/fd/9)" || {
    exec 9<&-
    return 1
  }
  if [[ "$fd_mode" != "600" || ! -O /dev/fd/9 || -L "$path" || \
    ! "$path" -ef /dev/fd/9 ]]; then
    exec 9<&-
    return 1
  fi
  exec 9<&-
  printf '%s\n' "$value"
}
_sgt_read_matching_legacy_pane_identity() {
  local path="$1" actual="$2" mode fd_mode value migrated candidate current_mode
  [[ -n "$actual" ]] || return 1
  [[ -f "$path" && ! -L "$path" && -O "$path" ]] || return 1
  mode="$(_sgt_path_mode "$path")" || return 1
  _sgt_legacy_identity_mode "$mode" || return 1
  exec 9< "$path" || return 1
  fd_mode="$(_sgt_fd_mode /dev/fd/9)" || {
    exec 9<&-
    return 1
  }
  if [[ "$fd_mode" != "$mode" || ! -f /dev/fd/9 || ! -O /dev/fd/9 || \
    ! -f "$path" || -L "$path" || ! -O "$path" || ! "$path" -ef /dev/fd/9 ]]; then
    exec 9<&-
    return 1
  fi
  value="$(cat <&9)" || { exec 9<&-; return 1; }
  [[ "$value" == "$actual" ]] || { exec 9<&-; return 1; }
  candidate="${path}.tmp.$$.$RANDOM.$RANDOM"
  (umask 077; set -C; printf '%s\n' "$value" > "$candidate") 2>/dev/null || {
    exec 9<&-
    return 1
  }
  chmod 600 "$candidate" || {
    rm -f "$candidate"
    exec 9<&-
    return 1
  }
  current_mode="$(_sgt_path_mode "$path")" || {
    rm -f "$candidate"
    exec 9<&-
    return 1
  }
  fd_mode="$(_sgt_fd_mode /dev/fd/9)" || {
    rm -f "$candidate"
    exec 9<&-
    return 1
  }
  if [[ "$current_mode" != "$mode" || "$fd_mode" != "$mode" || \
    ! -f /dev/fd/9 || ! -O /dev/fd/9 || \
    ! -f "$path" || -L "$path" || ! -O "$path" || ! "$path" -ef /dev/fd/9 ]]; then
    rm -f "$candidate"
    exec 9<&-
    return 1
  fi
  mv "$candidate" "$path" || {
    rm -f "$candidate"
    exec 9<&-
    return 1
  }
  exec 9<&-
  migrated="$(_sgt_read_owned_file "$path" 2>/dev/null || true)"
  [[ "$migrated" == "$actual" ]] || return 1
  printf '%s\n' "$migrated"
}
_sgt_read_same_owned_files() {
  local first="$1" second="$2" first_mode second_mode first_fd_mode second_fd_mode
  local first_value second_value
  [[ -f "$first" && ! -L "$first" && -O "$first" && \
    -f "$second" && ! -L "$second" && -O "$second" ]] || return 1
  first_mode="$(_sgt_path_mode "$first")" || return 1
  second_mode="$(_sgt_path_mode "$second")" || return 1
  [[ "$first_mode" == "600" && "$second_mode" == "600" ]] || return 1
  exec 8< "$first" || return 1
  exec 9< "$second" || { exec 8<&-; return 1; }
  first_fd_mode="$(_sgt_fd_mode /dev/fd/8)"
  second_fd_mode="$(_sgt_fd_mode /dev/fd/9)"
  if [[ "$first_fd_mode" != "600" || "$second_fd_mode" != "600" || \
    ! -f /dev/fd/8 || ! -f /dev/fd/9 || ! -O /dev/fd/8 || ! -O /dev/fd/9 || \
    ! "$first" -ef /dev/fd/8 || ! "$second" -ef /dev/fd/9 || \
    ! /dev/fd/8 -ef /dev/fd/9 || -L "$first" || -L "$second" ]]; then
    exec 8<&- 9<&-
    return 1
  fi
  first_value="$(cat <&8)" || { exec 8<&- 9<&-; return 1; }
  second_value="$(cat <&9)" || { exec 8<&- 9<&-; return 1; }
  first_fd_mode="$(_sgt_fd_mode /dev/fd/8)"
  second_fd_mode="$(_sgt_fd_mode /dev/fd/9)"
  if [[ "$first_fd_mode" != "600" || "$second_fd_mode" != "600" || \
    ! -f /dev/fd/8 || ! -f /dev/fd/9 || ! -O /dev/fd/8 || ! -O /dev/fd/9 || \
    -L "$first" || -L "$second" || \
    ! "$first" -ef /dev/fd/8 || ! "$second" -ef /dev/fd/9 || \
    ! /dev/fd/8 -ef /dev/fd/9 ]]; then
    exec 8<&- 9<&-
    return 1
  fi
  exec 8<&- 9<&-
  [[ "$first_value" == "$second_value" ]] || return 1
  printf '%s\n' "$first_value"
}
_sgt_replace_owned_file() {
  local path="$1" value="$2" candidate
  candidate="${path}.tmp.$$.$RANDOM.$RANDOM"
  (umask 077; set -C; printf '%s\n' "$value" > "$candidate") 2>/dev/null || return 1
  chmod 600 "$candidate" || { rm -f "$candidate"; return 1; }
  mv "$candidate" "$path" || { rm -f "$candidate"; return 1; }
}
_sgt_pane_identity_matches() {
  local pane="$1" repo_dir="$2" identity_name="${3:-pane_identity}" expected actual current
  actual="$(_sgt_pane_identity "$pane")" || return 1
  [[ "${actual%%|*}" == "0" ]] || return 1
  expected="$(_sgt_read_owned_file "$repo_dir/$identity_name" 2>/dev/null || true)"
  if [[ -z "$expected" ]]; then
    expected="$(_sgt_read_matching_legacy_pane_identity "$repo_dir/$identity_name" "$actual" \
      2>/dev/null || true)"
  fi
  [[ -n "$expected" ]] || return 1
  current="$(_sgt_pane_identity "$pane")" || return 1
  [[ "$actual" == "$expected" && "$current" == "$actual" ]]
}
_sgt_worker_command() {
  printf '%q %q %q %q' "$1" "$2" "$3" "$4"
}
_sgt_notification_target_create() {
  local repo_dir="$1" notification_id="$2" pane_identity="$3"
  local nonce target_dir temporary published_nonce
  nonce="$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  target_dir="$repo_dir/notifications/$notification_id/targets/$nonce"
  # pane_identity is stored exclusively inside target_dir so it is bound to the
  # nonce atomically; there is no separate top-level notification_target_pane_identity
  # file.  Callers that need the identity read it from
  # notifications/$id/targets/$(cat notification_target)/pane_identity.
  mkdir -p "$target_dir" || return 1
  printf '%s\n' "$pane_identity" > "$target_dir/pane_identity" || return 1
  temporary="$repo_dir/notification_target.tmp.$$"
  printf '%s\n' "$nonce" > "$temporary" || return 1
  # Atomic rename publishes our nonce.  A competing write that lands before our
  # mv is harmless because rename(2) overwrites the destination atomically.  A
  # write that lands after our mv is the failure window and is detected by the
  # post-mv verification below.
  mv "$temporary" "$repo_dir/notification_target" || return 1
  # Test seam: inject a concurrent replacement after the mv to exercise the
  # post-mv verification path.  Active only when SGT_TEST_HOOKS=1; never set
  # in production.  See sgt-lib-notification-target-test.sh.
  if [[ "${SGT_TEST_HOOKS:-}" == "1" && -n "${_SGT_POST_MV_HOOK:-}" ]]; then
    eval "${_SGT_POST_MV_HOOK}"
  fi
  # Post-mv verification: if notification_target no longer holds our nonce, a
  # concurrent publisher replaced it after our mv.  Remove the orphaned target
  # directory and return failure.
  published_nonce="$(cat "$repo_dir/notification_target" 2>/dev/null || true)"
  if [[ "$published_nonce" != "$nonce" ]]; then
    rm -rf "$target_dir"
    return 1
  fi
  printf '%s\n' "$nonce"
}
_sgt_publish_worker_notification() {
  local repo_dir="$1" worktree="$2" notification_id="$3" kind="$4" instruction="$5"
  local state_dir notification_state notification_tmp current_id current_ack current_delivered
  local proof_dir proof_tmp repo_tmp active_id current_ack_token current_delivered_identity
  local current_target_identity current_target_nonce

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
  # Derive the current target's pane_identity from the nonce-addressed target_dir
  # rather than a top-level notification_target_pane_identity file.  This is
  # race-free because pane_identity was written into target_dir before the nonce
  # was published atomically via mv.
  current_target_nonce="$(cat "$repo_dir/notification_target" 2>/dev/null || true)"
  current_target_identity=""
  if [[ -n "$current_id" && "$current_target_nonce" =~ ^[a-f0-9]{32}$ ]]; then
    current_target_identity="$(cat "$repo_dir/notifications/$current_id/targets/$current_target_nonce/pane_identity" 2>/dev/null || true)"
  fi
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
# _sgt_wait_worker_notification <pane> <repo_dir> <notification_id>
#
# Waits for the DELIVERY handshake only: the nudge reached the exact target pane
# and acceptance was published for that target's nonce.  Returning 0 does NOT
# mean the agent has acted.  Action completion is a separate, later state owned
# by the action lease and reported by _sgt_notification_action_completed /
# _sgt_notification_action_pending in bin/_sgt-response-lock.sh.
#
# Conflating the two is what GH #168 reported: delivery was called success while
# the accepted lease was still outstanding, so callers believed a turn was
# settled when nothing had published completion.  The two states now have
# distinct names and distinct durable artefacts — targets/<nonce>/handshake_complete
# for delivery, targets/<nonce>/completed for the action.
_sgt_wait_worker_notification() {
  local pane="$1" repo_dir="$2" notification_id="$3"
  local timeout="${SGT_NOTIFICATION_ACK_TIMEOUT:-60}" accepted attempt delivered expected_identity nonce pane_identity target_dir temporary
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
    if [[ "$delivered" == "$notification_id|$nonce" && "$accepted" == "$notification_id|$nonce" ]]; then
      # Record delivery as its own state, distinct from action completion.
      if [[ ! -e "$target_dir/handshake_complete" ]]; then
        temporary="$target_dir/handshake_complete.tmp.$$.$RANDOM"
        if printf '%s\n' "$notification_id|$nonce" > "$temporary" 2>/dev/null; then
          mv "$temporary" "$target_dir/handshake_complete" 2>/dev/null || \
            rm -f "$temporary" 2>/dev/null || true
        else
          rm -f "$temporary" 2>/dev/null || true
        fi
      fi
      return 0
    fi
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
# ── Managed background monitor helpers ───────────────────────────────────────
#
# Background monitor: run sgt-watch as a transient systemd user unit so
# OpenCode does not need to hold a Bash call open.  The unit is named
# sgt-watch-<task-id>.service, is started with --collect so systemd removes
# it automatically on exit, and its per-run InvocationID is stored in the
# fleet to bind stop authorization to the exact instance (TOCTOU protection).
#
# The indirection variables SERGEANT_SYSTEMCTL and SERGEANT_SYSTEMD_RUN allow
# tests to substitute a fake service manager without touching PATH.

_sgt_systemctl() {
  "${SERGEANT_SYSTEMCTL:-systemctl}" "$@"
}

_sgt_systemd_run() {
  "${SERGEANT_SYSTEMD_RUN:-systemd-run}" "$@"
}

# Validate that a task ID is safe for use in a systemd unit name.
# Accepts only alphanumeric characters, hyphens, dots, and underscores;
# rejects anything else to prevent argument injection and name collisions.
_sgt_validate_monitor_task_id() {
  local task_id="$1"
  case "$task_id" in
    ""|"."|".."|/*|*/*)
      _die "Invalid task ID: $task_id"
      ;;
  esac
  [[ "$task_id" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || \
    _die "Task ID contains characters not allowed in managed monitor unit name (only alphanumeric, hyphen, dot, underscore permitted): $task_id"
}

# Return the full systemd service unit name for a task's background monitor.
_sgt_monitor_unit_name() {
  local task_id="$1"
  printf 'sgt-watch-%s.service\n' "$task_id"
}

# Return the current InvocationID of a unit (empty string if not active).
_sgt_monitor_invocation_id() {
  local unit="$1"
  local id
  id="$(_sgt_systemctl --user show --property=InvocationID --value "$unit" 2>/dev/null | tr -d '\n')" || true
  # An inactive/absent unit returns an empty string or the zero GUID from systemd.
  # Treat the zero GUID as absent.
  case "${id:-}" in
    ""|"00000000000000000000000000000000") printf '' ;;
    *) printf '%s\n' "$id" ;;
  esac
}

# Print the stable monitor identity block shown after a successful start or
# idempotent return.
_sgt_print_monitor_identity() {
  local unit="$1" invocation_id="$2"
  printf 'monitor: %s (invocation: %s)\n' "$unit" "$invocation_id"
  printf '\n'
  printf '  status:  systemctl --user status %s\n' "$unit"
  printf '  log:     journalctl --user -u %s -f\n' "$unit"
  printf '  stop:    systemctl --user stop %s\n' "$unit"
}

# Start a background monitor for <task-id>, or return the existing one
# idempotently.  Writes monitor_unit and monitor_invocation_id into the
# task's fleet directory for ownership binding at cleanup time.
_sgt_background_watch() {
  local task_id="$1" task_dir="$2"
  local unit live_inv invocation_id
  local env_args=()

  _sgt_validate_monitor_task_id "$task_id"

  # Fail fast on unsupported platforms before touching any state.
  command -v "${SERGEANT_SYSTEMD_RUN:-systemd-run}" >/dev/null 2>&1 || \
    _die "Managed background monitor requires systemd user services (systemd-run not found). Use 'sgt-watch $task_id' for foreground monitoring instead."
  command -v "${SERGEANT_SYSTEMCTL:-systemctl}" >/dev/null 2>&1 || \
    _die "Managed background monitor requires systemd user services (systemctl not found). Use 'sgt-watch $task_id' for foreground monitoring instead."

  unit="$(_sgt_monitor_unit_name "$task_id")"

  # Check if the unit is already active regardless of the state of the ownership
  # files.  This handles three cases without calling systemd-run (which would
  # fail with 'unit already exists' for an active unit):
  #   1. Files present and IDs match   — normal idempotent return.
  #   2. Files missing or stale        — adopt the live unit and update files.
  #   3. Unit externally restarted     — adopt the new instance.
  live_inv="$(_sgt_monitor_invocation_id "$unit")"
  if [[ -n "$live_inv" ]]; then
    # Unit is active.  Write ownership files (invocation_id first; if monitor_unit
    # write is lost, cleanup silently skips rather than dying on a missing ID).
    printf '%s\n' "$live_inv" > "$task_dir/monitor_invocation_id.tmp.$$"
    mv "$task_dir/monitor_invocation_id.tmp.$$" "$task_dir/monitor_invocation_id"
    printf '%s\n' "$unit"     > "$task_dir/monitor_unit.tmp.$$"
    mv "$task_dir/monitor_unit.tmp.$$" "$task_dir/monitor_unit"
    _sgt_print_monitor_identity "$unit" "$live_inv"
    return 0
  fi

  # Unit is not active — start a new transient monitor.
  # Propagate the fleet directory when it differs from the compiled-in default
  # so the monitor finds the task in the same location.
  if [[ -n "${SERGEANT_FLEET:-}" ]]; then
    env_args+=(--setenv="SERGEANT_FLEET=$SERGEANT_FLEET")
  fi
  # Propagate test-only service-manager overrides if set (no-op in production).
  if [[ -n "${SERGEANT_SYSTEMCTL:-}" ]]; then
    env_args+=(--setenv="SERGEANT_SYSTEMCTL=$SERGEANT_SYSTEMCTL")
  fi
  if [[ -n "${SERGEANT_SYSTEMD_RUN:-}" ]]; then
    env_args+=(--setenv="SERGEANT_SYSTEMD_RUN=$SERGEANT_SYSTEMD_RUN")
  fi
  if [[ -n "${SGT_FAKE_SYSTEMD_STATE:-}" ]]; then
    env_args+=(--setenv="SGT_FAKE_SYSTEMD_STATE=$SGT_FAKE_SYSTEMD_STATE")
  fi
  # Propagate the calling user's PATH so user-installed tools (e.g. td from
  # /home/linuxbrew/.linuxbrew/bin) remain resolvable inside the transient unit.
  # The systemd user manager starts with a lean minimal PATH that omits custom
  # install prefixes, causing sgt-td-memory to fail with "td unavailable for handoff".
  if [[ -n "${PATH:-}" ]]; then
    env_args+=(--setenv="PATH=$PATH")
  fi

  _sgt_systemd_run --user \
    --unit="$unit" \
    --collect \
    --description="Sergeant fleet monitor for $task_id" \
    "${env_args[@]}" \
    "$_SGT_LIB_DIR/sgt-watch" "$task_id" || \
    _die "Failed to start managed background monitor for $task_id"

  # Capture the InvocationID that systemd assigned to this exact run.
  # systemd assigns the InvocationID asynchronously after the unit transitions
  # to active; retry briefly so a slow host does not fail the read.
  invocation_id=""
  local _inv_attempt=0
  while [[ -z "$invocation_id" && "$_inv_attempt" -lt 20 ]]; do
    invocation_id="$(_sgt_monitor_invocation_id "$unit")"
    if [[ -z "$invocation_id" ]]; then
      sleep 0.1
      _inv_attempt=$((_inv_attempt + 1))
    fi
  done
  [[ -n "$invocation_id" ]] || \
    _die "Failed to read InvocationID after starting monitor for $task_id (unit: $unit)"

  # Persist ownership with invocation_id written first so a crash between the
  # two writes leaves monitor_unit absent; cleanup then silently skips rather
  # than dying on a missing invocation ID.
  printf '%s\n' "$invocation_id" > "$task_dir/monitor_invocation_id.tmp.$$"
  mv "$task_dir/monitor_invocation_id.tmp.$$" "$task_dir/monitor_invocation_id"
  printf '%s\n' "$unit"          > "$task_dir/monitor_unit.tmp.$$"
  mv "$task_dir/monitor_unit.tmp.$$" "$task_dir/monitor_unit"

  _sgt_print_monitor_identity "$unit" "$invocation_id"
}

# Stop the background monitor registered for a task fleet directory, binding
# the stop to the exact stored InvocationID to prevent TOCTOU replacement.
# Silently succeeds when no monitor is registered or the unit is already gone.
_sgt_stop_background_monitor() {
  local task_dir="$1"
  local unit stored_inv current_inv

  # shellcheck disable=SC2002  # cat used intentionally: suppresses bash's own redirect error for absent files
  unit="$(cat "$task_dir/monitor_unit" 2>/dev/null | tr -d '\n' || true)"
  [[ -n "$unit" ]] || return 0  # No monitor registered for this task.

  # shellcheck disable=SC2002
  stored_inv="$(cat "$task_dir/monitor_invocation_id" 2>/dev/null | tr -d '\n' || true)"
  [[ -n "$stored_inv" ]] || \
    _die "Background monitor unit registered ($unit) but invocation ID is missing; cannot safely stop"

  current_inv="$(_sgt_monitor_invocation_id "$unit")"

  if [[ -z "$current_inv" ]]; then
    # Unit is inactive or already collected — nothing to stop.
    echo "  background monitor already stopped: $unit"
    return 0
  fi

  if [[ "$current_inv" != "$stored_inv" ]]; then
    # A different process instance holds this unit name (TOCTOU replacement).
    # Refuse to stop the foreign unit.
    _die "Background monitor unit has unexpected invocation ID (stored: $stored_inv, actual: $current_inv); refusing to stop foreign unit: $unit"
  fi

  echo "  stopping background monitor: $unit"
  _sgt_systemctl --user stop "$unit" || \
    _die "Failed to stop background monitor: $unit"
}

# _sgt_branch_unpushed_commits <repo-path> <branch>
#
# Print the one-line log of commits on <branch> that are not reachable from ANY
# remote-tracking ref, or nothing when the branch is fully published or absent.
#
# Reachability, not name matching, is the contract.  A commit that exists on a
# remote under a different branch name is published and must not be reported.
#
# Two failure modes this deliberately avoids (td-7f3a9a):
#   1. Excluding only "refs/remotes/origin/<branch>" makes the rev-list argument
#      invalid whenever that ref does not exist, which is the normal case for a
#      branch that has never been pushed.  The previous implementation fell back
#      to listing the branch's ENTIRE history, so the caller's guard fired for
#      every unpublished branch and re-dispatch onto preserved work became
#      impossible in any repository the operator cannot push to.
#   2. "git log" on an absent ref is a fatal error, not an empty result, so the
#      ref must be verified before it is used.
#
# "--not --remotes" is always a valid argument set: with no remotes configured it
# excludes nothing, so every commit is correctly reported as unpushed.
_sgt_branch_unpushed_commits() {
  local repo_path="$1" branch="$2"
  [[ -n "$repo_path" && -n "$branch" ]] || return 0
  git -C "$repo_path" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null || return 0
  git -C "$repo_path" log --oneline "refs/heads/$branch" --not --remotes 2>/dev/null || true
}
