#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

awk '
  /^\[tasks\.install\]$/ { in_task=1; next }
  in_task && /^run = """$/ { in_run=1; next }
  in_run && /^"""$/ { exit }
  in_run { print }
' "$ROOT_DIR/mise.toml" > "$TEST_ROOT/install.sh"
chmod +x "$TEST_ROOT/install.sh"

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/home/.config/opencode/plugins"
# Create stale oc-inject symlinks to verify mise install removes them.
# These reference paths that no longer exist in the repo (deleted in GH #179).
ln -s "/tmp/nonexistent/oc-inject" "$TEST_ROOT/bin/oc-inject"
ln -s "/tmp/nonexistent/oc-inject.js" \
  "$TEST_ROOT/home/.config/opencode/plugins/oc-inject.js"

HOME="$TEST_ROOT/home" MISE_PROJECT_ROOT="$ROOT_DIR" \
  MISE_ORIGINAL_CWD="$ROOT_DIR" SGT_INSTALL_DIR="$TEST_ROOT/bin" \
  bash "$TEST_ROOT/install.sh" >/dev/null

[[ -L "$TEST_ROOT/bin/sgt-dispatch" ]]
[[ -L "$TEST_ROOT/bin/sgt-review-findings" ]] || {
  printf 'sgt-review-findings was not installed by mise run install (#97)\n' >&2
  exit 1
}
set +e
rf_output="$(HOME="$TEST_ROOT/home" "$TEST_ROOT/bin/sgt-review-findings" 2>&1)"
rf_status=$?
set -e
[[ "$rf_status" -ne 0 && "$rf_output" == *'Usage: sgt-review-findings'* ]] || {
  printf 'sgt-review-findings from installed path did not print usage (#97): status=%s output=%s\n' \
    "$rf_status" "$rf_output" >&2
  exit 1
}
[[ -L "$TEST_ROOT/bin/_sgt-intent.sh" ]]
[[ -L "$TEST_ROOT/bin/_sgt-drain.sh" ]]
# Every sourced helper must be installed, or an installed sgt-* script fails at
# its source line. Enumerating helpers by name has broken this before.
for helper in "$ROOT_DIR"/bin/_sgt-*.sh; do
  [[ -L "$TEST_ROOT/bin/$(basename "$helper")" ]] || {
    printf 'runtime helper was not installed: %s\n' "$(basename "$helper")" >&2
    exit 1
  }
done
[[ ! -e "$TEST_ROOT/bin/oc-inject" ]]
[[ ! -e "$TEST_ROOT/home/.config/opencode/plugins/oc-inject.js" ]]

set +e
output="$(HOME="$TEST_ROOT/home" "$TEST_ROOT/bin/sgt-dispatch" 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *'Usage: sgt-dispatch'* ]]
[[ "$output" != *'_sgt-intent.sh: No such file'* ]]
[[ "$output" != *'_sgt-drain.sh: No such file'* ]]

printf 'mise install links runtime helpers: ok\n'
