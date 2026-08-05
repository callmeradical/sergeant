#!/usr/bin/env bash
# sgt-install-manifest-test.sh — Unit behavior of the shared install manifest.
#
# The manifest is the single decision point for what this checkout installs and
# for whether a path in the target directory may be repointed or must be
# preserved. bin/sgt-install, bin/sgt-uninstall and bin/sgt-bootstrap all route
# through it, so a plan and the action it predicts cannot diverge.

set -euo pipefail

# Physical paths throughout: the manifest resolves link targets physically, so a
# fixture built from a logical path (macOS puts TMPDIR under /var/folders, and
# /var is a symlink to private/var) would never compare equal.
ROOT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$(cd -P "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# Hook resolution reads git configuration, so the fixtures must not inherit the
# developer's global or system config; otherwise the result of this suite depends
# on the machine it runs on.
mkdir -p "$TEST_ROOT/home" "$TEST_ROOT/xdg"
export HOME="$TEST_ROOT/home"
export XDG_CONFIG_HOME="$TEST_ROOT/xdg"
export GIT_CONFIG_GLOBAL="$TEST_ROOT/gitconfig-global"
export GIT_CONFIG_SYSTEM="$TEST_ROOT/gitconfig-system"
export GIT_CONFIG_NOSYSTEM=1
: > "$GIT_CONFIG_GLOBAL"
: > "$GIT_CONFIG_SYSTEM"

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

# A relative link target must be resolved against the directory holding the
# link, never against the caller's working directory.
test_relative_link_to_a_users_own_command_is_a_conflict() {
  mkdir -p "$TEST_ROOT/s10/bin" "$TEST_ROOT/s10/mine"
  printf 'user command\n' > "$TEST_ROOT/s10/mine/sgt-list"
  ln -s '../mine/sgt-list' "$TEST_ROOT/s10/bin/sgt-list"
  assert_state "$SOURCE" "$TEST_ROOT/s10/bin" conflict
}

# A checkout predating this manifest is still Sergeant's, so an upgrade must not
# report Sergeant's own links to the user as their assets.
test_link_into_a_legacy_sergeant_checkout_is_stale() {
  mkdir -p "$TEST_ROOT/s11" "$TEST_ROOT/legacy/bin"
  cp "$ROOT_DIR/bin/_sgt-lib.sh" "$TEST_ROOT/legacy/bin/"
  printf '#!/usr/bin/env bash\n' > "$TEST_ROOT/legacy/bin/sgt-list"
  ln -s "$TEST_ROOT/legacy/bin/sgt-list" "$TEST_ROOT/s11/sgt-list"
  assert_state "$SOURCE" "$TEST_ROOT/s11" stale
}

# Logical `cd`/`pwd` collapse `..` lexically and leave a symlinked parent
# unresolved, yielding a path the kernel would never follow. With the install
# directory itself a symlink and a logical sibling present, a user's relative
# link must still be recognised as theirs.
test_relative_link_resolves_physically_through_a_symlinked_parent() {
  local resolved expected
  mkdir -p "$TEST_ROOT/phys/opt/bin" "$TEST_ROOT/phys/opt/mine" "$TEST_ROOT/phys/logical/mine"
  ln -s ../opt/bin "$TEST_ROOT/phys/logical/bin"
  printf '#!/bin/sh\n' > "$TEST_ROOT/phys/opt/mine/sgt-list"
  ln -s ../mine/sgt-list "$TEST_ROOT/phys/logical/bin/sgt-list"

  expected="$TEST_ROOT/phys/opt/mine/sgt-list"
  resolved="$(_sgt_install_resolve_link "$TEST_ROOT/phys/logical/bin/sgt-list")"
  [[ "$resolved" == "$expected" ]] || \
    fail "resolved '$resolved' instead of the physical target '$expected'"
  assert_state "$SOURCE" "$TEST_ROOT/phys/logical/bin" conflict
}

# ── _sgt_install_managed_state ────────────────────────────────────────────────

assert_managed_state() {
  local target="$1" expected="$2" actual
  actual="$(_sgt_install_managed_state "$target" '/mise/')"
  [[ "$actual" == "$expected" ]] || \
    fail "expected managed state '$expected' for $target, got '$actual'"
}

test_managed_absent_target_is_absent() {
  mkdir -p "$TEST_ROOT/m1"
  assert_managed_state "$TEST_ROOT/m1/uv" absent
}

test_managed_dangling_link_is_reclaimable() {
  mkdir -p "$TEST_ROOT/m2"
  ln -s "$TEST_ROOT/gone/uv" "$TEST_ROOT/m2/uv"
  assert_managed_state "$TEST_ROOT/m2/uv" reclaim
}

test_managed_link_into_the_mise_tree_is_reclaimable() {
  mkdir -p "$TEST_ROOT/m3" "$TEST_ROOT/mise/installs/uv/1.0/bin"
  printf '#!/usr/bin/env bash\n' > "$TEST_ROOT/mise/installs/uv/1.0/bin/uv"
  ln -s "$TEST_ROOT/mise/installs/uv/1.0/bin/uv" "$TEST_ROOT/m3/uv"
  assert_managed_state "$TEST_ROOT/m3/uv" reclaim
}

test_managed_real_file_is_a_conflict() {
  mkdir -p "$TEST_ROOT/m4"
  printf 'not really uv\n' > "$TEST_ROOT/m4/uv"
  assert_managed_state "$TEST_ROOT/m4/uv" conflict
}

# The defect this guards: an unresolved relative target is tested against the
# caller's cwd, looks dangling, and is deleted.
test_managed_relative_link_to_a_users_own_tool_is_a_conflict() {
  mkdir -p "$TEST_ROOT/m5/bin" "$TEST_ROOT/m5/mine"
  printf '#!/usr/bin/env bash\n' > "$TEST_ROOT/m5/mine/uv"
  chmod +x "$TEST_ROOT/m5/mine/uv"
  ln -s '../mine/uv' "$TEST_ROOT/m5/bin/uv"
  assert_managed_state "$TEST_ROOT/m5/bin/uv" conflict
}

# ── _sgt_install_hooks_dir ────────────────────────────────────────────────────

test_hooks_dir_is_absolute_for_a_plain_clone() {
  local resolved
  command -v git >/dev/null 2>&1 || { printf 'SKIP: hooks dir (no git)\n'; return 0; }
  git init -q "$TEST_ROOT/h1"
  resolved="$(_sgt_install_hooks_dir "$TEST_ROOT/h1")"
  [[ "$resolved" == /* ]] || fail "hooks dir is not absolute: $resolved"
  [[ "$resolved" == "$TEST_ROOT/h1/.git/hooks" ]] || fail "unexpected hooks dir: $resolved"
}

# A linked worktree's private git dir has no hooks/ and git never reads one
# there, so the common directory is the only correct answer.
test_hooks_dir_resolves_to_the_common_dir_for_a_worktree() {
  local resolved
  command -v git >/dev/null 2>&1 || { printf 'SKIP: worktree hooks dir (no git)\n'; return 0; }
  git init -q "$TEST_ROOT/h2"
  ( cd "$TEST_ROOT/h2" &&     git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init &&     git worktree add -q "$TEST_ROOT/h2wt" -b wt ) >/dev/null 2>&1
  resolved="$(_sgt_install_hooks_dir "$TEST_ROOT/h2wt")"
  [[ "$resolved" == "$TEST_ROOT/h2/.git/hooks" ]] || \
    fail "worktree hooks dir resolved to '$resolved' instead of the common dir"
}

test_hooks_dir_honours_a_repo_local_core_hooks_path() {
  local resolved
  command -v git >/dev/null 2>&1 || { printf 'SKIP: core.hooksPath (no git)\n'; return 0; }
  git init -q "$TEST_ROOT/h3"
  git -C "$TEST_ROOT/h3" config --local core.hooksPath .githooks
  resolved="$(_sgt_install_hooks_dir "$TEST_ROOT/h3")"
  [[ "$resolved" == "$TEST_ROOT/h3/.githooks" ]] || \
    fail "a repo-local core.hooksPath was ignored: $resolved"
}

# A global hooksPath belongs to every repository on the machine. Installing
# Sergeant's pre-push hook there would make every unrelated push run Sergeant's
# Docker drain suite, so there is nothing here Sergeant may own.
test_hooks_dir_refuses_a_global_core_hooks_path() {
  local status
  command -v git >/dev/null 2>&1 || { printf 'SKIP: global core.hooksPath (no git)\n'; return 0; }
  git init -q "$TEST_ROOT/h4"
  printf '[core]\n\thooksPath = %s\n' "$TEST_ROOT/global-hooks" > "$GIT_CONFIG_GLOBAL"
  set +e
  _sgt_install_hooks_dir "$TEST_ROOT/h4" >/dev/null
  status=$?
  set -e
  : > "$GIT_CONFIG_GLOBAL"
  [[ "$status" -ne 0 ]] || fail 'a global core.hooksPath was accepted as a Sergeant hooks directory'
}

# A repo-local hooksPath pointing outside the checkout is not ours either.
test_hooks_dir_refuses_a_path_outside_the_checkout() {
  local status
  command -v git >/dev/null 2>&1 || { printf 'SKIP: external core.hooksPath (no git)\n'; return 0; }
  git init -q "$TEST_ROOT/h5"
  git -C "$TEST_ROOT/h5" config --local core.hooksPath "$TEST_ROOT/elsewhere"
  set +e
  _sgt_install_hooks_dir "$TEST_ROOT/h5" >/dev/null
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail 'a hooksPath outside the checkout was accepted'
}

# ── _sgt_install_hook_state ───────────────────────────────────────────────────

test_hook_state_classifies_ownership() {
  local hooks
  mkdir -p "$TEST_ROOT/hk/scripts/hooks" "$TEST_ROOT/hk/bin" "$TEST_ROOT/hkdir"
  cp "$ROOT_DIR/bin/_sgt-install-manifest.sh" "$TEST_ROOT/hk/bin/"
  printf '#!/bin/sh\n' > "$TEST_ROOT/hk/scripts/hooks/pre-push"
  hooks="$TEST_ROOT/hkdir"

  [[ "$(_sgt_install_hook_state "$TEST_ROOT/hk/scripts/hooks/pre-push" "$hooks")" == absent ]] || \
    fail 'an empty hooks directory was not reported absent'

  ln -s "$TEST_ROOT/hk/scripts/hooks/pre-push" "$hooks/pre-push"
  [[ "$(_sgt_install_hook_state "$TEST_ROOT/hk/scripts/hooks/pre-push" "$hooks")" == linked ]] || \
    fail 'an exact hook link was not reported linked'

  mkdir -p "$TEST_ROOT/sib/scripts/hooks" "$TEST_ROOT/sib/bin"
  cp "$ROOT_DIR/bin/_sgt-install-manifest.sh" "$TEST_ROOT/sib/bin/"
  printf '#!/bin/sh\n' > "$TEST_ROOT/sib/scripts/hooks/pre-push"
  ln -sfn "$TEST_ROOT/sib/scripts/hooks/pre-push" "$hooks/pre-push"
  [[ "$(_sgt_install_hook_state "$TEST_ROOT/hk/scripts/hooks/pre-push" "$hooks")" == stale ]] || \
    fail "another Sergeant checkout's hook was not reported stale"

  rm -f "$hooks/pre-push"
  printf '#!/bin/sh\necho mine\n' > "$hooks/pre-push"
  [[ "$(_sgt_install_hook_state "$TEST_ROOT/hk/scripts/hooks/pre-push" "$hooks")" == conflict ]] || \
    fail "a user's own hook was not reported as a conflict"
}

# ── _sgt_install_link_points_into ─────────────────────────────────────────────

test_link_ownership_resolves_relative_links() {
  mkdir -p "$TEST_ROOT/po/bin" "$TEST_ROOT/po/target/bin"
  printf '#!/bin/sh\n' > "$TEST_ROOT/po/target/bin/sgt-thing"
  ln -s '../target/bin/sgt-thing' "$TEST_ROOT/po/bin/sgt-thing"
  _sgt_install_link_points_into "$TEST_ROOT/po/bin/sgt-thing" "$TEST_ROOT/po/target" || \
    fail 'a relative link into the checkout was not recognised as owned'
  if _sgt_install_link_points_into "$TEST_ROOT/po/bin/sgt-thing" "$TEST_ROOT/elsewhere"; then
    fail 'a link outside the checkout was reported as owned'
  fi
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
test_relative_link_to_a_users_own_command_is_a_conflict
test_link_into_a_legacy_sergeant_checkout_is_stale
test_relative_link_resolves_physically_through_a_symlinked_parent
test_managed_absent_target_is_absent
test_managed_dangling_link_is_reclaimable
test_managed_link_into_the_mise_tree_is_reclaimable
test_managed_real_file_is_a_conflict
test_managed_relative_link_to_a_users_own_tool_is_a_conflict
test_hooks_dir_is_absolute_for_a_plain_clone
test_hooks_dir_resolves_to_the_common_dir_for_a_worktree
test_hooks_dir_honours_a_repo_local_core_hooks_path
test_hooks_dir_refuses_a_global_core_hooks_path
test_hooks_dir_refuses_a_path_outside_the_checkout
test_hook_state_classifies_ownership
test_link_ownership_resolves_relative_links
test_non_executable_file_on_path_is_not_available
test_executable_on_path_is_available
test_dangling_link_on_path_is_not_available
test_script_root_follows_a_symlink_chain
test_script_root_follows_a_relative_symlink
test_script_root_reports_a_symlink_loop

printf 'install manifest behavior: ok\n'
