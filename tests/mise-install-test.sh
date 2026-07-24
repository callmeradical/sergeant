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

HOME="$TEST_ROOT/home" MISE_PROJECT_ROOT="$ROOT_DIR" \
  MISE_ORIGINAL_CWD="$ROOT_DIR" SGT_INSTALL_DIR="$TEST_ROOT/bin" \
  bash "$TEST_ROOT/install.sh" >/dev/null

[[ -L "$TEST_ROOT/bin/sgt-dispatch" ]]
[[ -L "$TEST_ROOT/bin/_sgt-intent.sh" ]]

set +e
output="$(HOME="$TEST_ROOT/home" "$TEST_ROOT/bin/sgt-dispatch" 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *'Usage: sgt-dispatch'* ]]
[[ "$output" != *'_sgt-intent.sh: No such file'* ]]

printf 'mise install links runtime helpers: ok\n'
