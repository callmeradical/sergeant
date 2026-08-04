#!/usr/bin/env bash
# sgt-install-manifest-test.sh — Unit behavior of the shared install manifest.
#
# The manifest is the single decision point for what this checkout installs and
# for whether a path in the target directory may be repointed or must be
# preserved. bin/sgt-install, bin/sgt-uninstall and bin/sgt-bootstrap all route
# through it, so a plan and the action it predicts cannot diverge.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# shellcheck source=bin/_sgt-install-manifest.sh
source "$ROOT_DIR/bin/_sgt-install-manifest.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_state() {
  local source_file="$1" target_dir="$2" expected="$3" actual
  actual="$(_sgt_install_link_state "$source_file" "$target_dir")"
  [[ "$actual" == "$expected" ]] || \
    fail "expected link state '$expected' for ${source_file##*/}, got '$actual'"
}

# A second checkout, so "another Sergeant clone" is a real path and not a guess.
OTHER_ROOT="$TEST_ROOT/other-checkout"
mkdir -p "$OTHER_ROOT/bin"
cp "$ROOT_DIR/bin/_sgt-install-manifest.sh" "$OTHER_ROOT/bin/"
printf '#!/usr/bin/env bash\n' > "$OTHER_ROOT/bin/sgt-list"

SOURCE="$ROOT_DIR/bin/sgt-list"

# ── _sgt_install_sources ──────────────────────────────────────────────────────

test_sources_include_commands_and_helpers() {
  local sources
  sources="$(_sgt_install_sources "$ROOT_DIR")"
  [[ "$sources" == *"$ROOT_DIR/bin/sgt-dispatch"* ]] || fail 'sources omit sgt-dispatch'
  [[ "$sources" == *"$ROOT_DIR/bin/_sgt-lib.sh"* ]] || fail 'sources omit _sgt-lib.sh'
  [[ "$sources" == *"$ROOT_DIR/bin/_sgt-install-manifest.sh"* ]] || fail 'sources omit the manifest'
  [[ "$sources" == *"$ROOT_DIR/bin/wiki-daily-digest"* ]] || fail 'sources omit wiki-daily-digest'
  [[ "$sources" != *"/bin/oc-inject"* ]] || fail 'sources include the deprecated oc-inject'
  [[ "$sources" != *'__pycache__'* ]] || fail 'sources include a non-regular entry'
}

# A root that resolves to nothing must be a hard error, not a silent empty plan
# that lets a caller report a complete installation having checked nothing.
test_empty_manifest_is_a_hard_error() {
  local status output
  mkdir -p "$TEST_ROOT/emptyroot"
  set +e
  output="$(_sgt_install_sources "$TEST_ROOT/emptyroot" 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail '_sgt_install_sources succeeded with zero entries'
  [[ "$output" == *"$TEST_ROOT/emptyroot"* ]] || \
    fail 'empty-manifest error does not name the resolved root'
}

# ── _sgt_install_link_state ───────────────────────────────────────────────────

test_absent_target_is_absent() {
  mkdir -p "$TEST_ROOT/s1"
  assert_state "$SOURCE" "$TEST_ROOT/s1" absent
}

test_exact_link_is_linked() {
  mkdir -p "$TEST_ROOT/s2"
  ln -s "$SOURCE" "$TEST_ROOT/s2/sgt-list"
  assert_state "$SOURCE" "$TEST_ROOT/s2" linked
}

test_link_into_another_sergeant_checkout_is_stale() {
  mkdir -p "$TEST_ROOT/s3"
  ln -s "$OTHER_ROOT/bin/sgt-list" "$TEST_ROOT/s3/sgt-list"
  assert_state "$SOURCE" "$TEST_ROOT/s3" stale
}

test_dangling_link_is_stale() {
  mkdir -p "$TEST_ROOT/s4"
  ln -s "$TEST_ROOT/gone/bin/sgt-list" "$TEST_ROOT/s4/sgt-list"
  assert_state "$SOURCE" "$TEST_ROOT/s4" stale
}

test_real_file_is_a_conflict() {
  mkdir -p "$TEST_ROOT/s5"
  printf 'user command\n' > "$TEST_ROOT/s5/sgt-list"
  assert_state "$SOURCE" "$TEST_ROOT/s5" conflict
}

# A user's own command reached through a symlink is not Sergeant's to repoint,
# even at a name inside the sgt-* namespace.
test_link_to_a_users_own_command_is_a_conflict() {
  mkdir -p "$TEST_ROOT/s6" "$TEST_ROOT/mine"
  printf 'user command\n' > "$TEST_ROOT/mine/sgt-list"
  ln -s "$TEST_ROOT/mine/sgt-list" "$TEST_ROOT/s6/sgt-list"
  assert_state "$SOURCE" "$TEST_ROOT/s6" conflict
}

# wiki-daily-digest is outside the sgt-* namespace, so a user is especially
# likely to own it. It must be preserved, not silently hijacked.
test_link_to_a_users_own_wiki_daily_digest_is_a_conflict() {
  mkdir -p "$TEST_ROOT/s7" "$TEST_ROOT/mine7"
  printf 'user digest\n' > "$TEST_ROOT/mine7/wiki-daily-digest"
  ln -s "$TEST_ROOT/mine7/wiki-daily-digest" "$TEST_ROOT/s7/wiki-daily-digest"
  assert_state "$ROOT_DIR/bin/wiki-daily-digest" "$TEST_ROOT/s7" conflict
}

test_directory_at_target_is_a_conflict() {
  mkdir -p "$TEST_ROOT/s8/sgt-list"
  assert_state "$SOURCE" "$TEST_ROOT/s8" conflict
}

# ln -sf would follow this symlink and write inside the directory instead of
# replacing the link, so the state must be classified, never blindly forced.
test_link_to_a_directory_is_a_conflict() {
  mkdir -p "$TEST_ROOT/s9" "$TEST_ROOT/victim"
  ln -s "$TEST_ROOT/victim" "$TEST_ROOT/s9/sgt-list"
  assert_state "$SOURCE" "$TEST_ROOT/s9" conflict
}

# ── _sgt_command_available ────────────────────────────────────────────────────

# `command -v` reports success for a non-executable file on PATH, which would
# make a broken tool look installed and skip its conflict handling.
test_non_executable_file_on_path_is_not_available() {
  mkdir -p "$TEST_ROOT/p1"
  printf 'junk\n' > "$TEST_ROOT/p1/faketool"
  chmod 644 "$TEST_ROOT/p1/faketool"
  if PATH="$TEST_ROOT/p1:$PATH" _sgt_command_available faketool; then
    fail 'a non-executable file on PATH was reported as available'
  fi
}

test_executable_on_path_is_available() {
  mkdir -p "$TEST_ROOT/p2"
  printf '#!/usr/bin/env bash\n' > "$TEST_ROOT/p2/realtool"
  chmod 755 "$TEST_ROOT/p2/realtool"
  PATH="$TEST_ROOT/p2:$PATH" _sgt_command_available realtool || \
    fail 'an executable on PATH was reported as unavailable'
}

test_dangling_link_on_path_is_not_available() {
  mkdir -p "$TEST_ROOT/p3"
  ln -s "$TEST_ROOT/nope/tool" "$TEST_ROOT/p3/danglingtool"
  if PATH="$TEST_ROOT/p3:$PATH" _sgt_command_available danglingtool; then
    fail 'a dangling link on PATH was reported as available'
  fi
}

# ── _sgt_install_script_root ──────────────────────────────────────────────────

test_script_root_follows_a_symlink_chain() {
  local resolved
  mkdir -p "$TEST_ROOT/l1" "$TEST_ROOT/l2"
  ln -s "$ROOT_DIR/bin/sgt-install" "$TEST_ROOT/l1/sgt-install"
  ln -s "$TEST_ROOT/l1/sgt-install" "$TEST_ROOT/l2/sgt-install"
  resolved="$(_sgt_install_script_root "$TEST_ROOT/l2/sgt-install")"
  [[ "$resolved" == "$ROOT_DIR" ]] || \
    fail "script root through a two-hop chain resolved to '$resolved'"
}

test_script_root_follows_a_relative_symlink() {
  local resolved
  mkdir -p "$TEST_ROOT/rel/bin" "$TEST_ROOT/rel/link"
  printf '#!/usr/bin/env bash\n' > "$TEST_ROOT/rel/bin/sgt-install"
  ln -s '../bin/sgt-install' "$TEST_ROOT/rel/link/sgt-install"
  resolved="$(_sgt_install_script_root "$TEST_ROOT/rel/link/sgt-install")"
  [[ "$resolved" == "$TEST_ROOT/rel" ]] || \
    fail "script root through a relative symlink resolved to '$resolved'"
}

test_script_root_reports_a_symlink_loop() {
  local status output
  mkdir -p "$TEST_ROOT/loop"
  ln -s "$TEST_ROOT/loop/b" "$TEST_ROOT/loop/a"
  ln -s "$TEST_ROOT/loop/a" "$TEST_ROOT/loop/b"
  set +e
  output="$(_sgt_install_script_root "$TEST_ROOT/loop/a" 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail 'a symlink loop did not fail'
  [[ "$output" == *'symlink loop'* ]] || fail 'symlink loop error is not actionable'
}

test_sources_include_commands_and_helpers
test_empty_manifest_is_a_hard_error
test_absent_target_is_absent
test_exact_link_is_linked
test_link_into_another_sergeant_checkout_is_stale
test_dangling_link_is_stale
test_real_file_is_a_conflict
test_link_to_a_users_own_command_is_a_conflict
test_link_to_a_users_own_wiki_daily_digest_is_a_conflict
test_directory_at_target_is_a_conflict
test_link_to_a_directory_is_a_conflict
test_non_executable_file_on_path_is_not_available
test_executable_on_path_is_available
test_dangling_link_on_path_is_not_available
test_script_root_follows_a_symlink_chain
test_script_root_follows_a_relative_symlink
test_script_root_reports_a_symlink_loop

printf 'install manifest behavior: ok\n'
