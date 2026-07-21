#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=""
REAL_YQ="$(command -v yq)"

setup_fixture() {
  teardown_fixture
  TEST_TMP="$(mktemp -d)"
  export HOME="$TEST_TMP/home"
  export SERGEANT_CONFIG="$HOME/.config/sergeant"
  export SERGEANT_FLEET="$HOME/.local/share/sergeant/fleet"
  export SGT_INSTALL_DIR="$HOME/.local/bin"
  export PATH="$TEST_TMP/bin:$SGT_INSTALL_DIR:/usr/bin:/bin"

  mkdir -p "$TEST_TMP/bin" "$SERGEANT_CONFIG" "$SERGEANT_FLEET" \
    "$SGT_INSTALL_DIR" "$HOME/.config/opencode/skills/fixture" "$HOME/.config/opencode/plugins" \
    "$HOME/.claude/skills/fixture" \
    "$HOME/dev/app"
  printf '%s\n' '# Fixture skill' > "$HOME/.config/opencode/skills/fixture/SKILL.md"
  printf '%s\n' '# Fixture skill' > "$HOME/.claude/skills/fixture/SKILL.md"

  cat > "$SERGEANT_CONFIG/config.yaml" <<EOF
dev_root: $HOME/dev
EOF
  cat > "$SERGEANT_CONFIG/app.yaml" <<'EOF'
name: app
repos:
  - name: app
    path: app
    url: git@github.com:example/app.git
EOF

  git -C "$HOME/dev/app" init -q
  git -C "$HOME/dev/app" remote add origin git@github.com:example/app.git

  for command_name in gh tmux td opencode no-mistakes graphify treehouse mise babydriver; do
    make_fake_command "$command_name"
  done
  ln -s "$REAL_YQ" "$TEST_TMP/bin/yq"

  for script in "$ROOT"/bin/sgt-* "$ROOT"/bin/_sgt-lib.sh \
    "$ROOT"/bin/oc-inject "$ROOT"/bin/wiki-daily-digest; do
    [[ -f "$script" ]] || continue
    ln -s "$script" "$SGT_INSTALL_DIR/$(basename "$script")"
  done
  ln -s "$ROOT/opencode/plugins/oc-inject.js" \
    "$HOME/.config/opencode/plugins/oc-inject.js"
}

make_fake_command() {
  local name="$1"
  cat > "$TEST_TMP/bin/$name" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  --version|-version|version|-V) echo "$name 1.0.0" ;;
  api) echo "fixture-user" ;;
  auth) echo "fixture-user" ;;
  list) echo '[]' ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$TEST_TMP/bin/$name"
}

make_unavailable_command() {
  local name="$1"
  cat > "$TEST_TMP/bin/$name" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
  chmod +x "$TEST_TMP/bin/$name"
}

make_td_without_database() {
  cat > "$TEST_TMP/bin/td" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo "td 1.0.0"
  exit 0
fi
exit 1
EOF
  chmod +x "$TEST_TMP/bin/td"
}

teardown_fixture() {
  if [[ -n "$TEST_TMP" ]]; then
    rm -rf "$TEST_TMP"
    TEST_TMP=""
  fi
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"
}

assert_not_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" != *"$needle"* ]] || fail "expected output not to contain: $needle"
}

assert_eq() {
  local expected="$1" actual="$2"
  [[ "$expected" == "$actual" ]] || fail "expected '$expected', got '$actual'"
}

fixture_digest() {
  if command -v sha256sum >/dev/null 2>&1; then
    tar -C "$HOME" -cf - .config .local dev | sha256sum
  else
    tar -C "$HOME" -cf - .config .local dev | shasum -a 256
  fi
}
