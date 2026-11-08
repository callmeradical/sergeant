#!/usr/bin/env bash
# tests/lib/suite-policy.sh — shared case tally, skip policy, and verdict for the
# Sergeant suite runners (tests/run-drain-tests.sh, tests/run-notification-tests.sh).
#
# Why this library exists (td-5ab019):
#   Both runners used to count only failures, so a pass in which every case
#   skipped exited 0 and was reported as "✓ passed".  The bash:3.2 Alpine image
#   shipped no git, tmux, yq, or python3, so the entire Bash 3.2 notification
#   pass skipped and still contributed a green tick to the pre-push gate.  A
#   Bash 3.2 incompatibility in any of those code paths could reach main behind
#   a fully green gate.
#
# The policy this library enforces:
#   1. Required tools are prerequisites, not conveniences.  A missing tool fails
#      the run before any case executes; it never downgrades a case to a skip.
#   2. A skip is legal only with a reason code on SGT_SUITE_ALLOWED_SKIP_CODES,
#      each of which names a deliberate, documented limitation.
#   3. A run that executed no case is never a success, however many cases it
#      skipped.
#
# Bash 3.2 compatibility is mandatory: the runners source this file while running
# under Bash 3.2.  No associative arrays, no `[[ =~ ]]`, no brace ranges.
# tests/suite-policy-test.sh re-executes itself under Bash 3.2 to enforce that.

# ── Allowlisted skip reason codes ─────────────────────────────────────────────
#
# bash32-pass-not-selected
#   The caller set BASH32="" to opt out of the Bash 3.2 pass, because that pass
#   runs as a separate container in the same mise task (see Dockerfile.bash32
#   and the test:docker:* tasks).  This is orchestration, not a missing tool:
#   the pass still runs, in the image built to run it.
#
# Add a code here only for a limitation that is deliberate and documented, and
# only together with the sentence that explains it.  "Tool X is not installed"
# is never such a limitation — install X, or fail.
SGT_SUITE_ALLOWED_SKIP_CODES="bash32-pass-not-selected"

SGT_SUITE_PASS=0
SGT_SUITE_FAIL=0
SGT_SUITE_SKIP=0

# sgt_suite_reset — zero the tallies.
sgt_suite_reset() {
  SGT_SUITE_PASS=0
  SGT_SUITE_FAIL=0
  SGT_SUITE_SKIP=0
}

sgt_suite_record_pass() { SGT_SUITE_PASS=$((SGT_SUITE_PASS + 1)); }
sgt_suite_record_fail() { SGT_SUITE_FAIL=$((SGT_SUITE_FAIL + 1)); }

# sgt_suite_missing_tools <tool>... — print the tools that do not resolve, one
# space-separated line; return 0 when every tool is present.
#
# Uses only shell builtins so it can run before the runner touches PATH-provided
# commands: a tool-starved environment must produce a diagnosis, not a cascade of
# "command not found".
sgt_suite_missing_tools() {
  local tool
  local missing=""
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing="${missing:+$missing }$tool"
    fi
  done
  if [[ -z "$missing" ]]; then
    return 0
  fi
  printf '%s\n' "$missing"
  return 1
}

# sgt_suite_require_tools <context> <tool>... — fail the run when a required
# tool is absent, naming every missing tool at once.
sgt_suite_require_tools() {
  local context="$1"
  shift
  local missing=""
  local status=0
  missing="$(sgt_suite_missing_tools "$@")" || status=$?
  if [[ $status -eq 0 ]]; then
    return 0
  fi
  {
    printf '%s: missing required tools: %s\n' "$context" "$missing"
    printf '  These tools are prerequisites of this suite, not optional extras.\n'
    printf '  Skipping the cases that need them would report success while\n'
    printf '  proving nothing, so this run fails instead.\n'
    printf '  Install them, or run the suite in its complete environment:\n'
    printf '    mise run test:docker:drain\n'
    printf '    mise run test:docker:notification\n'
  } >&2
  return 1
}

# sgt_suite_skip <label> <reason-code> [detail] — record a skip, but only for an
# allowlisted reason code.  Any other reason is a failure: an undocumented skip
# is exactly how a vacuous pass looks from the outside.
sgt_suite_skip() {
  local label="$1"
  local code="$2"
  local detail="${3:-}"
  case " $SGT_SUITE_ALLOWED_SKIP_CODES " in
    *" $code "*)
      SGT_SUITE_SKIP=$((SGT_SUITE_SKIP + 1))
      printf '\n  %-12s  %s\n' "[skip]" "$label"
      printf '    documented limitation [%s]: %s\n' "$code" "$detail"
      return 0
      ;;
  esac
  SGT_SUITE_FAIL=$((SGT_SUITE_FAIL + 1))
  {
    printf '\n  %-12s  %s\n' "[FAILED]" "$label"
    printf '    ✗ refused to skip: "%s" is not an allowlisted platform\n' "$code"
    printf '      limitation, so this case counts as a failure.\n'
    printf '      detail: %s\n' "$detail"
    printf '      allowlisted reason codes: %s\n' "$SGT_SUITE_ALLOWED_SKIP_CODES"
  } >&2
  return 1
}

# sgt_suite_require_bash32 <path> — classify the Bash 3.2 binary before any case
# runs.  Empty is a deliberate opt-out; a non-executable path is a broken
# configuration, which used to skip the whole pass in silence.
sgt_suite_require_bash32() {
  local bash32="$1"
  if [[ -z "$bash32" ]]; then
    sgt_suite_skip "Bash 3.2 pass" bash32-pass-not-selected \
      "BASH32 is empty, so this container runs the system-Bash pass only; the Bash 3.2 pass runs in the image built by Dockerfile.bash32"
    return 0
  fi
  if [[ ! -x "$bash32" ]]; then
    {
      printf 'BASH32 is set to "%s", which is not an executable file.\n' "$bash32"
      printf '  A wrong or absent BASH32 used to skip the entire Bash 3.2 pass\n'
      printf '  and still exit 0.  Point BASH32 at a real Bash 3.2 (on macOS:\n'
      printf '  BASH32=/bin/bash), run the dedicated image with\n'
      printf '  `mise run test:docker:drain` / `mise run test:docker:notification`,\n'
      printf '  or set BASH32="" to run the system-Bash pass only.\n'
    } >&2
    return 1
  fi
  return 0
}

# sgt_suite_run <label> <shell> <script> [filter-command...] — execute one case
# and tally the result.  An optional filter command receives the case output on
# stdin (used to drop known-harmless noise) before indentation.
sgt_suite_run() {
  local label="$1"
  local shell="$2"
  local script="$3"
  shift 3
  printf '\n  %-12s  %s\n' "[$shell]" "$label"
  local ok=0
  if [[ $# -gt 0 ]]; then
    if "$shell" "$script" 2>&1 | "$@" | sed 's/^/    /'; then ok=1; fi
  else
    if "$shell" "$script" 2>&1 | sed 's/^/    /'; then ok=1; fi
  fi
  if [[ $ok -eq 1 ]]; then
    printf '    ✓ passed\n'
    sgt_suite_record_pass
    return 0
  fi
  printf '    ✗ FAILED\n' >&2
  sgt_suite_record_fail
  return 0
}

# sgt_suite_verdict — print the canonical Results line and return the run's
# verdict.  A run that executed no case is a failure even with zero failures:
# "0 passed, 0 failed, 9 skipped" is the vacuous pass this library exists to
# stop.
sgt_suite_verdict() {
  printf '\n═══════════════════════════════════════════════════════════\n'
  printf ' Results: %d passed, %d failed, %d skipped\n' \
    "$SGT_SUITE_PASS" "$SGT_SUITE_FAIL" "$SGT_SUITE_SKIP"
  printf '═══════════════════════════════════════════════════════════\n'
  if [[ $SGT_SUITE_FAIL -ne 0 ]]; then
    return 1
  fi
  if [[ $SGT_SUITE_PASS -eq 0 ]]; then
    printf 'FAIL: no test case executed (%d skipped) — a suite that only skips proves nothing\n' \
      "$SGT_SUITE_SKIP" >&2
    return 1
  fi
  return 0
}
