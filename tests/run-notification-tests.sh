#!/usr/bin/env bash
# run-notification-tests.sh — Notification delivery handshake test suite runner.
#
# Covers the supervisor/worker notification contract: prompt delivery, agent
# acknowledgement, acceptance publication, delivered marker timing, action-lease
# finalization, and per-harness readiness gate behaviour.
#
# These tests were introduced to catch regressions in the delivery handshake
# fixed by GH #114 and GH #229, and in the delivered-marker timing regression
# introduced in PR #243 and fixed in PR #246.
#
# Usage (host):
#   bash tests/run-notification-tests.sh
#
# Usage (Docker — system Bash only):
#   docker build -f Dockerfile.test -t sergeant-test .
#   docker run --rm -v "$PWD:/repo:ro" sergeant-test \
#     bash /repo/tests/run-notification-tests.sh
#
# Usage (Docker — both passes, via mise task):
#   mise run test:docker:notification
#
# Exit codes:
#   0  all tests passed (or skipped)
#   1  one or more tests failed
#
# Environment variables:
#   BASH32   path to Bash 3.2 binary (default: /usr/local/bin/bash32)
#            set to "" to skip the Bash 3.2 pass

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
  if "$shell" "$script" 2>&1 | sed 's/^/    /'; then
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
printf ' Sergeant notification test suite\n'
printf ' Repo:  %s\n' "$ROOT_DIR"
printf ' Bash:  %s\n' "$(bash --version | head -1)"
if [[ -x "$BASH32" ]]; then
  printf ' Bash32:%s\n' "$("$BASH32" --version 2>&1 | head -1)"
fi
printf '═══════════════════════════════════════════════════════════\n'

# ── Pass 1: system Bash ───────────────────────────────────────────────────────

printf '\n── Pass 1: system Bash ─────────────────────────────────────\n'

# Shared harness registry, readiness probe, and settle-seconds default.
# Requires tmux.
if command -v tmux >/dev/null 2>&1; then
  _run "shared harness contract and readiness probe" \
    bash "$ROOT_DIR/tests/sgt-harness-test.sh"
else
  _skip "shared harness contract and readiness probe" "tmux not available"
fi

# Core delivery handshake: prompt, ack, acceptance, delivered timing, lease.
# Requires tmux and git (for sgt-interactive-worker fixture setup).
if command -v tmux >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
  _run "notification delivery handshake" \
    bash "$ROOT_DIR/tests/sgt-notification-delivery-test.sh"
else
  _skip "notification delivery handshake" "tmux or git not available"
fi

# Per-harness notification handshake (opencode, goose, claude).
# Requires tmux and git.
if command -v tmux >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
  _run "per-harness notification handshake" \
    bash "$ROOT_DIR/tests/sgt-worker-handshake-test.sh"
else
  _skip "per-harness notification handshake" "tmux or git not available"
fi

# Action-lease finalizer: settles a completed lease exactly once and is
# idempotent.  No tmux required.
if command -v git >/dev/null 2>&1; then
  _run "action-lease finalizer" \
    bash "$ROOT_DIR/tests/sgt-lease-finalizer-test.sh"
else
  _skip "action-lease finalizer" "git not available"
fi

# Lease convergence before refusal: sgt-respond and sgt-recover converge a
# completed turn before checking lease ownership (GH #168).  Requires git.
if command -v git >/dev/null 2>&1; then
  _run "action-lease convergence" \
    bash "$ROOT_DIR/tests/sgt-lease-convergence-test.sh"
else
  _skip "action-lease convergence" "git not available"
fi

# Bounded readiness gate: never orphans a worker that acknowledges after the
# settle window; reports readiness failure once and recovers via sgt-respond
# (GH #175).  Requires tmux + git.
if command -v tmux >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
  _run "bounded interactive worker readiness" \
    bash "$ROOT_DIR/tests/sgt-worker-readiness-test.sh"
else
  _skip "bounded interactive worker readiness" "tmux or git not available"
fi

# sgt-session-resume end-to-end: resumed worker must acknowledge its notification
# within the 60-second timeout so dispatch and resume callers do not time out
# with all ack/accept/complete directories empty.  Pins the PR #246 regression
# (delivered tied to complete_path, not acceptance) as observed by @mrtnebrle.
# Requires tmux, git, yq, python3.
if command -v tmux >/dev/null 2>&1 && command -v git >/dev/null 2>&1 && \
   command -v yq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  _run "sgt-session-resume notification handshake" \
    bash "$ROOT_DIR/tests/sgt-session-resume-notification-test.sh"
else
  _skip "sgt-session-resume notification handshake" \
    "tmux, git, yq, or python3 not available"
fi

# ── Pass 2: Bash 3.2 ─────────────────────────────────────────────────────────

printf '\n── Pass 2: Bash 3.2 ────────────────────────────────────────\n'

if [[ ! -x "$BASH32" ]]; then
  _skip "Bash 3.2 pass" "BASH32 binary not found at ${BASH32:-/usr/local/bin/bash32}"
else
  # Action-lease finalizer does not require tmux — confirm it is Bash 3.2
  # compatible.  The other notification tests need tmux, which is absent from
  # the bash:3.2 Alpine image.
  if command -v git >/dev/null 2>&1; then
    _run "action-lease finalizer" \
      "$BASH32" "$ROOT_DIR/tests/sgt-lease-finalizer-test.sh"
  else
    _skip "action-lease finalizer (Bash 3.2)" "git not available in this image"
  fi

  # Per-harness handshake needs tmux; skip in Alpine.
  if command -v tmux >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
    _run "per-harness notification handshake" \
      "$BASH32" "$ROOT_DIR/tests/sgt-worker-handshake-test.sh"
  else
    _skip "per-harness notification handshake (Bash 3.2)" \
      "tmux or git not available in this image"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────

printf '\n═══════════════════════════════════════════════════════════\n'
printf ' Results: %d passed, %d failed, %d skipped\n' \
  "$pass" "$fail" "$skip"
printf '═══════════════════════════════════════════════════════════\n'

[[ $fail -eq 0 ]]
