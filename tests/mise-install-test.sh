#!/usr/bin/env bash
# mise-install-test.sh — `mise run install` must delegate to bin/sgt-install and
# produce a working installation whose commands resolve their runtime helpers.

set -euo pipefail

# Physical paths throughout: the manifest resolves link targets physically, so a
# fixture built from a logical path (macOS puts TMPDIR under /var/folders, and
# /var is a symlink to private/var) would never compare equal.
ROOT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$(cd -P "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# Hook resolution reads git configuration, so no fixture may inherit the
# developer's global or system config; otherwise these results depend on the
# machine the suite runs on.
mkdir -p "$TEST_ROOT/git-home" "$TEST_ROOT/git-xdg"
export XDG_CONFIG_HOME="$TEST_ROOT/git-xdg"
export GIT_CONFIG_GLOBAL="$TEST_ROOT/gitconfig-global"
export GIT_CONFIG_SYSTEM="$TEST_ROOT/gitconfig-system"
export GIT_CONFIG_NOSYSTEM=1
unset SGT_INSTALL_DIR
: > "$GIT_CONFIG_GLOBAL"
: > "$GIT_CONFIG_SYSTEM"

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
    ("install:hooks", "./bin/sgt-install --hooks-only"),
    ("uninstall:hooks", "./bin/sgt-uninstall --hooks-only"),
    ("bootstrap", "./bin/sgt-bootstrap"),
    ("verify", "./bin/sgt-bootstrap --verify-only"),
):
    header = "[tasks.%s]" % task if ":" not in task else '[tasks."%s"]' % task
    match = re.search(
        r"^%s$(.*?)(?=^\[tasks|\Z)" % re.escape(header),
        toml,
        re.MULTILINE | re.DOTALL,
    )
    if match is None:
        raise SystemExit("mise.toml is missing %s" % header)
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

# sgt-install and sgt-uninstall write to their own checkout's git hooks
# directory, so the behavioural assertions run against a throwaway copy. Driving
# the real ROOT_DIR would delete the developer's installed pre-push hook as a
# side effect of running the tests.
FIXTURE_ROOT="$TEST_ROOT/checkout"
mkdir -p "$FIXTURE_ROOT"
cp -R "$ROOT_DIR/bin" "$FIXTURE_ROOT/bin"
cp -R "$ROOT_DIR/scripts" "$FIXTURE_ROOT/scripts"
cp -R "$ROOT_DIR/opencode" "$FIXTURE_ROOT/opencode"
cp "$ROOT_DIR/mise.toml" "$FIXTURE_ROOT/mise.toml"
git init -q "$FIXTURE_ROOT"

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/home/.config/opencode/plugins"
ln -s "$FIXTURE_ROOT/bin/oc-inject" "$TEST_ROOT/bin/oc-inject"
ln -s "$FIXTURE_ROOT/opencode/plugins/oc-inject.js" \
  "$TEST_ROOT/home/.config/opencode/plugins/oc-inject.js"

HOME="$TEST_ROOT/home" SGT_INSTALL_DIR="$TEST_ROOT/bin" \
  "$FIXTURE_ROOT/bin/sgt-install" >/dev/null

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
printf 'user command\n' > "$TEST_ROOT/bin/sgt-a-user-command"
HOME="$TEST_ROOT/home" SGT_INSTALL_DIR="$TEST_ROOT/bin" \
  "$FIXTURE_ROOT/bin/sgt-uninstall" >/dev/null

# shellcheck source=bin/_sgt-install-manifest.sh
source "$ROOT_DIR/bin/_sgt-install-manifest.sh"
while IFS= read -r source_file; do
  [[ -n "$source_file" ]] || continue
  residue="$TEST_ROOT/bin/${source_file##*/}"
  [[ ! -e "$residue" && ! -L "$residue" ]] || \
    fail "sgt-uninstall left an installed entry behind: ${source_file##*/}"
done <<EOF
$(_sgt_install_sources "$FIXTURE_ROOT")
EOF
[[ "$(cat "$TEST_ROOT/bin/sgt-a-user-command")" == 'user command' ]] || \
  fail 'sgt-uninstall removed a real user file inside the sgt-* namespace'

# The structural check above only proves the delegation text. Run the real task
# runner when it is available, so a wrong relative path or a renamed key fails.
if command -v mise >/dev/null 2>&1; then
  MISE_ROOT="$TEST_ROOT/mise"
  mkdir -p "$MISE_ROOT/bin" "$MISE_ROOT/home"
  # Run the real task runner against the fixture's own mise.toml, so the task
  # delegation is genuinely executed without touching this checkout.
  HOME="$MISE_ROOT/home" SGT_INSTALL_DIR="$MISE_ROOT/bin" \
    mise run --cd "$FIXTURE_ROOT" install >/dev/null
  [[ -L "$MISE_ROOT/bin/sgt-dispatch" ]] || \
    fail 'mise run install did not create the command links'
  [[ -L "$MISE_ROOT/bin/_sgt-install-manifest.sh" ]] || \
    fail 'mise run install did not link the install manifest'
  HOME="$MISE_ROOT/home" SGT_INSTALL_DIR="$MISE_ROOT/bin" \
    mise run --cd "$FIXTURE_ROOT" uninstall >/dev/null
  [[ ! -e "$MISE_ROOT/bin/sgt-dispatch" ]] || \
    fail 'mise run uninstall left a command link behind'
  printf 'mise run install/uninstall via the real task runner: ok\n'
else
  printf 'SKIP: mise run install/uninstall (mise is not available on this host)\n'
fi

printf 'mise install/uninstall round-trip: ok\n'

# --hooks-only is the seam mise run install:hooks delegates to, so it must
# install the hook and leave the command links alone.
HOOKS_BIN="$TEST_ROOT/hooks-only-bin"
mkdir -p "$HOOKS_BIN"
HOME="$TEST_ROOT/home" SGT_INSTALL_DIR="$HOOKS_BIN" \
  "$FIXTURE_ROOT/bin/sgt-install" --hooks-only >/dev/null
[[ "$(readlink "$FIXTURE_ROOT/.git/hooks/pre-push")" == "$FIXTURE_ROOT/scripts/hooks/pre-push" ]] || \
  fail 'sgt-install --hooks-only did not install the git hook'
[[ -z "$(ls -A "$HOOKS_BIN")" ]] || \
  fail 'sgt-install --hooks-only created command links'
HOME="$TEST_ROOT/home" SGT_INSTALL_DIR="$HOOKS_BIN" \
  "$FIXTURE_ROOT/bin/sgt-uninstall" --hooks-only >/dev/null
[[ ! -e "$FIXTURE_ROOT/.git/hooks/pre-push" ]] || \
  fail 'sgt-uninstall --hooks-only did not remove the git hook'

printf 'hooks-only install/uninstall seam: ok\n'
