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
#   0  every case executed and passed; any skip was an allowlisted, documented
#      limitation and at least one case actually ran
#   1  a case failed, a required tool was missing, BASH32 was misconfigured, or
#      no case executed at all
#
# git, tmux, yq, and python3 are prerequisites, not optional conveniences.  This
# runner used to degrade every case that needed them into a skip and still exit
# 0, which is how the Bash 3.2 pass reported "0 passed, 0 failed, 9 skipped" as
# success (td-5ab019).  Dockerfile.bash32 supplies all four under Bash 3.2.
#
# Environment variables:
#   BASH32   path to Bash 3.2 binary (default: /usr/local/bin/bash32)
#            set to "" to run the system-Bash pass only; the Bash 3.2 pass then
#            runs in the dedicated Bash 3.2 image (see mise test:docker:*)

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
sgt_suite_require_tools "notification suite" git tmux yq python3
sgt_suite_require_bash32 "$BASH32"

# ── Suite ─────────────────────────────────────────────────────────────────────

printf '═══════════════════════════════════════════════════════════\n'
printf ' Sergeant notification test suite\n'
printf ' Repo:  %s\n' "$ROOT_DIR"
printf ' Bash:  %s\n' "$(bash --version | head -1)"
if [[ -n "$BASH32" ]]; then
  printf ' Bash32:%s\n' "$("$BASH32" --version 2>&1 | head -1)"
fi
printf '═══════════════════════════════════════════════════════════\n'

# ── Pass 1: system Bash ───────────────────────────────────────────────────────

printf '\n── Pass 1: system Bash ─────────────────────────────────────\n'

# Shared harness registry, readiness probe, and settle-seconds default.
sgt_suite_run "shared harness contract and readiness probe" \
  bash "$ROOT_DIR/tests/sgt-harness-test.sh"

# Core delivery handshake: prompt, ack, acceptance, delivered timing, lease.
sgt_suite_run "notification delivery handshake" \
  bash "$ROOT_DIR/tests/sgt-notification-delivery-test.sh"

# Per-harness notification handshake (opencode, goose, claude).
sgt_suite_run "per-harness notification handshake" \
  bash "$ROOT_DIR/tests/sgt-worker-handshake-test.sh"

# Action-lease finalizer: settles a completed lease exactly once and is
# idempotent.
sgt_suite_run "action-lease finalizer" \
  bash "$ROOT_DIR/tests/sgt-lease-finalizer-test.sh"

# Lease convergence before refusal: sgt-respond and sgt-recover converge a
# completed turn before checking lease ownership (GH #168).
sgt_suite_run "action-lease convergence" \
  bash "$ROOT_DIR/tests/sgt-lease-convergence-test.sh"

# Bounded readiness gate: never orphans a worker that acknowledges after the
# settle window; reports readiness failure once and recovers via sgt-respond
# (GH #175).
sgt_suite_run "bounded interactive worker readiness" \
  bash "$ROOT_DIR/tests/sgt-worker-readiness-test.sh"

# sgt-session-resume end-to-end: resumed worker must acknowledge its notification
# within the 60-second timeout so dispatch and resume callers do not time out
# with all ack/accept/complete directories empty.  Pins the PR #246 regression
# (delivered tied to complete_path, not acceptance) as observed by @mrtnebrle.
sgt_suite_run "sgt-session-resume notification handshake" \
  bash "$ROOT_DIR/tests/sgt-session-resume-notification-test.sh"

# ── Pass 2: Bash 3.2 ─────────────────────────────────────────────────────────
#
# The preflight already classified BASH32: a non-executable path failed the run,
# and an empty one recorded the documented opt-out skip.

printf '\n── Pass 2: Bash 3.2 ────────────────────────────────────────\n'

if [[ -n "$BASH32" ]]; then
  # Action-lease finalizer under Bash 3.2 — no tmux server required.
  sgt_suite_run "action-lease finalizer" \
    "$BASH32" "$ROOT_DIR/tests/sgt-lease-finalizer-test.sh"

  # Per-harness handshake drives a real tmux server under Bash 3.2.
  sgt_suite_run "per-harness notification handshake" \
    "$BASH32" "$ROOT_DIR/tests/sgt-worker-handshake-test.sh"
else
  printf '\n  not selected in this container — see the documented skip above\n'
fi

# ── Summary ───────────────────────────────────────────────────────────────────

sgt_suite_verdict
