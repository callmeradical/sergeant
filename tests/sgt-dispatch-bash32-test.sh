#!/usr/bin/env bash
# Regression: every shipped script must parse under Bash 3.2, and sgt-dispatch
# must not use inline complex alternation patterns in =~ constructs.
#
# Apple's Bash 3.2.57 (the macOS system default) raises a runtime error when
# the right-hand side of [[ str =~ pattern ]] contains an inline alternation
# group such as ^(feat|fix|chore)-. The portable fix is to store the regex in
# a variable first: re='^(feat|fix|chore)-'; [[ str =~ $re ]].
#
# This test:
#  1. Requires a Bash 3.2 binary (SGT_MINIMUM_BASH env var or /bin/bash).
#  2. Runs bash -n on every shipped bin/ script to check for parse errors.
#  3. Checks that sgt-dispatch contains no inline complex alternation patterns
#     in =~ constructs (the original expression that failed on macOS Bash 3.2).
#  4. Behaviorally exercises the dispatch branch-name logic under Bash 3.2
#     to confirm the variable-based form produces correct output.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

minimum_bash="${SGT_MINIMUM_BASH:-/bin/bash}"
# shellcheck disable=SC2016
version="$("$minimum_bash" -c 'printf "%s.%s\n" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"')"
if [[ "$version" != "3.2" ]]; then
  # Bash 3.2 not available natively.  Re-exec this test inside Docker using the
  # pinned bash:3.2 image when Docker is available.
  _bash32_image="docker.io/library/bash:3.2@sha256:3a13e5da38baa575985778cd09ce8ac736d4b4dafc91a430e71271f6e5311b89"
  if command -v docker >/dev/null 2>&1 && \
     docker image inspect "$_bash32_image" >/dev/null 2>&1; then
    exec docker run --rm \
      -v "$ROOT_DIR:$ROOT_DIR:ro" \
      -e "SGT_MINIMUM_BASH=/usr/local/bin/bash" \
      "$_bash32_image" \
      bash "$ROOT_DIR/tests/sgt-dispatch-bash32-test.sh" "$@"
  fi
  printf 'Bash 3.2 dispatch regression requires Bash 3.2, found %s at %s\n' \
    "$version" "$minimum_bash" >&2
  printf 'Install Bash 3.2 or set SGT_MINIMUM_BASH; see docs/troubleshooting.md\n' >&2
  exit 1
fi

# ── 1. bash -n parse check for all shipped scripts ───────────────────────────
parse_fail=0
for f in \
    "$ROOT_DIR"/bin/sgt-* \
    "$ROOT_DIR"/bin/wiki-daily-digest \
    "$ROOT_DIR"/bin/_sgt-*.sh; do
  [[ -f "$f" ]] || continue
  result=$("$minimum_bash" -n "$f" 2>&1) || {
    printf 'FAIL (parse error under Bash 3.2 in %s):\n  %s\n' "$f" "$result" >&2
    parse_fail=1
  }
done
[[ "$parse_fail" -eq 0 ]] || exit 1

# ── 2. Static check: no inline complex alternation in =~ constructs ───────────
# An inline complex alternation looks like:  =~ SOMETHING(X|Y)MORE
# where the alternation group is not behind a $ variable reference.
# Use grep (not bash =~) to avoid the same portability issue in this test.
# Exclude comment lines (those starting with optional whitespace then #).
# Pattern: find =~ followed by content containing ( then non-)$ chars then |
# Check every shipped script — the spec requires "every shipped bin script".
inline_fail=0
for f in \
    "$ROOT_DIR"/bin/sgt-* \
    "$ROOT_DIR"/bin/wiki-daily-digest \
    "$ROOT_DIR"/bin/_sgt-*.sh; do
  [[ -f "$f" ]] || continue
  if grep -vE '^[[:space:]]*#' "$f" 2>/dev/null | \
     grep -qE '=~[^#$]*([(][^)$]*\|)'; then
    printf 'FAIL: %s contains inline complex alternation in =~ (not portable to macOS Bash 3.2):\n' \
      "$(basename "$f")" >&2
    grep -vE '^[[:space:]]*#' "$f" | grep -nE '=~[^#$]*([(][^)$]*\|)' >&2 || true
    inline_fail=1
  fi
done
if [[ "$inline_fail" -ne 0 ]]; then
  printf '  Fix: store complex regex in a variable before using =~\n' >&2
  exit 1
fi

# ── 3. Behavioral: dispatch branch-name logic under Bash 3.2 ─────────────────
result=$("$minimum_bash" <<'BASH32'
set -e
pass=0
fail=0

check() {
  local bslug="$1"
  local expected="$2"
  # Variable-based form required for macOS Bash 3.2 compatibility
  local _re
  _re='^(feat|fix|chore|refactor|docs|test)-'
  local branch
  if [[ "$bslug" =~ $_re ]]; then
    branch="${bslug/-//}"
  else
    branch="feat/$bslug"
  fi
  if [[ "$branch" = "$expected" ]]; then
    pass=$((pass + 1))
  else
    printf 'FAIL: slug=%s got=%s want=%s\n' "$bslug" "$branch" "$expected" >&2
    fail=$((fail + 1))
  fi
}

check "feat-add-oauth"        "feat/add-oauth"
check "fix-bug-in-dispatch"   "fix/bug-in-dispatch"
check "chore-cleanup"         "chore/cleanup"
check "refactor-core-loop"    "refactor/core-loop"
check "docs-update-readme"    "docs/update-readme"
check "test-response-lock"    "test/response-lock"
check "add-new-feature"       "feat/add-new-feature"
check "update-deps"           "feat/update-deps"
check "my-custom-slug"        "feat/my-custom-slug"

if [[ "$fail" -eq 0 ]]; then
  printf 'branch-name generation: %d cases ok\n' "$pass"
else
  exit 1
fi
BASH32
)

if [[ "$result" != *"branch-name generation:"* ]]; then
  printf 'Branch-name generation failed under Bash 3.2:\n%s\n' "$result" >&2
  exit 1
fi

printf 'sgt-dispatch Bash 3.2 regression: ok\n'
