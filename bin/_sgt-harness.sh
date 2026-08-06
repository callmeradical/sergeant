#!/usr/bin/env bash
# _sgt-harness.sh — The single definition of every accepted interactive harness.
# Source this file; do not execute it directly.
#
# Sergeant used to describe each harness in three unrelated places inside
# bin/sgt-interactive-worker: the accepted-harness capability gate, the
# readiness probe, and the launch invocation.  They drifted, and `claude` ended
# up accepted by the gate and launchable while being permanently unable to
# satisfy readiness — so its notification was never injected.  One registry now
# drives all three, and _sgt_harness_registry_validate fails loudly when a row
# omits a probe or names a probe that is not implemented.
#
# Registry row format:
#
#   <harness>:<probe>:<launch-args>
#
#   harness      basename of the accepted harness executable
#   probe        readiness probe identifier; must appear in
#                _sgt_harness_supported_probes
#   launch-args  space-separated extra arguments, possibly empty
#
# Readiness contract for the `tui` probe
# --------------------------------------
# Readiness answers exactly one question: will a keystroke sent to this pane
# reach a running harness rather than being swallowed during startup?  It is
# deliberately free of any UI presentation string and of any harness-name
# comparison:
#
#   * A presentation string such as OpenCode's "Ask anything..." breaks on every
#     harness UI revision (GH #156).
#   * #{pane_current_command} is the interpreter for an interpreted harness —
#     `node` for claude — so comparing it to the harness name can never succeed
#     (GH #175).
#
# The probe therefore requires that the pane is alive and that the harness has
# been observed rendering on two consecutive probes.  Requiring two consecutive
# observations, rather than a fixed wall-clock delay, scales with whatever
# interval the caller already polls at: one second in the worker's delivery loop,
# milliseconds in tests.  SGT_HARNESS_SETTLE_SECONDS adds a wall-clock minimum on
# top when a deployment wants one; it defaults to none.
# Every accepted harness uses this probe, including interpreted ones.

_SGT_HARNESS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/_sgt-bash-version.sh
source "$_SGT_HARNESS_SCRIPT_DIR/_sgt-bash-version.sh"
_sgt_require_running_bash || return 1

# Readiness probes that _sgt_harness_ready actually implements.  A registry row
# naming anything else is a programming error and fails validation.
_sgt_harness_supported_probes() {
  printf '%s\n' tui
}

# The registry.  Bash 3.2 has no associative arrays, so rows are plain lines.
#
# SGT_TEST_HOOKS=1 plus _SGT_HARNESS_REGISTRY_OVERRIDE substitutes a registry so
# tests can exercise malformed rows.  Never set in production.
_sgt_harness_registry() {
  if [[ "${SGT_TEST_HOOKS:-}" == "1" && -n "${_SGT_HARNESS_REGISTRY_OVERRIDE:-}" ]]; then
    printf '%s\n' "$_SGT_HARNESS_REGISTRY_OVERRIDE"
    return 0
  fi
  # The opencode harness is launched with --dangerously-skip-permissions.
  # This is a deliberate security posture decision: Sergeant workers execute
  # in an automated dispatch context, not an interactive session. The operator
  # approves scope at dispatch time through the intent file and worker brief
  # content — there is no human at the keyboard to respond to individual
  # permission gates.  The flag bypasses OpenCode's interactive confirmation
  # prompts so the worker can proceed autonomously.  Operator trust is scoped
  # to the intent file reviewed and approved at dispatch time; the worker
  # cannot escalate beyond that scope.  See docs/using-sergeant.md for the
  # full security model.
  printf '%s\n' \
    'opencode:tui:--dangerously-skip-permissions' \
    'oc:tui:--dangerously-skip-permissions' \
    'goose:tui:session' \
    'claude:tui:'
}

# Print the registry row for a harness, or return 1 when it is not accepted.
_sgt_harness_row() {
  local harness="$1" row
  [[ -n "$harness" ]] || return 1
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    [[ "${row%%:*}" == "$harness" ]] || continue
    printf '%s\n' "$row"
    return 0
  done <<EOF
$(_sgt_harness_registry)
EOF
  return 1
}

# Print every accepted harness name, one per line.
_sgt_harness_names() {
  local row
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    printf '%s\n' "${row%%:*}"
  done <<EOF
$(_sgt_harness_registry)
EOF
}

_sgt_harness_is_accepted() {
  _sgt_harness_row "$1" >/dev/null 2>&1
}

# Print the readiness probe identifier declared for a harness.
_sgt_harness_probe() {
  local row rest
  row="$(_sgt_harness_row "$1")" || return 1
  rest="${row#*:}"
  printf '%s\n' "${rest%%:*}"
}

# Print the harness launch arguments, one per line.  Prints nothing for a
# harness that takes no extra arguments; returns 1 for an unknown harness.
_sgt_harness_launch_args() {
  local row rest args argument
  row="$(_sgt_harness_row "$1")" || return 1
  rest="${row#*:}"
  args="${rest#*:}"
  [[ -n "$args" ]] || return 0
  # Word splitting is intended: launch args are a fixed, space-separated,
  # non-user-supplied vector defined in the registry above.
  # shellcheck disable=SC2086
  for argument in $args; do
    printf '%s\n' "$argument"
  done
}

# Validate the whole registry.  Fails loudly, naming the offending row, when a
# harness omits its probe, names an unimplemented probe, is malformed, or is
# declared twice.  Callers run this before honouring the capability gate so a
# newly accepted harness cannot ship without a readiness probe.
_sgt_harness_registry_validate() {
  local row harness probe seen="" supported
  supported="$(_sgt_harness_supported_probes)"
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    if [[ ! "$row" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*:[A-Za-z0-9][A-Za-z0-9._-]*: ]]; then
      harness="${row%%:*}"
      printf 'ERROR: harness registry row for %s is malformed or declares no readiness probe (expected <harness>:<probe>:<launch-args>): %s\n' \
        "${harness:-<unnamed>}" "$row" >&2
      return 1
    fi
    harness="${row%%:*}"
    probe="${row#*:}"
    probe="${probe%%:*}"
    if ! printf '%s\n' "$supported" | grep -Fxq "$probe"; then
      printf 'ERROR: harness %s declares readiness probe %s, which is not implemented (supported: %s)\n' \
        "$harness" "$probe" "$(printf '%s' "$supported" | tr '\n' ' ')" >&2
      return 1
    fi
    if printf '%s\n' "$seen" | grep -Fxq "$harness"; then
      printf 'ERROR: harness %s is declared more than once in the harness registry\n' \
        "$harness" >&2
      return 1
    fi
    seen="$seen$harness
"
  done <<EOF
$(_sgt_harness_registry)
EOF
}

# Capability gate.  Returns non-zero, with an actionable message, when the
# registry is inconsistent or the harness is not accepted.
_sgt_harness_require_accepted() {
  local harness="$1"
  _sgt_harness_registry_validate || return 1
  _sgt_harness_is_accepted "$harness" && return 0
  printf 'ERROR: unsupported interactive agent: %s (accepted: %s)\n' \
    "$harness" "$(_sgt_harness_names | tr '\n' ' ' | sed 's/ *$//')" >&2
  return 1
}

# First-render bookkeeping.  A worker probes exactly one pane, so a single slot
# is enough; switching panes restarts the observation.
_SGT_HARNESS_READY_PANE=""
_SGT_HARNESS_READY_SINCE=""

# _sgt_harness_settle_seconds: optional wall-clock minimum on top of the
# two-consecutive-observations rule.  Defaults to none.
_sgt_harness_settle_seconds() {
  local settle="${SGT_HARNESS_SETTLE_SECONDS-0}"
  [[ "$settle" =~ ^[0-9]+$ ]] || settle=0
  printf '%s\n' "$settle"
}

# _sgt_harness_ready_tui <pane>
# Alive pane + rendered output observed on two consecutive probes + any
# configured wall-clock minimum.  No presentation string, no harness-name
# comparison.
_sgt_harness_ready_tui() {
  local pane="$1" observed capture now settle first_observation
  [[ -n "$pane" ]] || return 1
  command -v tmux >/dev/null 2>&1 || return 1

  # `display-message -t <gone>` silently falls back to the default target, so the
  # pane id has to be read back and compared rather than the exit status trusted.
  observed="$(tmux display-message -p -t "$pane" '#{pane_id}|#{pane_dead}' 2>/dev/null)" || return 1
  [[ "$observed" == "$pane|0" ]] || return 1

  capture="$(tmux capture-pane -p -t "$pane" 2>/dev/null)" || return 1
  # Any non-whitespace glyph proves the harness has drawn its interface.  The
  # supervisor itself prints nothing into this pane, so output can only be the
  # harness.
  [[ -n "$(printf '%s' "$capture" | tr -d '[:space:]')" ]] || return 1

  now="$(date +%s)"
  [[ "$now" =~ ^[0-9]+$ ]] || return 1
  first_observation=0
  if [[ "$_SGT_HARNESS_READY_PANE" != "$pane" || ! "$_SGT_HARNESS_READY_SINCE" =~ ^[0-9]+$ ]]; then
    _SGT_HARNESS_READY_PANE="$pane"
    _SGT_HARNESS_READY_SINCE="$now"
    first_observation=1
  fi
  # Never deliver on the very first sighting of a drawn pane: a TUI that has just
  # painted its first frame may still be installing its input handlers.
  (( first_observation == 0 )) || return 1

  settle="$(_sgt_harness_settle_seconds)"
  (( now >= _SGT_HARNESS_READY_SINCE )) || return 1
  (( now - _SGT_HARNESS_READY_SINCE >= settle ))
}

# _sgt_harness_ready <harness> <pane>
# Dispatches to the probe declared for the harness in the one registry.
_sgt_harness_ready() {
  local harness="$1" pane="$2" probe
  [[ -n "$harness" && -n "$pane" ]] || return 1
  probe="$(_sgt_harness_probe "$harness")" || return 1
  case "$probe" in
    tui) _sgt_harness_ready_tui "$pane" ;;
    *)
      printf 'ERROR: harness %s declares unimplemented readiness probe %s\n' \
        "$harness" "$probe" >&2
      return 1
      ;;
  esac
}
