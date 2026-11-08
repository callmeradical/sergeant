#!/usr/bin/env bash
# Tests for tests/lib/suite-policy.sh — the suite skip/verdict policy shared by
# tests/run-drain-tests.sh and tests/run-notification-tests.sh (td-5ab019).
#
# Why this exists:
#   The Bash 3.2 compatibility passes reported "✓ passed" while executing zero
#   assertions.  The bash:3.2 Alpine image shipped no git, tmux, yq, or python3,
#   so every tool-guarded case skipped, and both runners exited 0 because they
#   only counted failures.  A vacuous pass is worse than no pass: it is a green
#   gate that guards nothing.
#
# Seams under test:
#   sgt_suite_reset / _record_pass / _record_fail   case tallies
#   sgt_suite_missing_tools <tool>...               tool probe, builtins only
#   sgt_suite_require_tools <tool>...               fail-fast preflight
#   sgt_suite_require_bash32 <path>                 BASH32 preflight classifier
#   sgt_suite_skip <label> <code> <detail>          allowlisted skips only
#   sgt_suite_verdict                               never green on a vacuous run
#   tests/run-drain-tests.sh                        preflights before any case
#   tests/run-notification-tests.sh                 preflights before any case
#
# The library must be Bash 3.2 clean: it is sourced by suites that run under
# Bash 3.2.  When a Bash 3.2 binary is available this suite re-executes itself
# under it, so a Bash 4+ construct in the policy cannot reach main unnoticed.
#
# shellcheck disable=SC2016,SC2034
# Assertions intentionally pass their condition as a single-quoted string for
# eval, so the variables they reference are read there rather than here.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

LIB="$ROOT_DIR/tests/lib/suite-policy.sh"

failures=0

_ok() { printf '  %s: ok\n' "$1"; }

_bad() {
  printf '  %s: FAIL — %s\n' "$1" "$2" >&2
  failures=$((failures + 1))
}

_assert() {
  local description="$1" condition="$2"
  if eval "$condition"; then
    _ok "$description"
  else
    _bad "$description" "condition failed: $condition"
  fi
}

# _contains <haystack> <needle> — substring test without a regex engine.
_contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

_assert_contains() {
  local description="$1" haystack="$2" needle="$3"
  if _contains "$haystack" "$needle"; then
    _ok "$description"
  else
    _bad "$description" "expected output to contain '$needle'; got: $haystack"
  fi
}

# _capture <fn> [args...] — run a policy function in THIS shell, capturing its
# output in $out and returning its exit status.  Command substitution would run
# the function in a subshell and discard the tally it is supposed to update, so
# the output goes through a file instead.
CAPTURE_FILE=""
out=""
rc=0
_capture() {
  local status=0
  CAPTURE_FILE="$TEST_ROOT/capture.out"
  "$@" > "$CAPTURE_FILE" 2>&1 || status=$?
  out="$(<"$CAPTURE_FILE")"
  return $status
}

# ── 0. The library must exist and be sourceable ───────────────────────────────

[[ -f "$LIB" ]] || {
  printf 'FAIL: missing %s — the shared suite policy library\n' "$LIB" >&2
  exit 1
}

# shellcheck source=tests/lib/suite-policy.sh
source "$LIB"

# ── 1. Tallies start at zero and count what happened ──────────────────────────

sgt_suite_reset
_assert "reset zeroes the tallies" \
  '[[ $SGT_SUITE_PASS -eq 0 && $SGT_SUITE_FAIL -eq 0 && $SGT_SUITE_SKIP -eq 0 ]]'

sgt_suite_record_pass
sgt_suite_record_pass
sgt_suite_record_fail
_assert "pass and fail tallies are independent" \
  '[[ $SGT_SUITE_PASS -eq 2 && $SGT_SUITE_FAIL -eq 1 && $SGT_SUITE_SKIP -eq 0 ]]'

# ── 2. An allowlisted skip is a skip, and only an allowlisted one ─────────────

sgt_suite_reset
rc=0
_capture sgt_suite_skip "Bash 3.2 pass" bash32-pass-not-selected \
  "BASH32 empty; the dedicated Bash 3.2 image runs that pass" || rc=$?
_assert "documented skip returns success" '[[ $rc -eq 0 ]]'
_assert "documented skip counts as a skip, not a failure" \
  '[[ $SGT_SUITE_SKIP -eq 1 && $SGT_SUITE_FAIL -eq 0 ]]'
_assert_contains "documented skip names its reason code" "$out" \
  "bash32-pass-not-selected"

sgt_suite_reset
rc=0
_capture sgt_suite_skip "notification delivery handshake" "tmux not available" \
  "no detail" || rc=$?
_assert "an unallowlisted skip reason is refused" '[[ $rc -ne 0 ]]'
_assert "an unallowlisted skip is counted as a failure" \
  '[[ $SGT_SUITE_FAIL -eq 1 && $SGT_SUITE_SKIP -eq 0 ]]'
_assert_contains "an unallowlisted skip explains itself" "$out" \
  "not an allowlisted"

# ── 3. The tool probe reports exactly the missing tools ───────────────────────

sgt_suite_reset
missing="$(sgt_suite_missing_tools sh cd 2>&1 || true)"
_assert "tools that resolve are not reported missing" '[[ -z "$missing" ]]'

rc=0
missing="$(sgt_suite_missing_tools sh sgt-definitely-not-a-real-tool 2>&1)" || rc=$?
_assert "a missing tool makes the probe return non-zero" '[[ $rc -ne 0 ]]'
_assert "the probe reports only the missing tool" \
  '[[ "$missing" == "sgt-definitely-not-a-real-tool" ]]'

# ── 4. Preflight fails fast rather than skipping ──────────────────────────────

rc=0
_capture sgt_suite_require_tools "drain suite" sh sgt-definitely-not-a-real-tool || rc=$?
_assert "require_tools fails when a required tool is absent" '[[ $rc -ne 0 ]]'
_assert_contains "require_tools names the missing tools" "$out" \
  "missing required tools: sgt-definitely-not-a-real-tool"
_assert_contains "require_tools says how to get a complete environment" "$out" \
  "test:docker"

rc=0
sgt_suite_require_tools "drain suite" sh cd >/dev/null 2>&1 || rc=$?
_assert "require_tools succeeds when every tool resolves" '[[ $rc -eq 0 ]]'

# ── 5. BASH32 preflight: empty is deliberate, wrong is broken ────────────────

sgt_suite_reset
rc=0
_capture sgt_suite_require_bash32 "" || rc=$?
_assert "an empty BASH32 is a deliberate opt-out, not an error" '[[ $rc -eq 0 ]]'
_assert "the opted-out Bash 3.2 pass is recorded as a documented skip" \
  '[[ $SGT_SUITE_SKIP -eq 1 && $SGT_SUITE_FAIL -eq 0 ]]'

sgt_suite_reset
rc=0
_capture sgt_suite_require_bash32 "$TEST_ROOT/no-such-bash32" || rc=$?
_assert "a BASH32 path that does not exist is a hard failure" '[[ $rc -ne 0 ]]'
_assert_contains "the broken BASH32 failure names the path" "$out" \
  "$TEST_ROOT/no-such-bash32"
_assert "a broken BASH32 is never silently skipped" '[[ $SGT_SUITE_SKIP -eq 0 ]]'

printf '#!/bin/sh\nexit 0\n' > "$TEST_ROOT/fake-bash32"
chmod +x "$TEST_ROOT/fake-bash32"
sgt_suite_reset
rc=0
sgt_suite_require_bash32 "$TEST_ROOT/fake-bash32" >/dev/null 2>&1 || rc=$?
_assert "an executable BASH32 preflights clean" \
  '[[ $rc -eq 0 && $SGT_SUITE_SKIP -eq 0 && $SGT_SUITE_FAIL -eq 0 ]]'

# ── 6. The verdict is never green on a vacuous run ───────────────────────────

sgt_suite_reset
sgt_suite_record_pass
rc=0
_capture sgt_suite_verdict || rc=$?
_assert "a run with one passing case and no failures is green" '[[ $rc -eq 0 ]]'
_assert_contains "the verdict keeps the canonical Results line" "$out" \
  "Results: 1 passed, 0 failed, 0 skipped"

sgt_suite_reset
sgt_suite_skip "Bash 3.2 pass" bash32-pass-not-selected "deliberate" >/dev/null 2>&1
rc=0
_capture sgt_suite_verdict || rc=$?
_assert "a run where every case skipped is never reported as success" \
  '[[ $rc -ne 0 ]]'
_assert_contains "the vacuous run explains why it failed" "$out" \
  "no test case executed"

sgt_suite_reset
sgt_suite_record_pass
sgt_suite_record_fail
rc=0
sgt_suite_verdict >/dev/null 2>&1 || rc=$?
_assert "a run with a failing case is not green" '[[ $rc -ne 0 ]]'

# ── 7. Both runners preflight before executing any case ──────────────────────
#
# The runners must refuse a tool-starved or misconfigured environment instead of
# skipping their way to exit 0.  PATH is emptied, so a runner that reaches its
# banner (which shells out to `bash --version | head -1`) would fail for the
# wrong reason: these assertions also pin that the preflight runs first, using
# shell builtins only.

EMPTY_BIN="$TEST_ROOT/empty-bin"
mkdir -p "$EMPTY_BIN"
BASH_BIN="${BASH:-/bin/bash}"

for runner in run-drain-tests.sh run-notification-tests.sh; do
  rc=0
  out="$(PATH="$EMPTY_BIN" BASH32="" "$BASH_BIN" "$ROOT_DIR/tests/$runner" 2>&1)" || rc=$?
  _assert "$runner fails when required tools are missing" '[[ $rc -ne 0 ]]'
  _assert_contains "$runner names the missing tools" "$out" \
    "missing required tools:"
  for tool in git tmux yq python3; do
    _assert_contains "$runner requires $tool" "$out" "$tool"
  done
  _assert "$runner ran no case before failing preflight" \
    '! _contains "$out" "Pass 1"'

  rc=0
  out="$(BASH32="$TEST_ROOT/no-such-bash32" "$BASH_BIN" "$ROOT_DIR/tests/$runner" 2>&1)" || rc=$?
  _assert "$runner fails on a BASH32 path that is not executable" '[[ $rc -ne 0 ]]'
  _assert_contains "$runner names the unusable BASH32 path" "$out" \
    "$TEST_ROOT/no-such-bash32"
  _assert "$runner does not run its suite with a broken BASH32" \
    '! _contains "$out" "Results:"'
done

# ── 8. The policy must be Bash 3.2 clean ─────────────────────────────────────

BASH32_UNDER_TEST="${BASH32:-${SGT_MINIMUM_BASH:-}}"
if [[ -z "${SGT_SUITE_POLICY_CHILD:-}" && -n "$BASH32_UNDER_TEST" && -x "$BASH32_UNDER_TEST" ]]; then
  version="$("$BASH32_UNDER_TEST" --version 2>&1 | head -1)"
  printf '  re-executing under %s\n' "$version"
  if SGT_SUITE_POLICY_CHILD=1 BASH32="" SGT_MINIMUM_BASH="" \
      "$BASH32_UNDER_TEST" "$ROOT_DIR/tests/suite-policy-test.sh" \
      2>&1 | sed 's/^/    /'; then
    _ok "suite policy is clean under $version"
  else
    _bad "suite policy under $version" "re-execution failed"
  fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────

if [[ $failures -ne 0 ]]; then
  printf 'suite-policy: %d assertion(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'suite-policy: all tests passed\n'
