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

[[ -L "$TEST_ROOT/bin/wiki-daily-digest" ]] || {
  printf 'wiki-daily-digest was not installed by mise run install\n' >&2
  exit 1
}
[[ ! -e "$TEST_ROOT/bin/sgt-dispatch" ]] || {
  printf 'v1 script sgt-dispatch was installed by mise run install; v1 is removed on this branch\n' >&2
  exit 1
}
[[ ! -e "$TEST_ROOT/bin/oc-inject" ]]
[[ ! -e "$TEST_ROOT/home/.config/opencode/plugins/oc-inject.js" ]]

[[ -x "$ROOT_DIR/bin/sergeant" ]] || {
  printf 'mise run install did not build bin/sergeant\n' >&2
  exit 1
}

printf 'mise install links wiki-daily-digest and builds sergeant: ok\n'
