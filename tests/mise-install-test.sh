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
ln -s "$ROOT_DIR/bin/oc-inject" "$TEST_ROOT/bin/oc-inject"
ln -s "$ROOT_DIR/opencode/plugins/oc-inject.js" \
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

for helper in _sgt-lib.sh _sgt-bash-version.sh _sgt-intent.sh _sgt-drain.sh \
              _sgt-response-lock.sh _sgt-install-manifest.sh; do
  [[ -L "$TEST_ROOT/bin/$helper" ]] || fail "runtime helper was not installed: $helper"
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
printf 'user command\n' > "$TEST_ROOT/bin/sgt-not-ours"
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
[[ "$(cat "$TEST_ROOT/bin/sgt-not-ours")" == 'user command' ]] || \
  fail 'sgt-uninstall removed a command it does not own'

printf 'mise install/uninstall round-trip: ok\n'
