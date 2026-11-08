#!/usr/bin/env bash
# run-drain-tests.sh — Drain test suite runner.
#
# Runs every drain-related test that verifies the behaviour fixed by
# GitHub issues #81 (sgt-respond drain admission lock) and #82
# (sgt-drain --status).  Also covers adjacent drain functionality
# (admission gating in sgt-recover, drain state helpers).
#
# Usage (host):
#   bash tests/run-drain-tests.sh
#
# Usage (Docker — system Bash only, Bash 3.2 pass via separate container):
#   docker build -f Dockerfile.test -t sergeant-test .
#   docker run --rm -v "$PWD:/repo:ro" sergeant-test
#
# Usage (Docker — both passes, via mise task):
#   mise run test:docker:drain
#
# Exit codes:
#   0  every case executed and passed; any skip was an allowlisted, documented
#      limitation and at least one case actually ran
#   1  a case failed, a required tool was missing, BASH32 was misconfigured, or
#      no case executed at all
#
# git, tmux, yq, and python3 are prerequisites, not optional conveniences.  This
# runner used to degrade every case that needed them into a skip and still exit
# 0, so the Bash 3.2 pass ran half its cases and reported success (td-5ab019).
# Dockerfile.bash32 supplies all four under Bash 3.2.
#
# Environment variables:
#   BASH32   path to Bash 3.2 binary (default: /usr/local/bin/bash32)
#            set to "" to run the system-Bash pass only; the mise task runs the
#            Bash 3.2 pass in the dedicated Bash 3.2 image

set -euo pipefail

# Resolve the repo root with shell builtins only, so the tool preflight below
# reports a missing-tool diagnosis instead of dying on `dirname: not found`.
_SELF="${BASH_SOURCE[0]}"
case "$_SELF" in
  */*) _SELF_DIR="${_SELF%/*}" ;;
  *) _SELF_DIR="." ;;
esac
ROOT_DIR="$(cd "$_SELF_DIR/.." && pwd)"
BASH32="${BASH32-/usr/local/bin/bash32}"

# shellcheck source=tests/lib/suite-policy.sh
source "$ROOT_DIR/tests/lib/suite-policy.sh"

# ── Preflight ─────────────────────────────────────────────────────────────────
#
# Fail before the first case rather than skipping through to a green summary.

sgt_suite_reset
sgt_suite_require_tools "drain suite" git tmux yq python3
sgt_suite_require_bash32 "$BASH32"

# Known-harmless noise filter for case output: some suites probe for files with
# grep before they exist.
_drain_noise_filter() { grep -v '^grep:.*No such file or directory'; }

# ── Suite ─────────────────────────────────────────────────────────────────────

printf '═══════════════════════════════════════════════════════════\n'
printf ' Sergeant drain test suite\n'
printf ' Repo:  %s\n' "$ROOT_DIR"
printf ' Bash:  %s\n' "$(bash --version | head -1)"
if [[ -n "$BASH32" ]]; then
  printf ' Bash32:%s\n' "$("$BASH32" --version 2>&1 | head -1)"
fi
printf '═══════════════════════════════════════════════════════════\n'

# ── Pass 1: system Bash ───────────────────────────────────────────────────────

printf '\n── Pass 1: system Bash ─────────────────────────────────────\n'

# Global-state isolation guard FIRST: it proves no suite in tests/ can write to
# the operator's real drain, fleet, or notification state.  It runs before the
# drain suites deliberately, because a leaking suite must be caught before it is
# given the chance to run against a live installation.
sgt_suite_run "global state isolation guard" \
  bash "$ROOT_DIR/tests/global-state-isolation-test.sh" _drain_noise_filter

# Core drain state + --status (bug #82) + lock helpers (bug #81)
sgt_suite_run "drain state, --status, lock helpers" \
  bash "$ROOT_DIR/tests/sgt-drain-test.sh" _drain_noise_filter

# sgt-respond drain admission gating (bug #81 — orphaned worker resume).
# This test validates the full flow: drain active → response stored → drain_held
# written → no new-window call.
sgt_suite_run "sgt-respond drain admission" \
  bash "$ROOT_DIR/tests/sgt-respond-drain-test.sh" _drain_noise_filter

# sgt-recover drain gating (adjacent behaviour)
sgt_suite_run "sgt-recover drain gating" \
  bash "$ROOT_DIR/tests/sgt-recover-drain-test.sh" _drain_noise_filter

# sgt-drain-worker: _sgt_drain_write helper and drain detection in the worker
# (covers _sgt_drain_write, _sgt_drain_global_active, _sgt_drain_project_active).
sgt_suite_run "drain write helper + worker drain detection" \
  bash "$ROOT_DIR/tests/sgt-drain-worker-test.sh" _drain_noise_filter

# sgt-worker-drain: _watch_progress drain-signal write (cooperative drain for
# interactive workers; no tmux pane launched).
sgt_suite_run "worker drain checkpoint + _watch_progress drain signal" \
  bash "$ROOT_DIR/tests/sgt-worker-drain-test.sh" _drain_noise_filter

# ── Pass 2: Bash 3.2 ─────────────────────────────────────────────────────────
#
# The preflight already classified BASH32: a non-executable path failed the run,
# and an empty one recorded the documented opt-out skip.

printf '\n── Pass 2: Bash 3.2 ────────────────────────────────────────\n'

if [[ -n "$BASH32" ]]; then
  # Drain state helpers must work under Bash 3.2 — this covers the core of
  # both bugs: --status (bug #82) and lock helpers (bug #81).
  sgt_suite_run "drain state, --status, lock helpers" \
    "$BASH32" "$ROOT_DIR/tests/sgt-drain-test.sh" _drain_noise_filter

  # sgt-recover uses git worktrees for fixture setup.
  sgt_suite_run "sgt-recover drain gating" \
    "$BASH32" "$ROOT_DIR/tests/sgt-recover-drain-test.sh" _drain_noise_filter
else
  printf '\n  not selected in this container — see the documented skip above\n'
fi

# ── Summary ───────────────────────────────────────────────────────────────────

sgt_suite_verdict
