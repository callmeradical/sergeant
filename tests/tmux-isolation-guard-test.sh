#!/usr/bin/env bash
# Guard: no test may drive a tmux server it does not own.
#
# Seam under test: the tests/ directory itself, read as text.  This is a static
# guard rather than a behavioral test because the failure it prevents is
# destructive and cannot be safely reproduced -- proving it by running the
# offending test would destroy the developer's tmux session, which is precisely
# the defect (td-be53d1).
#
# Why this exists.  On 2026-08-14 a full `tests/` run killed the developer's tmux
# server twice (session recreated 10:45:45 and 11:58:49).  Four test files drove
# real tmux on the DEFAULT socket while executing the real
# bin/sgt-interactive-worker, whose terminate path is deliberately destructive:
#
#     kill -TERM -"$pgid"                # process-group TERM
#     tmux kill-pane -t "$TMUX_PANE"     # pane removal
#     kill -KILL -"$pgid"                # process-group KILL
#
# On an isolated server those signals stay inside the fixture.  On the default
# server they land on real panes and real process groups; when the caught pane is
# the only pane of the only session, the tmux server exits with it.  The first
# occurrence killed dispatched worker add-cross-platform-serge-e86975 mid-rebase,
# because repository-native validation runs this suite -- so Sergeant's own
# validation step killed Sergeant's own worker and recorded it `orphaned` with no
# durable explanation.
#
# A test isolates itself in one of two established ways:
#   export TMUX_TMPDIR="$TEST_ROOT/tmux"   -- confines the socket directory
#   tmux -L <socket> / tmux -S <path>      -- names a private socket per call
#
# Isolation must appear BEFORE the first tmux invocation; setting TMUX_TMPDIR
# afterwards leaves the earlier calls on the default socket.

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$(basename "${BASH_SOURCE[0]}")"

# This guard only reads files -- it executes nothing.  It still declares a
# private state root, for two reasons.  First, the isolation audit
# (tests/global-state-isolation-test.sh) matches the literal string
# "bin/sgt-interactive-worker" anywhere in a suite, including the rationale
# above, and requires a declared root; satisfying that invariant unconditionally
# is cheaper and more honest than wording the comment around a grep.  Second, if
# this guard ever grows to execute a candidate command, the isolation is already
# in place rather than added after the first leak.
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
export SERGEANT_CONFIG="$TEST_ROOT/config"
export SERGEANT_DRAIN_DIR="$TEST_ROOT/drain"
export SERGEANT_FLEET="$TEST_ROOT/fleet"
export TMUX_TMPDIR="$TEST_ROOT/tmux"
mkdir -p "$SERGEANT_CONFIG" "$SERGEANT_DRAIN_DIR" "$SERGEANT_FLEET" "$TMUX_TMPDIR"

# tmux subcommands that reach a server.  A test using any of these needs a
# server, and therefore needs to own the one it talks to.
SERVER_SUBCOMMANDS='new-session|new-window|kill-server|kill-session|kill-pane|split-window|send-keys|respawn-pane|respawn-window|set-option|show-options|display-message|list-panes|list-sessions|list-windows|has-session|select-window|select-pane|switch-client|attach-session|capture-pane|paste-buffer'

offenders=""
checked=0

for test_file in "$TESTS_DIR"/*.sh; do
  [[ -f "$test_file" ]] || continue
  name="$(basename "$test_file")"
  [[ "$name" != "$SELF" ]] || continue

  # First real tmux invocation at command position, ignoring comment lines.  The
  # leading-context class keeps `sgt-tmux-helper` and similar from matching.
  first_tmux="$(grep -nE "(^|[;&|(]|[[:space:]])tmux[[:space:]]+($SERVER_SUBCOMMANDS)" \
    "$test_file" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1 || true)"

  # A file that never talks to a tmux server has nothing to isolate.  Tests that
  # exercise dispatch through a fake tmux shim on PATH land here, correctly: they
  # never reach a real server.
  [[ -n "$first_tmux" ]] || continue

  checked=$((checked + 1))

  first_isolation="$(grep -nE 'TMUX_TMPDIR=|tmux -L |tmux -S ' "$test_file" 2>/dev/null \
    | grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1 || true)"

  if [[ -z "$first_isolation" ]]; then
    offenders+="  $name: drives a tmux server with no isolation (first tmux call line $first_tmux)"$'\n'
  elif (( first_isolation > first_tmux )); then
    offenders+="  $name: isolation at line $first_isolation comes after the first tmux call at line $first_tmux"$'\n'
  fi
done

(( checked > 0 )) || {
  printf 'FAIL: guard matched no tmux-driving tests; the detector is broken\n' >&2
  exit 1
}

if [[ -n "$offenders" ]]; then
  printf 'FAIL: these tests drive a tmux server they do not own (td-be53d1):\n' >&2
  printf '%s' "$offenders" >&2
  # shellcheck disable=SC2016  # Literal advice text; $TEST_ROOT must not expand.
  printf '\nFix: export TMUX_TMPDIR="$TEST_ROOT/tmux" (and mkdir -p it) before the\n' >&2
  printf 'first tmux call, or scope every call with tmux -L <socket>.\n' >&2
  exit 1
fi

printf 'tmux isolation guard: ok (%d tmux-driving tests, all isolated)\n' "$checked"
