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
#   0  all tests passed (or skipped)
#   1  one or more tests failed
#
# Environment variables:
#   BASH32   path to Bash 3.2 binary (default: /usr/local/bin/bash32)
#            set to "" to skip the Bash 3.2 pass; the mise task handles
#            the Bash 3.2 pass in the official bash:3.2 Alpine image

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASH32="${BASH32:-/usr/local/bin/bash32}"

# ── Helpers ───────────────────────────────────────────────────────────────────

pass=0
fail=0
skip=0

_run() {
  local label="$1" shell="$2" script="$3"
  printf '\n  %-12s  %s\n' "[$shell]" "$label"
  if "$shell" "$script" 2>&1 | grep -v '^grep:.*No such file or directory' | sed 's/^/    /'; then
    printf '    ✓ passed\n'
    pass=$((pass + 1))
  else
    printf '    ✗ FAILED\n' >&2
    fail=$((fail + 1))
  fi
}

_skip() {
  local label="$1" reason="$2"
  printf '\n  %-12s  %s  (skipped: %s)\n' "[skip]" "$label" "$reason"
  skip=$((skip + 1))
}

# ── Suite ─────────────────────────────────────────────────────────────────────

printf '═══════════════════════════════════════════════════════════\n'
printf ' Sergeant drain test suite\n'
printf ' Repo:  %s\n' "$ROOT_DIR"
printf ' Bash:  %s\n' "$(bash --version | head -1)"
if [[ -x "$BASH32" ]]; then
  printf ' Bash32:%s\n' "$("$BASH32" --version 2>&1 | head -1)"
fi
printf '═══════════════════════════════════════════════════════════\n'

# ── Pass 1: system Bash ───────────────────────────────────────────────────────

printf '\n── Pass 1: system Bash ─────────────────────────────────────\n'

# Global-state isolation guard FIRST: it proves no suite in tests/ can write to
# the operator's real drain, fleet, or notification state.  It runs before the
# drain suites deliberately, because a leaking suite must be caught before it is
# given the chance to run against a live installation.
_run "global state isolation guard" \
  bash "$ROOT_DIR/tests/global-state-isolation-test.sh"

# Core drain state + --status (bug #82) + lock helpers (bug #81)
_run "drain state, --status, lock helpers" \
  bash "$ROOT_DIR/tests/sgt-drain-test.sh"

# sgt-respond drain admission gating (bug #81 — orphaned worker resume).
# This test validates the full flow: drain active → response stored → drain_held
# written → no new-window call.  Requires git for worktree ownership setup.
if command -v git >/dev/null 2>&1; then
  _run "sgt-respond drain admission" \
    bash "$ROOT_DIR/tests/sgt-respond-drain-test.sh"
else
  _skip "sgt-respond drain admission" "git not available in this environment"
fi

# sgt-recover drain gating (adjacent behaviour; requires git for fixture setup)
if command -v git >/dev/null 2>&1; then
  _run "sgt-recover drain gating" \
    bash "$ROOT_DIR/tests/sgt-recover-drain-test.sh"
else
  _skip "sgt-recover drain gating" "git not available in this environment"
fi

# sgt-drain-worker: _sgt_drain_write helper and drain detection in the worker
# (covers _sgt_drain_write, _sgt_drain_global_active, _sgt_drain_project_active).
# Requires git for fixture setup.
if command -v git >/dev/null 2>&1; then
  _run "drain write helper + worker drain detection" \
    bash "$ROOT_DIR/tests/sgt-drain-worker-test.sh"
else
  _skip "drain write helper + worker drain detection" "git not available in this environment"
fi

# sgt-worker-drain: _watch_progress drain-signal write (cooperative drain for
# interactive workers; requires tmux is absent — no tmux pane launched).
_run "worker drain checkpoint + _watch_progress drain signal" \
  bash "$ROOT_DIR/tests/sgt-worker-drain-test.sh"

# ── Pass 2: Bash 3.2 ─────────────────────────────────────────────────────────

printf '\n── Pass 2: Bash 3.2 ────────────────────────────────────────\n'

if [[ -x "$BASH32" ]]; then
  # Drain state helpers must work under Bash 3.2 — this covers the core of
  # both bugs: --status (bug #82) and lock helpers (bug #81).
  _run "drain state, --status, lock helpers" \
    "$BASH32" "$ROOT_DIR/tests/sgt-drain-test.sh"

  # sgt-recover uses git worktrees for fixture setup and is skipped in the
  # Bash 3.2 pass when git is unavailable (e.g. bash:3.2 Alpine image).
  if command -v git >/dev/null 2>&1; then
    _run "sgt-recover drain gating" \
      "$BASH32" "$ROOT_DIR/tests/sgt-recover-drain-test.sh"
  else
    _skip "sgt-recover drain gating (Bash 3.2)" "git not available in this image"
  fi
else
  _skip "Bash 3.2 pass" "BASH32 binary not found at $BASH32"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

printf '\n═══════════════════════════════════════════════════════════\n'
printf ' Results: %d passed, %d failed, %d skipped\n' \
  "$pass" "$fail" "$skip"
printf '═══════════════════════════════════════════════════════════\n'

[[ $fail -eq 0 ]]
