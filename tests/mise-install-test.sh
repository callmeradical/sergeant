#!/usr/bin/env bash
# mise-install-test.sh — `mise run install` must delegate to bin/sgt-install and
# produce a working installation whose commands resolve their runtime helpers.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

# The install task must delegate rather than carry a second copy of the link
# logic; bin/sgt-install is the seam bin/sgt-bootstrap also drives.
python3 - "$ROOT_DIR/mise.toml" <<'PY'
import re
import sys

with open(sys.argv[1], encoding="utf-8") as toml_file:
    toml = toml_file.read()

for task, expected in (
    ("install", "./bin/sgt-install"),
    ("uninstall", "./bin/sgt-uninstall"),
    ("bootstrap", "./bin/sgt-bootstrap"),
    ("verify", "./bin/sgt-bootstrap --verify-only"),
):
    match = re.search(
        r"^\[tasks\.%s\]$(.*?)(?=^\[tasks|\Z)" % re.escape(task),
        toml,
        re.MULTILINE | re.DOTALL,
    )
    if match is None:
        raise SystemExit("mise.toml is missing [tasks.%s]" % task)
    body = match.group(1)
    if 'run = "%s"' % expected not in body:
        raise SystemExit(
            "mise.toml [tasks.%s] must delegate with run = \"%s\"" % (task, expected)
        )
    if '"""' in body:
        raise SystemExit(
            "mise.toml [tasks.%s] must not inline a script; delegate instead" % task
        )
PY

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/home/.config/opencode/plugins"
# Create stale oc-inject symlinks to verify mise install removes them.
# These reference paths that no longer exist in the repo (deleted in GH #179).
ln -s "/tmp/nonexistent/oc-inject" "$TEST_ROOT/bin/oc-inject"
ln -s "/tmp/nonexistent/oc-inject.js" \
  "$TEST_ROOT/home/.config/opencode/plugins/oc-inject.js"

HOME="$TEST_ROOT/home" SGT_INSTALL_DIR="$TEST_ROOT/bin" \
  "$ROOT_DIR/bin/sgt-install" >/dev/null

[[ -L "$TEST_ROOT/bin/sgt-dispatch" ]] || fail 'sgt-dispatch was not installed'
[[ -L "$TEST_ROOT/bin/sgt-review-findings" ]] || \
  fail 'sgt-review-findings was not installed by mise run install (#97)'

set +e
rf_output="$(HOME="$TEST_ROOT/home" "$TEST_ROOT/bin/sgt-review-findings" 2>&1)"
rf_status=$?
set -e
[[ "$rf_status" -ne 0 && "$rf_output" == *'Usage: sgt-review-findings'* ]] || \
  fail "$(printf 'sgt-review-findings from installed path did not print usage (#97): status=%s output=%s' \
    "$rf_status" "$rf_output")"

# Every sourced helper must be installed, or an installed sgt-* script fails at
# its source line. Enumerating helpers by name has broken this before, so assert
# over the checkout's glob rather than a hardcoded list.
for helper in "$ROOT_DIR"/bin/_sgt-*.sh; do
  [[ -L "$TEST_ROOT/bin/${helper##*/}" ]] || \
    fail "runtime helper was not installed: ${helper##*/}"
done

# oc-inject is deprecated: its links are removed and never recreated.
[[ ! -e "$TEST_ROOT/bin/oc-inject" ]] || fail 'deprecated oc-inject link was not removed'
[[ ! -e "$TEST_ROOT/home/.config/opencode/plugins/oc-inject.js" ]] || \
  fail 'deprecated oc-inject plugin link was not removed'

set +e
output="$(HOME="$TEST_ROOT/home" "$TEST_ROOT/bin/sgt-dispatch" 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *'Usage: sgt-dispatch'* ]] || \
  fail 'installed sgt-dispatch did not print usage'
[[ "$output" != *'_sgt-intent.sh: No such file'* ]] || fail 'installed sgt-dispatch lost _sgt-intent.sh'
[[ "$output" != *'_sgt-drain.sh: No such file'* ]] || fail 'installed sgt-dispatch lost _sgt-drain.sh'

# Uninstall must be the exact inverse of install: every entry install created is
# removed, and a user's own file of the same name is left alone.
printf 'user command\n' > "$TEST_ROOT/bin/sgt-a-user-command"
HOME="$TEST_ROOT/home" SGT_INSTALL_DIR="$TEST_ROOT/bin" \
  "$ROOT_DIR/bin/sgt-uninstall" >/dev/null

# shellcheck source=bin/_sgt-install-manifest.sh
source "$ROOT_DIR/bin/_sgt-install-manifest.sh"
while IFS= read -r source_file; do
  [[ -n "$source_file" ]] || continue
  residue="$TEST_ROOT/bin/${source_file##*/}"
  [[ ! -e "$residue" && ! -L "$residue" ]] || \
    fail "sgt-uninstall left an installed entry behind: ${source_file##*/}"
done <<EOF
$(_sgt_install_sources "$ROOT_DIR")
EOF
[[ "$(cat "$TEST_ROOT/bin/sgt-a-user-command")" == 'user command' ]] || \
  fail 'sgt-uninstall removed a real user file inside the sgt-* namespace'

# The structural check above only proves the delegation text. Run the real task
# runner when it is available, so a wrong relative path or a renamed key fails.
if command -v mise >/dev/null 2>&1; then
  MISE_ROOT="$TEST_ROOT/mise"
  mkdir -p "$MISE_ROOT/bin" "$MISE_ROOT/home"
  ( cd "$ROOT_DIR" && HOME="$MISE_ROOT/home" SGT_INSTALL_DIR="$MISE_ROOT/bin" \
      mise run install >/dev/null )
  [[ -L "$MISE_ROOT/bin/sgt-dispatch" ]] || \
    fail 'mise run install did not create the command links'
  [[ -L "$MISE_ROOT/bin/_sgt-install-manifest.sh" ]] || \
    fail 'mise run install did not link the install manifest'
  ( cd "$ROOT_DIR" && HOME="$MISE_ROOT/home" SGT_INSTALL_DIR="$MISE_ROOT/bin" \
      mise run uninstall >/dev/null )
  [[ ! -e "$MISE_ROOT/bin/sgt-dispatch" ]] || \
    fail 'mise run uninstall left a command link behind'
  printf 'mise run install/uninstall via the real task runner: ok\n'
else
  printf 'SKIP: mise run install/uninstall (mise is not available on this host)\n'
fi

printf 'mise install/uninstall round-trip: ok\n'
