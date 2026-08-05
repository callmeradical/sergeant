#!/usr/bin/env bash
# sgt-bootstrap-test.sh — Behavior tests for the cross-platform developer bootstrap.
#
# Covers bin/sgt-bootstrap (toolchain planning, verification, installation) and
# bin/sgt-install (Sergeant command links, deprecated link cleanup, git hooks).
#
# Policy under test (docs/repo-scoped-skills.md): no install step writes to a
# user's global agent configuration. Neither command may create or modify
# ~/.config/opencode or ~/.claude.

set -euo pipefail

# Physical paths throughout: the manifest resolves link targets physically, so a
# fixture built from a logical path (macOS puts TMPDIR under /var/folders, and
# /var is a symlink to private/var) would never compare equal.
ROOT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# shellcheck source=bin/_sgt-install-manifest.sh
source "$ROOT_DIR/bin/_sgt-install-manifest.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# Resolve host utilities rather than hardcoding /bin, so the suite runs the same
# under the pinned Bash 3.2 image where bash lives in /usr/local/bin.
host_utility() {
  local resolved
  resolved="$(command -v "$1")" || fail "test host lacks $1"
  printf '%s\n' "$resolved"
}

HOST_BASH="$(host_utility bash)"

# One sandbox root with an EXIT trap, matching every other test in this repo.
# RETURN traps do not fire when fail() exits, which leaks temp directories.
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
: > "$GIT_CONFIG_GLOBAL"
: > "$GIT_CONFIG_SYSTEM"

# Every command under test runs from a throwaway copy of this checkout, never
# from the checkout itself. sgt-install and sgt-uninstall write to their own
# repository's git hooks directory, so driving the real ROOT_DIR would install
# and then delete the developer's pre-push hook as a side effect of running the
# tests, and a hook the developer already owns would make the suite fail.
FIXTURE_ROOT="$TEST_ROOT/checkout"
mkdir -p "$FIXTURE_ROOT"
cp -R "$ROOT_DIR/bin" "$FIXTURE_ROOT/bin"
cp -R "$ROOT_DIR/scripts" "$FIXTURE_ROOT/scripts"
cp -R "$ROOT_DIR/opencode" "$FIXTURE_ROOT/opencode"
if command -v git >/dev/null 2>&1; then
  git init -q "$FIXTURE_ROOT"
fi

BOOTSTRAP="$FIXTURE_ROOT/bin/sgt-bootstrap"
INSTALL="$FIXTURE_ROOT/bin/sgt-install"
# Assigns SANDBOX rather than printing it: a command substitution would run the
# counter in a subshell and hand every test the same directory.
_case=0
SANDBOX=''
new_sandbox() {
  _case=$((_case + 1))
  SANDBOX="$TEST_ROOT/case-$_case"
  mkdir -p "$SANDBOX"
}
# System PATH suffix for tests that need real utilities alongside their stubs.
SYSTEM_PATH="${HOST_BASH%/*}:/usr/local/bin:/usr/bin:/bin"

assert_contains() {
  local output="$1" expected="$2"
  [[ "$output" == *"$expected"* ]] || fail "expected output to contain: $expected"
}

assert_not_contains() {
  local output="$1" unexpected="$2"
  [[ "$output" != *"$unexpected"* ]] || fail "expected output not to contain: $unexpected"
}

assert_no_global_agent_config() {
  local home_dir="$1" context="$2"
  [[ ! -e "$home_dir/.config/opencode" ]] || \
    fail "$context wrote to global OpenCode configuration"
  [[ ! -e "$home_dir/.claude" ]] || \
    fail "$context wrote to global Claude configuration"
  [[ ! -e "$home_dir/.agents" ]] || \
    fail "$context wrote to the global Agent Skills tree"
}

stub_commands() {
  local bin_dir="$1" command_name
  shift
  for command_name in "$@"; do
    if [[ "$command_name" == 'yq' ]]; then
      cat > "$bin_dir/$command_name" <<'EOF'
#!/usr/bin/env bash
printf 'yq (https://github.com/mikefarah/yq/) version v4.44.1\n'
EOF
    else
      cat > "$bin_dir/$command_name" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    fi
    chmod +x "$bin_dir/$command_name"
  done
}

# Pre-create the command links that `mise run install` would create, so that
# bootstrap's post-install reconciliation finds a complete installation.
# python3 and lsof are now part of the toolchain, so a "fully installed" fixture
# must provide them like any other command.
BASE_TOOLS=(git gh tmux jq shellcheck curl python3 lsof yq)

stub_sergeant_install() {
  local home_dir="$1" source_file target
  mkdir -p "$home_dir/.local/bin"
  while IFS= read -r source_file; do
    [[ -n "$source_file" ]] || continue
    target="$home_dir/.local/bin/${source_file##*/}"
    [[ -e "$target" || -L "$target" ]] || ln -s "$source_file" "$target"
  done <<EOF
$(_sgt_install_sources "$FIXTURE_ROOT")
EOF
}

# Minimal external commands the bootstrap itself needs on a restricted PATH.
stub_platform() {
  local temp_dir="$1" platform="$2" manager="$3" manager_exit="$4"
  mkdir -p "$temp_dir/bin" "$temp_dir/home"
  [[ -e "$temp_dir/bin/bash" ]] || ln -s "$HOST_BASH" "$temp_dir/bin/bash"
  # Real coreutils the bootstrap genuinely shells out to. Stubbing the platform
  # must not hide a missing dependency, so this is the actual binary.
  local utility
  for utility in readlink mkdir rm ln env; do
    [[ -e "$temp_dir/bin/$utility" ]] && continue
    ln -s "$(host_utility "$utility")" "$temp_dir/bin/$utility"
  done
  cat > "$temp_dir/bin/uname" <<EOF
#!/usr/bin/env bash
printf '%s\n' '$platform'
EOF
  chmod +x "$temp_dir/bin/uname"
  if [[ -n "$manager" ]]; then
    cat > "$temp_dir/bin/$manager" <<EOF
#!/usr/bin/env bash
exit $manager_exit
EOF
    chmod +x "$temp_dir/bin/$manager"
  fi
}

# ── Platform detection and package planning ───────────────────────────────────

test_linux_dry_run_plans_apt_packages() {
  local temp_dir output
  new_sandbox; temp_dir="$SANDBOX"

  stub_platform "$temp_dir" Linux apt-get 99

  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin" "$BOOTSTRAP" --dry-run)"

  assert_contains "$output" 'Platform: Linux (apt)'
  assert_contains "$output" 'apt-get update'
  assert_contains "$output" 'apt-get install -y'
  assert_contains "$output" 'git gh tmux jq shellcheck curl python3 lsof'
}

test_macos_dry_run_plans_homebrew_packages() {
  local temp_dir output
  new_sandbox; temp_dir="$SANDBOX"

  stub_platform "$temp_dir" Darwin brew 93

  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin" "$BOOTSTRAP" --dry-run)"

  assert_contains "$output" 'Platform: macOS (Homebrew)'
  assert_contains "$output" 'brew install git gh tmux jq shellcheck curl python3 lsof'
}

# Installing packages needs a supported package manager; inspecting the machine
# does not. docs/getting-started.md and the sergeant-setup skill both send users
# on an unsupported platform to --verify-only, so the read-only modes must run
# everywhere and name the blocker as a manual step.
test_unsupported_platform_blocks_install_only() {
  local temp_dir output status
  new_sandbox; temp_dir="$SANDBOX"

  stub_platform "$temp_dir" FreeBSD '' 0
  stub_commands "$temp_dir/bin" "${BASE_TOOLS[@]}" mise go node uv td graphify no-mistakes opencode claude

  set +e
  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin" "$BOOTSTRAP" --dry-run 2>&1)"
  status=$?
  set -e
  [[ "$status" -eq 0 ]] || fail "expected --dry-run to work on FreeBSD, got $status: $output"
  assert_contains "$output" 'Platform: FreeBSD (no supported package manager)'

  set +e
  output="$(HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/home/.local/bin" \
    PATH="$temp_dir/bin" "$BOOTSTRAP" --verify-only 2>&1)"
  status=$?
  set -e
  assert_contains "$output" 'MANUAL: unsupported platform for automated package installation: FreeBSD'
  assert_contains "$output" 'OK: git'

  # Only the install mode is fatal, and only when packages are actually missing.
  rm -f "$temp_dir/bin/jq"
  set +e
  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin" "$BOOTSTRAP" 2>&1)"
  status=$?
  set -e
  [[ "$status" -eq 1 ]] || fail "expected install on FreeBSD to fail, got $status"
  assert_contains "$output" 'unsupported platform for automated package installation: FreeBSD'
  assert_contains "$output" 'install these packages yourself and rerun: jq'
}

test_missing_package_manager_blocks_install_only() {
  local temp_dir output status
  new_sandbox; temp_dir="$SANDBOX"

  stub_platform "$temp_dir" Linux '' 0
  stub_commands "$temp_dir/bin" "${BASE_TOOLS[@]}" mise go node uv td graphify no-mistakes opencode claude

  # Nothing missing: an apt-less Linux with a complete toolchain must verify.
  set +e
  output="$(HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/home/.local/bin" \
    PATH="$temp_dir/bin" "$BOOTSTRAP" --verify-only 2>&1)"
  status=$?
  set -e
  assert_contains "$output" 'MANUAL: Linux requires an apt-compatible package manager'
  assert_contains "$output" 'OK: python3'

  rm -f "$temp_dir/bin/tmux"
  set +e
  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin" "$BOOTSTRAP" 2>&1)"
  status=$?
  set -e
  [[ "$status" -eq 1 ]] || fail "expected missing apt-get to fail the install, got $status"
  assert_contains "$output" 'requires an apt-compatible package manager'
  assert_contains "$output" 'install these packages yourself and rerun: tmux'
}

test_modes_are_mutually_exclusive() {
  local output status

  set +e
  output="$("$BOOTSTRAP" --dry-run --verify-only 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 2 ]] || fail "expected conflicting modes exit 2, got $status"
  assert_contains "$output" 'cannot be combined'
}

test_unknown_option_fails_clearly() {
  local output status

  set +e
  output="$("$BOOTSTRAP" --nope 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 2 ]] || fail "expected unknown option exit 2, got $status"
  assert_contains "$output" 'unknown option: --nope'
}

# ── Dry-run planning ──────────────────────────────────────────────────────────

test_dry_run_does_not_plan_installed_packages() {
  local temp_dir output
  new_sandbox; temp_dir="$SANDBOX"

  stub_platform "$temp_dir" Linux apt-get 91
  stub_commands "$temp_dir/bin" "${BASE_TOOLS[@]}" \
    mise go node uv td graphify no-mistakes opencode claude

  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin" "$BOOTSTRAP" --dry-run)"

  assert_not_contains "$output" 'apt-get install'
  assert_not_contains "$output" 'link managed executables'
  assert_not_contains "$output" 'go install'
  assert_not_contains "$output" 'uv tool install'
}

test_dry_run_plans_workspace_tools_without_changes() {
  local temp_dir output
  new_sandbox; temp_dir="$SANDBOX"

  stub_platform "$temp_dir" Linux apt-get 98

  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin" "$BOOTSTRAP" --dry-run)"

  assert_contains "$output" 'install mise'
  assert_contains "$output" 'mise install go@latest node@lts uv@latest opencode@latest claude@latest yq@latest'
  assert_contains "$output" 'go install github.com/marcus/td@latest'
  assert_contains "$output" 'go install github.com/kunchenguid/no-mistakes/cmd/no-mistakes@latest'
  assert_contains "$output" 'uv tool install graphifyy'
  assert_contains "$output" 'mise run install'
  assert_contains "$output" 'link Sergeant command sgt-dispatch'
  [[ ! -e "$temp_dir/home/.local" ]] || fail 'dry-run changed the filesystem'
  assert_no_global_agent_config "$temp_dir/home" 'dry-run'
}

test_dry_run_plans_no_global_agent_configuration() {
  local temp_dir output
  new_sandbox; temp_dir="$SANDBOX"

  stub_platform "$temp_dir" Linux apt-get 90

  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin" "$BOOTSTRAP" --dry-run)"

  assert_not_contains "$output" 'skill'
  assert_not_contains "$output" 'oc-inject'
  assert_not_contains "$output" 'plugin'
  assert_no_global_agent_config "$temp_dir/home" 'dry-run'
}

test_dry_run_reports_existing_and_conflicting_commands() {
  local temp_dir output
  new_sandbox; temp_dir="$SANDBOX"

  stub_platform "$temp_dir" Linux apt-get 84
  mkdir -p "$temp_dir/home/.local/bin"
  ln -s "$FIXTURE_ROOT/bin/sgt-dispatch" "$temp_dir/home/.local/bin/sgt-dispatch"
  printf 'custom command\n' > "$temp_dir/home/.local/bin/sgt-list"

  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin" "$BOOTSTRAP" --dry-run)"

  assert_contains "$output" 'preserve Sergeant command sgt-dispatch'
  assert_contains "$output" 'conflict at Sergeant command sgt-list'
  [[ "$(cat "$temp_dir/home/.local/bin/sgt-list")" == 'custom command' ]] || \
    fail 'dry-run modified an existing command'
}

test_python_yq_is_replaced_with_mikefarah_yq() {
  local temp_dir output
  new_sandbox; temp_dir="$SANDBOX"

  stub_platform "$temp_dir" Linux apt-get 87
  stub_commands "$temp_dir/bin" "${BASE_TOOLS[@]}" \
    mise go node uv td graphify no-mistakes opencode claude
  cat > "$temp_dir/bin/yq" <<'EOF'
#!/usr/bin/env bash
printf 'yq 3.4.3\n'
EOF
  chmod +x "$temp_dir/bin/yq"

  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin" "$BOOTSTRAP" --dry-run)"

  assert_contains "$output" 'mise install yq@latest'
}

# A tool in the install directory counts only when that directory is on PATH.
# Crediting it otherwise would report a toolchain the user cannot actually run.
test_managed_tool_counts_only_when_the_install_dir_is_on_path() {
  local temp_dir output
  new_sandbox; temp_dir="$SANDBOX"

  stub_platform "$temp_dir" Linux apt-get 86
  mkdir -p "$temp_dir/home/.local/bin"
  stub_commands "$temp_dir/bin" "${BASE_TOOLS[@]}" mise go node uv td graphify no-mistakes opencode
  stub_commands "$temp_dir/home/.local/bin" claude

  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin" "$BOOTSTRAP" --dry-run)"
  assert_contains "$output" 'claude@latest'

  output="$(HOME="$temp_dir/home" \
    PATH="$temp_dir/bin:$temp_dir/home/.local/bin" "$BOOTSTRAP" --dry-run)"
  assert_not_contains "$output" 'claude@latest'
}

# ── Verification ──────────────────────────────────────────────────────────────

test_verify_only_reports_missing_without_installing() {
  local temp_dir output status
  new_sandbox; temp_dir="$SANDBOX"

  stub_platform "$temp_dir" Linux '' 0
  cat > "$temp_dir/bin/apt-get" <<EOF
#!/usr/bin/env bash
printf 'called\n' > '$temp_dir/apt-called'
EOF
  chmod +x "$temp_dir/bin/apt-get"

  set +e
  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin" "$BOOTSTRAP" --verify-only 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 1 ]] || fail "expected verify exit 1, got $status"
  assert_contains "$output" 'MISSING: git'
  assert_contains "$output" 'MISSING: td'
  assert_contains "$output" 'MISSING: python3'
  assert_contains "$output" 'MISSING: lsof'
  assert_contains "$output" 'MISSING: an agent harness'
  assert_contains "$output" 'MISSING: Sergeant command sgt-list'
  # Optional tools are reported, never fatal: mise run check treats them the same way.
  assert_contains "$output" 'OPTIONAL MISSING: mise'
  assert_contains "$output" 'OPTIONAL MISSING: graphify'
  assert_contains "$output" 'OPTIONAL MISSING: no-mistakes'
  [[ ! -e "$temp_dir/apt-called" ]] || fail 'verify-only called apt-get'
  assert_no_global_agent_config "$temp_dir/home" 'verify-only'
}

test_verify_only_does_not_require_deprecated_oc_inject() {
  local temp_dir output status
  new_sandbox; temp_dir="$SANDBOX"

  stub_platform "$temp_dir" Linux apt-get 95
  stub_commands "$temp_dir/bin" "${BASE_TOOLS[@]}" \
    mise go node uv td graphify no-mistakes opencode claude
  stub_sergeant_install "$temp_dir/home"

  set +e
  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin:$SYSTEM_PATH" "$BOOTSTRAP" --verify-only 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected complete installation to verify, got $status: $output"
  assert_contains "$output" 'Verification complete'
  assert_not_contains "$output" 'oc-inject'
  assert_not_contains "$output" 'skill'
  assert_no_global_agent_config "$temp_dir/home" 'verify-only'
}

test_verify_only_reports_wrong_command_link_as_missing() {
  local temp_dir output status
  new_sandbox; temp_dir="$SANDBOX"

  stub_platform "$temp_dir" Linux apt-get 83
  stub_commands "$temp_dir/bin" "${BASE_TOOLS[@]}" \
    mise go node uv td graphify no-mistakes opencode claude
  stub_sergeant_install "$temp_dir/home"
  rm "$temp_dir/home/.local/bin/sgt-watch"
  ln -s "$HOST_BASH" "$temp_dir/home/.local/bin/sgt-watch"

  set +e
  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin:$SYSTEM_PATH" "$BOOTSTRAP" --verify-only 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 1 ]] || fail "expected wrong command link to fail verification, got $status"
  assert_contains "$output" 'MISSING: Sergeant command sgt-watch'
}

# ── Installation ──────────────────────────────────────────────────────────────

test_package_manager_failure_is_propagated() {
  local temp_dir status
  new_sandbox; temp_dir="$SANDBOX"

  stub_platform "$temp_dir" Linux '' 0
  cat > "$temp_dir/bin/apt-get" <<EOF
#!/usr/bin/env bash
printf 'called\n' > '$temp_dir/apt-called'
exit 42
EOF
  chmod +x "$temp_dir/bin/apt-get"

  set +e
  HOME="$temp_dir/home" PATH="$temp_dir/bin" SGT_BOOTSTRAP_EUID=0 "$BOOTSTRAP" >/dev/null 2>&1
  status=$?
  set -e

  [[ "$status" -eq 42 ]] || fail "expected apt-get exit 42, got $status"
  [[ -f "$temp_dir/apt-called" ]] || fail 'expected apt-get to be called'
}

test_linux_uses_noninteractive_sudo_when_not_root() {
  local temp_dir status
  new_sandbox; temp_dir="$SANDBOX"

  stub_platform "$temp_dir" Linux apt-get 94
  cat > "$temp_dir/bin/sudo" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > '$temp_dir/sudo-call'
exit 43
EOF
  chmod +x "$temp_dir/bin/sudo"

  set +e
  HOME="$temp_dir/home" PATH="$temp_dir/bin" SGT_BOOTSTRAP_EUID=1000 "$BOOTSTRAP" >/dev/null 2>&1
  status=$?
  set -e

  [[ "$status" -eq 43 ]] || fail "expected sudo exit 43, got $status"
  [[ "$(cat "$temp_dir/sudo-call")" == '-n DEBIAN_FRONTEND=noninteractive apt-get update' ]] || \
    fail "apt was not invoked through noninteractive sudo carrying DEBIAN_FRONTEND: $(cat "$temp_dir/sudo-call")"
}

test_missing_sudo_fails_before_touching_packages() {
  local temp_dir output status
  new_sandbox; temp_dir="$SANDBOX"

  stub_platform "$temp_dir" Linux apt-get 94

  set +e
  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin" SGT_BOOTSTRAP_EUID=1000 "$BOOTSTRAP" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 1 ]] || fail "expected missing sudo exit 1, got $status"
  assert_contains "$output" 'requires root or passwordless sudo'
}

test_workspace_installer_failure_is_propagated() {
  local temp_dir status
  new_sandbox; temp_dir="$SANDBOX"

  stub_platform "$temp_dir" Linux apt-get 89
  stub_commands "$temp_dir/bin" "${BASE_TOOLS[@]}" \
    mise node uv graphify no-mistakes opencode claude
  cat > "$temp_dir/bin/go" <<'EOF'
#!/usr/bin/env bash
exit 45
EOF
  chmod +x "$temp_dir/bin/go"

  set +e
  HOME="$temp_dir/home" PATH="$temp_dir/bin" "$BOOTSTRAP" >/dev/null 2>&1
  status=$?
  set -e

  [[ "$status" -eq 45 ]] || fail "expected Go installer exit 45, got $status"
}

test_bootstrap_makes_no_global_agent_configuration_writes() {
  local temp_dir output
  new_sandbox; temp_dir="$SANDBOX"

  stub_platform "$temp_dir" Linux apt-get 97
  stub_commands "$temp_dir/bin" "${BASE_TOOLS[@]}" node \
    mise go uv td graphify no-mistakes opencode claude
  stub_sergeant_install "$temp_dir/home"

  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin:$SYSTEM_PATH" "$BOOTSTRAP")"

  assert_not_contains "$output" 'skill'
  assert_not_contains "$output" 'oc-inject'
  assert_no_global_agent_config "$temp_dir/home" 'bootstrap'
}

test_repeated_run_preserves_existing_tools() {
  local temp_dir command_name
  new_sandbox; temp_dir="$SANDBOX"

  stub_platform "$temp_dir" Linux apt-get 96
  cat > "$temp_dir/bin/mise" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$temp_dir/mise-calls'
EOF
  for command_name in go uv td graphify no-mistakes; do
    cat > "$temp_dir/bin/$command_name" <<EOF
#!/usr/bin/env bash
printf '%s\n' '$command_name' >> '$temp_dir/tool-calls'
EOF
    chmod +x "$temp_dir/bin/$command_name"
  done
  chmod +x "$temp_dir/bin/mise"
  stub_commands "$temp_dir/bin" "${BASE_TOOLS[@]}" node opencode claude
  stub_sergeant_install "$temp_dir/home"

  HOME="$temp_dir/home" PATH="$temp_dir/bin:$SYSTEM_PATH" "$BOOTSTRAP" >/dev/null
  HOME="$temp_dir/home" PATH="$temp_dir/bin:$SYSTEM_PATH" "$BOOTSTRAP" >/dev/null

  [[ "$(grep -c '^install$' "$temp_dir/mise-calls")" -eq 2 ]] || \
    fail 'repository-managed mise tools were not reconciled twice'
  [[ "$(grep -c '^run install$' "$temp_dir/mise-calls")" -eq 2 ]] || \
    fail 'mise install task did not run twice'
  [[ ! -e "$temp_dir/tool-calls" ]] || fail 'an existing tool installer was invoked'
  assert_no_global_agent_config "$temp_dir/home" 'repeated bootstrap'
}


test_bootstrap_reports_preserved_command_conflicts() {
  local temp_dir output status
  new_sandbox; temp_dir="$SANDBOX"

  stub_platform "$temp_dir" Linux apt-get 88
  mkdir -p "$temp_dir/home/.local/bin"
  printf 'custom command\n' > "$temp_dir/home/.local/bin/sgt-list"
  stub_sergeant_install "$temp_dir/home"
  stub_commands "$temp_dir/bin" "${BASE_TOOLS[@]}" node \
    mise go uv td graphify no-mistakes opencode claude

  set +e
  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin:$SYSTEM_PATH" "$BOOTSTRAP" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 1 ]] || fail "expected command conflict exit 1, got $status"
  assert_contains "$output" 'CONFLICT:'
  [[ "$(cat "$temp_dir/home/.local/bin/sgt-list")" == 'custom command' ]] || \
    fail 'bootstrap overwrote a conflicting command'
}


# A bootstrap invoked through its installed symlink must still resolve the
# checkout it belongs to. Resolving to $HOME instead would make it enumerate no
# Sergeant commands at all and silently report a complete installation.
test_bootstrap_resolves_repo_root_through_installed_symlink() {
  local temp_dir output
  new_sandbox; temp_dir="$SANDBOX"

  mkdir -p "$temp_dir/bin" "$temp_dir/home"
  HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/bin" "$INSTALL" >/dev/null
  [[ -L "$temp_dir/bin/sgt-bootstrap" ]] || fail 'sgt-install did not link sgt-bootstrap'

  cat > "$temp_dir/bin/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Linux\n'
EOF
  cat > "$temp_dir/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
exit 82
EOF
  chmod +x "$temp_dir/bin/uname" "$temp_dir/bin/apt-get"

  output="$(HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/bin" \
    PATH="$temp_dir/bin:$SYSTEM_PATH" "$temp_dir/bin/sgt-bootstrap" --dry-run)"

  assert_contains "$output" 'preserve Sergeant command sgt-dispatch'
  assert_contains "$output" 'preserve Sergeant command _sgt-install-manifest.sh'
  assert_not_contains "$output" 'conflict at Sergeant command'
}

# ── bin/sgt-install ───────────────────────────────────────────────────────────

test_install_links_runtime_helpers() {
  local temp_dir output helper
  new_sandbox; temp_dir="$SANDBOX"

  mkdir -p "$temp_dir/bin" "$temp_dir/home"

  output="$(HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/bin" "$INSTALL")"

  for helper in _sgt-lib.sh _sgt-bash-version.sh _sgt-intent.sh _sgt-drain.sh \
                _sgt-response-lock.sh _sgt-install-manifest.sh; do
    [[ -L "$temp_dir/bin/$helper" ]] || fail "sgt-install did not link runtime helper $helper"
  done
  [[ -L "$temp_dir/bin/sgt-dispatch" ]] || fail 'sgt-install did not link sgt-dispatch'
  [[ -L "$temp_dir/bin/sgt-bootstrap" ]] || fail 'sgt-install did not link sgt-bootstrap'
  [[ -L "$temp_dir/bin/wiki-daily-digest" ]] || fail 'sgt-install did not link wiki-daily-digest'
  [[ ! -e "$temp_dir/bin/oc-inject" ]] || fail 'sgt-install linked the deprecated oc-inject command'
  assert_contains "$output" 'Installed'
  assert_no_global_agent_config "$temp_dir/home" 'sgt-install'
}

test_installed_commands_resolve_their_helpers() {
  local temp_dir output status
  new_sandbox; temp_dir="$SANDBOX"

  mkdir -p "$temp_dir/bin" "$temp_dir/home"
  HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/bin" "$INSTALL" >/dev/null

  set +e
  output="$(HOME="$temp_dir/home" "$temp_dir/bin/sgt-dispatch" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail 'sgt-dispatch without arguments should fail'
  assert_contains "$output" 'Usage: sgt-dispatch'
  assert_not_contains "$output" 'No such file'
}

test_install_preserves_existing_user_files() {
  local temp_dir status
  new_sandbox; temp_dir="$SANDBOX"

  mkdir -p "$temp_dir/home/.config/opencode/plugins" "$temp_dir/bin"
  printf 'custom command\n' > "$temp_dir/bin/sgt-list"
  printf 'custom plugin\n' > "$temp_dir/home/.config/opencode/plugins/oc-inject.js"

  # Preserving means the installation is incomplete, so the command must fail.
  set +e
  HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/bin" "$INSTALL" >/dev/null 2>&1
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail 'sgt-install reported success while preserving a command'
  [[ "$(cat "$temp_dir/bin/sgt-list")" == 'custom command' ]] || \
    fail 'sgt-install overwrote an existing command'
  [[ "$(cat "$temp_dir/home/.config/opencode/plugins/oc-inject.js")" == 'custom plugin' ]] || \
    fail 'sgt-install overwrote existing OpenCode configuration'
}

test_install_reports_preserved_conflicts() {
  local temp_dir output status
  new_sandbox; temp_dir="$SANDBOX"
  mkdir -p "$temp_dir/bin" "$temp_dir/home"
  printf 'custom command\n' > "$temp_dir/bin/sgt-list"

  set +e
  output="$(HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/bin" "$INSTALL" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || \
    fail 'sgt-install reported success while sgt-list was not installed'
  assert_contains "$output" "preserved existing: $temp_dir/bin/sgt-list"
  assert_contains "$output" 'Preserved 1 existing'
}

# A dangling link is not a user asset, so it is reclaimed.
test_install_repoints_dangling_sergeant_links() {
  local temp_dir
  new_sandbox; temp_dir="$SANDBOX"
  mkdir -p "$temp_dir/bin" "$temp_dir/home"
  ln -s /nonexistent/other-checkout/bin/sgt-list "$temp_dir/bin/sgt-list"

  HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/bin" "$INSTALL" >/dev/null

  [[ "$(readlink "$temp_dir/bin/sgt-list")" == "$FIXTURE_ROOT/bin/sgt-list" ]] || \
    fail 'sgt-install did not reclaim a dangling Sergeant link'
}

# A symlink pointing at a directory must be replaced in place, never used as a
# destination: ln -sf would write the link inside the directory and report success.
test_install_never_writes_through_a_directory_symlink() {
  local temp_dir status output
  new_sandbox; temp_dir="$SANDBOX"
  mkdir -p "$temp_dir/bin" "$temp_dir/home" "$temp_dir/victim"
  ln -s "$temp_dir/victim" "$temp_dir/bin/sgt-list"

  set +e
  output="$(HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/bin" "$INSTALL" 2>&1)"
  status=$?
  set -e

  [[ -z "$(ls -A "$temp_dir/victim")" ]] || \
    fail 'sgt-install wrote a link inside a directory reached through a symlink'
  [[ "$status" -ne 0 ]] || fail 'sgt-install reported success over an uninstalled command'
  assert_contains "$output" 'preserved existing'
  assert_contains "$output" 'sgt-list'
}

# A user's own command reached through a symlink must survive, including at a
# name outside the sgt-* namespace.
test_install_preserves_a_users_own_symlinked_commands() {
  local temp_dir status
  new_sandbox; temp_dir="$SANDBOX"
  mkdir -p "$temp_dir/bin" "$temp_dir/home" "$temp_dir/mine"
  printf 'user digest\n' > "$temp_dir/mine/wiki-daily-digest"
  printf 'user command\n' > "$temp_dir/mine/sgt-list"
  ln -s "$temp_dir/mine/wiki-daily-digest" "$temp_dir/bin/wiki-daily-digest"
  ln -s "$temp_dir/mine/sgt-list" "$temp_dir/bin/sgt-list"

  set +e
  HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/bin" "$INSTALL" >/dev/null 2>&1
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail 'sgt-install reported success while preserving user commands'
  [[ "$(readlink "$temp_dir/bin/wiki-daily-digest")" == "$temp_dir/mine/wiki-daily-digest" ]] || \
    fail 'sgt-install hijacked a user-owned wiki-daily-digest link'
  [[ "$(readlink "$temp_dir/bin/sgt-list")" == "$temp_dir/mine/sgt-list" ]] || \
    fail 'sgt-install hijacked a user-owned sgt-list link'
}

# A link into a different Sergeant checkout is Sergeant's to repoint.
test_install_repoints_another_sergeant_checkout() {
  local temp_dir
  new_sandbox; temp_dir="$SANDBOX"
  mkdir -p "$temp_dir/bin" "$temp_dir/home" "$temp_dir/other/bin"
  cp "$ROOT_DIR/bin/_sgt-install-manifest.sh" "$temp_dir/other/bin/"
  printf '#!/usr/bin/env bash\n' > "$temp_dir/other/bin/sgt-list"
  ln -s "$temp_dir/other/bin/sgt-list" "$temp_dir/bin/sgt-list"

  HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/bin" "$INSTALL" >/dev/null

  [[ "$(readlink "$temp_dir/bin/sgt-list")" == "$FIXTURE_ROOT/bin/sgt-list" ]] || \
    fail 'sgt-install did not repoint a link from another Sergeant checkout'
}

# Renaming or removing a command must not leave a dangling entry on PATH.
test_install_sweeps_links_for_removed_commands() {
  local temp_dir output
  new_sandbox; temp_dir="$SANDBOX"
  mkdir -p "$temp_dir/bin" "$temp_dir/home"
  ln -s "$FIXTURE_ROOT/bin/sgt-was-renamed-away" "$temp_dir/bin/sgt-was-renamed-away"

  output="$(HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/bin" "$INSTALL")"

  [[ ! -e "$temp_dir/bin/sgt-was-renamed-away" && ! -L "$temp_dir/bin/sgt-was-renamed-away" ]] || \
    fail 'sgt-install left a link for a command this checkout no longer ships'
  assert_contains "$output" 'removed stale Sergeant link'
}

test_install_removes_deprecated_oc_inject_links() {
  local temp_dir output
  new_sandbox; temp_dir="$SANDBOX"

  mkdir -p "$temp_dir/bin" "$temp_dir/home/.config/opencode/plugins"
  ln -s "$FIXTURE_ROOT/bin/oc-inject" "$temp_dir/bin/oc-inject"
  ln -s "$FIXTURE_ROOT/opencode/plugins/oc-inject.js" \
    "$temp_dir/home/.config/opencode/plugins/oc-inject.js"

  output="$(HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/bin" "$INSTALL")"

  [[ ! -e "$temp_dir/bin/oc-inject" && ! -L "$temp_dir/bin/oc-inject" ]] || \
    fail 'sgt-install did not remove the deprecated oc-inject command link'
  [[ ! -e "$temp_dir/home/.config/opencode/plugins/oc-inject.js" && \
     ! -L "$temp_dir/home/.config/opencode/plugins/oc-inject.js" ]] || \
    fail 'sgt-install did not remove the deprecated oc-inject plugin link'
  assert_contains "$output" 'removed deprecated Sergeant link'
}

test_install_keeps_foreign_oc_inject_links() {
  local temp_dir
  new_sandbox; temp_dir="$SANDBOX"

  mkdir -p "$temp_dir/bin" "$temp_dir/home/.config/opencode/plugins"
  ln -s "$HOST_BASH" "$temp_dir/bin/oc-inject"

  HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/bin" "$INSTALL" >/dev/null

  [[ -L "$temp_dir/bin/oc-inject" ]] || \
    fail 'sgt-install removed an oc-inject link it does not own'
}

test_install_is_idempotent() {
  local temp_dir first second
  new_sandbox; temp_dir="$SANDBOX"

  mkdir -p "$temp_dir/bin" "$temp_dir/home"
  first="$(HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/bin" "$INSTALL")"
  second="$(HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/bin" "$INSTALL")"

  [[ "$first" == "$second" ]] || fail 'sgt-install is not idempotent'
}


test_install_warns_when_target_is_not_on_path() {
  local temp_dir output
  new_sandbox; temp_dir="$SANDBOX"

  mkdir -p "$temp_dir/bin" "$temp_dir/home"

  output="$(HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/bin" "$INSTALL")"
  assert_contains "$output" 'is not on your PATH'

  output="$(HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/bin" \
    PATH="$temp_dir/bin:$PATH" "$INSTALL")"
  assert_not_contains "$output" 'is not on your PATH'
}


# ── Read-only guarantees against a stub that actually writes ──────────────────

# assert_no_global_agent_config is only meaningful if the harness stubs would
# write when invoked. These stubs create the forbidden paths, so any probe that
# executes them fails the assertion instead of passing vacuously.
stub_writing_harnesses() {
  local bin_dir="$1" home_dir="$2" command_name
  # yq is instrumented too: the read-only modes are allowed to read its version
  # string to tell mikefarah yq from the Python package, and nothing more.
  cat > "$bin_dir/yq" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$home_dir/yq-invocations'
printf 'yq (https://github.com/mikefarah/yq/) version v4.44.1\n'
EOF
  chmod +x "$bin_dir/yq"
  for command_name in gh opencode claude; do
    cat > "$bin_dir/$command_name" <<EOF
#!/usr/bin/env bash
mkdir -p '$home_dir/.config/opencode' '$home_dir/.claude' '$home_dir/.agents'
printf '%s\n' "\$*" >> '$home_dir/harness-invocations'
exit 0
EOF
    chmod +x "$bin_dir/$command_name"
  done
}

test_dry_run_invokes_no_third_party_command() {
  local temp_dir
  new_sandbox; temp_dir="$SANDBOX"

  stub_platform "$temp_dir" Linux apt-get 81
  stub_commands "$temp_dir/bin" "${BASE_TOOLS[@]}" mise go node uv td graphify no-mistakes
  stub_writing_harnesses "$temp_dir/bin" "$temp_dir/home"

  HOME="$temp_dir/home" PATH="$temp_dir/bin:$SYSTEM_PATH" "$BOOTSTRAP" --dry-run >/dev/null

  [[ ! -e "$temp_dir/home/harness-invocations" ]] || \
    fail "dry-run executed an agent harness: $(cat "$temp_dir/home/harness-invocations")"
  # The only permitted third-party invocation is reading yq's version.
  if [[ -e "$temp_dir/home/yq-invocations" ]]; then
    [[ "$(sort -u "$temp_dir/home/yq-invocations")" == '--version' ]] || \
      fail "dry-run invoked yq beyond a version read: $(cat "$temp_dir/home/yq-invocations")"
  fi
  assert_no_global_agent_config "$temp_dir/home" 'dry-run'
}

test_verify_only_invokes_no_third_party_command() {
  local temp_dir status
  new_sandbox; temp_dir="$SANDBOX"

  stub_platform "$temp_dir" Linux apt-get 80
  stub_commands "$temp_dir/bin" "${BASE_TOOLS[@]}" mise go node uv td graphify no-mistakes
  stub_writing_harnesses "$temp_dir/bin" "$temp_dir/home"
  stub_sergeant_install "$temp_dir/home"

  set +e
  HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/home/.local/bin" \
    PATH="$temp_dir/bin:$SYSTEM_PATH" "$BOOTSTRAP" --verify-only >/dev/null 2>&1
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected a complete installation to verify, got $status"
  [[ ! -e "$temp_dir/home/harness-invocations" ]] || \
    fail "verify-only executed an agent harness: $(cat "$temp_dir/home/harness-invocations")"
  if [[ -e "$temp_dir/home/yq-invocations" ]]; then
    [[ "$(sort -u "$temp_dir/home/yq-invocations")" == '--version' ]] || \
      fail "verify-only invoked yq beyond a version read: $(cat "$temp_dir/home/yq-invocations")"
  fi
  [[ ! -e "$temp_dir/home/.claude" ]] || fail 'verify-only wrote to global Claude configuration'
}

# Authentication is reported unconditionally because it is never automated and
# probing it is neither free nor reliable.
test_authentication_is_always_reported_as_manual() {
  local temp_dir output
  new_sandbox; temp_dir="$SANDBOX"

  stub_platform "$temp_dir" Linux apt-get 79
  stub_commands "$temp_dir/bin" "${BASE_TOOLS[@]}" mise go node uv td graphify no-mistakes
  stub_writing_harnesses "$temp_dir/bin" "$temp_dir/home"
  stub_sergeant_install "$temp_dir/home"

  output="$(HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/home/.local/bin" \
    PATH="$temp_dir/bin:$SYSTEM_PATH" "$BOOTSTRAP" --verify-only)"

  assert_contains "$output" 'MANUAL: run gh auth login'
  assert_contains "$output" 'MANUAL: run opencode auth login'
  [[ ! -e "$temp_dir/home/harness-invocations" ]] || fail 'a harness was probed'
}

# ── verify-only required vs optional ──────────────────────────────────────────

# One harness is enough, and a missing optional tool must not fail the check.
test_verify_only_accepts_one_harness_and_no_optional_tools() {
  local temp_dir output status
  new_sandbox; temp_dir="$SANDBOX"

  stub_platform "$temp_dir" Linux apt-get 78
  stub_commands "$temp_dir/bin" git gh tmux yq python3 lsof td opencode
  stub_sergeant_install "$temp_dir/home"

  # A restricted PATH so a tool installed on the test host cannot satisfy an
  # assertion that it is absent.
  set +e
  output="$(HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/home/.local/bin" \
    PATH="$temp_dir/bin" "$BOOTSTRAP" --verify-only 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected OpenCode-only install to verify, got $status: $output"
  assert_contains "$output" 'OK: agent harness opencode'
  assert_contains "$output" 'OPTIONAL MISSING: graphify'
  assert_contains "$output" 'OPTIONAL MISSING: no-mistakes'
  assert_not_contains "$output" 'MISSING: an agent harness'
}

# A tool reachable only through the install directory is not on the user's PATH,
# so verify-only must not credit it: `mise run check` would fail on that machine.
test_verify_only_does_not_prepend_the_install_directory_to_path() {
  local temp_dir output
  new_sandbox; temp_dir="$SANDBOX"

  stub_platform "$temp_dir" Linux apt-get 68
  mkdir -p "$temp_dir/instdir"
  stub_commands "$temp_dir/instdir" git gh tmux yq python3 lsof td opencode

  set +e
  output="$(HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/instdir" \
    PATH="$temp_dir/bin" "$BOOTSTRAP" --verify-only 2>&1)"
  set -e

  assert_contains "$output" 'MISSING: git'
  assert_contains "$output" 'is not on your PATH'
}

# ── Validate before mutate ────────────────────────────────────────────────────

# A conflict that is knowable up front must stop the run before any package is
# installed, so a failed run has not already changed the machine.
test_conflicts_stop_the_run_before_any_package_is_installed() {
  local temp_dir output status
  new_sandbox; temp_dir="$SANDBOX"

  stub_platform "$temp_dir" Linux '' 0
  cat > "$temp_dir/bin/apt-get" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$temp_dir/apt-calls'
EOF
  chmod +x "$temp_dir/bin/apt-get"
  cat > "$temp_dir/bin/curl" <<EOF
#!/usr/bin/env bash
printf 'curl\n' >> '$temp_dir/curl-calls'
EOF
  chmod +x "$temp_dir/bin/curl"
  mkdir -p "$temp_dir/home/.local/bin"
  printf 'not really uv\n' > "$temp_dir/home/.local/bin/uv"
  stub_commands "$temp_dir/bin" git gh tmux jq shellcheck python3 lsof yq \
    mise go node td graphify no-mistakes opencode claude

  set +e
  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin:$SYSTEM_PATH" "$BOOTSTRAP" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 1 ]] || fail "expected conflict exit 1, got $status"
  assert_contains "$output" "$temp_dir/home/.local/bin/uv is not the required uv executable"
  assert_contains "$output" 'nothing was changed'
  [[ ! -e "$temp_dir/apt-calls" ]] || \
    fail "a package manager ran despite a known conflict: $(cat "$temp_dir/apt-calls")"
  [[ ! -e "$temp_dir/curl-calls" ]] || fail 'an installer was downloaded despite a known conflict'
  [[ "$(cat "$temp_dir/home/.local/bin/uv")" == 'not really uv' ]] || \
    fail 'bootstrap overwrote a conflicting managed tool'
}

# The plan must name the same conflicts the real run would decline on.
test_dry_run_reports_managed_tool_conflicts() {
  local temp_dir output
  new_sandbox; temp_dir="$SANDBOX"

  stub_platform "$temp_dir" Linux apt-get 77
  mkdir -p "$temp_dir/home/.local/bin"
  printf 'not really uv\n' > "$temp_dir/home/.local/bin/uv"
  stub_commands "$temp_dir/bin" "${BASE_TOOLS[@]}" mise go node td graphify no-mistakes opencode claude

  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin:$SYSTEM_PATH" "$BOOTSTRAP" --dry-run)"

  assert_contains "$output" "$temp_dir/home/.local/bin/uv is not the required uv executable"
  assert_contains "$output" 'conflict would stop this run'
}

# A non-executable file on PATH must not be mistaken for an installed tool.
test_non_executable_tool_is_not_treated_as_installed() {
  local temp_dir output
  new_sandbox; temp_dir="$SANDBOX"

  stub_platform "$temp_dir" Linux apt-get 76
  stub_commands "$temp_dir/bin" "${BASE_TOOLS[@]}" mise go node uv td graphify no-mistakes opencode claude
  printf 'junk\n' > "$temp_dir/bin/jq"
  chmod 644 "$temp_dir/bin/jq"

  # Restricted PATH so the host's real jq cannot mask the broken stub.
  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin" "$BOOTSTRAP" --dry-run)"

  assert_contains "$output" 'apt-get install -y jq'
}

# A dangling link is the artifact bootstrap itself leaves behind when mise prunes
# a versioned path, so a rerun has to repair it rather than call it a conflict.
test_dangling_managed_link_is_reclaimed_not_a_conflict() {
  local temp_dir output status
  new_sandbox; temp_dir="$SANDBOX"

  stub_platform "$temp_dir" Linux apt-get 75
  mkdir -p "$temp_dir/home/.local/bin" "$temp_dir/misebin"
  ln -s "$temp_dir/home/.local/share/mise/installs/uv/0.1.0/bin/uv" \
    "$temp_dir/home/.local/bin/uv"
  printf '#!/usr/bin/env bash\n' > "$temp_dir/misebin/uv"
  chmod +x "$temp_dir/misebin/uv"
  cat > "$temp_dir/bin/mise" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == 'exec' ]]; then printf '%s\n' '$temp_dir/misebin/uv'; fi
exit 0
EOF
  chmod +x "$temp_dir/bin/mise"
  stub_commands "$temp_dir/bin" "${BASE_TOOLS[@]}" go node td graphify no-mistakes opencode claude
  stub_sergeant_install "$temp_dir/home"

  set +e
  output="$(HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/home/.local/bin" \
    PATH="$temp_dir/bin:$SYSTEM_PATH" "$BOOTSTRAP" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected a dangling managed link to be repaired, got $status: $output"
  [[ "$(readlink "$temp_dir/home/.local/bin/uv")" == "$temp_dir/misebin/uv" ]] || \
    fail 'the dangling managed link was not repaired'
  assert_not_contains "$output" 'CONFLICT'
}

# A failed download must not be mistaken for a successful mise install.
test_failed_mise_download_is_reported() {
  local temp_dir output status
  new_sandbox; temp_dir="$SANDBOX"

  stub_platform "$temp_dir" Linux apt-get 74
  cat > "$temp_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 22
EOF
  chmod +x "$temp_dir/bin/curl"
  stub_commands "$temp_dir/bin" git gh tmux jq shellcheck python3 lsof yq \
    go node uv td graphify no-mistakes opencode claude
  stub_sergeant_install "$temp_dir/home"

  set +e
  output="$(HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/home/.local/bin" \
    PATH="$temp_dir/bin:$SYSTEM_PATH" "$BOOTSTRAP" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail 'a failed mise download was reported as success'
  assert_contains "$output" 'mise installation failed'
}

# A hook conflict is knowable before any package is installed, so it must be in
# the plan and must stop the run up front like every other conflict.
test_hook_conflict_stops_the_run_before_any_package_is_installed() {
  local temp_dir output status
  new_sandbox; temp_dir="$SANDBOX"
  require_git "hook conflict gating" || return 0

  make_fake_checkout "$temp_dir/checkout"
  printf '#!/bin/sh\necho mine\n' > "$temp_dir/checkout/.git/hooks/pre-push"
  chmod +x "$temp_dir/checkout/.git/hooks/pre-push"
  cp "$FIXTURE_ROOT/bin/sgt-bootstrap" "$temp_dir/checkout/bin/"

  stub_platform "$temp_dir" Linux '' 0
  cat > "$temp_dir/bin/apt-get" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$temp_dir/apt-calls'
EOF
  chmod +x "$temp_dir/bin/apt-get"
  stub_commands "$temp_dir/bin" gh tmux shellcheck curl python3 lsof yq \
    mise go node uv td graphify no-mistakes opencode claude
  # Hook resolution asks git real questions, so the real git must be reachable.
  rm -f "$temp_dir/bin/git"

  set +e
  output="$(HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/home/.local/bin" \
    PATH="$temp_dir/bin:$SYSTEM_PATH" "$temp_dir/checkout/bin/sgt-bootstrap" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 1 ]] || fail "expected a hook conflict to stop the run, got $status: $output"
  assert_contains "$output" 'is a git hook this checkout does not own'
  assert_contains "$output" 'nothing was changed'
  [[ ! -e "$temp_dir/apt-calls" ]] || \
    fail "a package manager ran despite a known hook conflict: $(cat "$temp_dir/apt-calls")"
  [[ "$(cat "$temp_dir/checkout/.git/hooks/pre-push")" == '#!/bin/sh'* ]] || \
    fail "the user's hook was modified"
}

test_dry_run_reports_the_hook_plan() {
  local temp_dir output
  new_sandbox; temp_dir="$SANDBOX"
  require_git "hook plan" || return 0

  make_fake_checkout "$temp_dir/checkout"
  cp "$FIXTURE_ROOT/bin/sgt-bootstrap" "$temp_dir/checkout/bin/"
  stub_platform "$temp_dir" Linux apt-get 73
  stub_commands "$temp_dir/bin" "${BASE_TOOLS[@]}" mise go node uv td graphify no-mistakes opencode claude
  # Hook resolution asks git real questions, so the real git must be reachable.
  rm -f "$temp_dir/bin/git"

  output="$(HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/home/.local/bin" \
    PATH="$temp_dir/bin:$SYSTEM_PATH" "$temp_dir/checkout/bin/sgt-bootstrap" --dry-run)"

  assert_contains "$output" 'DRY-RUN: link git hook pre-push'
}

# The plan text and the executed command must come from one literal, so a change
# to one cannot silently diverge from the other.
test_dry_run_plan_matches_the_source_installer_commands() {
  local temp_dir output planned_commands
  new_sandbox; temp_dir="$SANDBOX"

  stub_platform "$temp_dir" Linux apt-get 72
  cat > "$temp_dir/bin/go" <<EOF
#!/usr/bin/env bash
printf 'go %s\n' "\$*" >> '$temp_dir/installer-calls'
EOF
  cat > "$temp_dir/bin/uv" <<EOF
#!/usr/bin/env bash
printf 'uv %s\n' "\$*" >> '$temp_dir/installer-calls'
EOF
  chmod +x "$temp_dir/bin/go" "$temp_dir/bin/uv"
  stub_commands "$temp_dir/bin" "${BASE_TOOLS[@]}" mise node opencode claude
  stub_sergeant_install "$temp_dir/home"

  output="$(HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/home/.local/bin" \
    PATH="$temp_dir/bin:$SYSTEM_PATH" "$BOOTSTRAP" --dry-run)"

  HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/home/.local/bin" \
    PATH="$temp_dir/bin:$SYSTEM_PATH" "$BOOTSTRAP" >/dev/null

  # Extended regex: BRE alternation with \| is a GNU sed extension that BSD sed
  # treats literally, which would silently extract nothing and assert nothing.
  planned_commands="$(printf '%s\n' "$output" | \
    sed -n -E 's/^DRY-RUN: [A-Z_]+=[^ ]+ ((go install|uv tool install) .*)$/\1/p')"
  [[ -n "$planned_commands" ]] || \
    fail "no installer commands were extracted from the plan: $output"

  # Every command the plan promised must appear in what actually ran.
  while IFS= read -r planned; do
    [[ -n "$planned" ]] || continue
    grep -Fqx "$planned" "$temp_dir/installer-calls" || \
      fail "the plan promised '$planned' but the run executed: $(cat "$temp_dir/installer-calls")"
  done <<< "$planned_commands"
}

# go install and uv write directly into the install directory, so a user file
# there must stop the run before either installer executes.
test_source_installed_tool_conflict_stops_the_run() {
  local temp_dir output status
  new_sandbox; temp_dir="$SANDBOX"

  stub_platform "$temp_dir" Linux apt-get 71
  mkdir -p "$temp_dir/home/.local/bin"
  printf 'MY OWN NOTES\n' > "$temp_dir/home/.local/bin/td"
  cat > "$temp_dir/bin/go" <<EOF
#!/usr/bin/env bash
printf 'go %s\n' "\$*" >> '$temp_dir/installer-calls'
printf '#!/bin/sh\n' > "\$GOBIN/td"
EOF
  chmod +x "$temp_dir/bin/go"
  stub_commands "$temp_dir/bin" "${BASE_TOOLS[@]}" mise node uv graphify no-mistakes opencode claude

  set +e
  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin:$SYSTEM_PATH" "$BOOTSTRAP" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 1 ]] || fail "expected a td conflict to stop the run, got $status: $output"
  assert_contains "$output" "$temp_dir/home/.local/bin/td is not the required td executable"
  assert_contains "$output" 'nothing was changed'
  [[ ! -e "$temp_dir/installer-calls" ]] || \
    fail "an installer ran despite a known conflict: $(cat "$temp_dir/installer-calls")"
  [[ "$(cat "$temp_dir/home/.local/bin/td")" == 'MY OWN NOTES' ]] || \
    fail "the user's file at the td path was overwritten"
}

test_dry_run_reports_source_installed_tool_conflicts() {
  local temp_dir output
  new_sandbox; temp_dir="$SANDBOX"

  stub_platform "$temp_dir" Linux apt-get 70
  mkdir -p "$temp_dir/home/.local/bin"
  printf 'MY OWN NOTES\n' > "$temp_dir/home/.local/bin/graphify"
  stub_commands "$temp_dir/bin" "${BASE_TOOLS[@]}" mise go node uv td no-mistakes opencode claude

  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin:$SYSTEM_PATH" "$BOOTSTRAP" --dry-run)"

  assert_contains "$output" "$temp_dir/home/.local/bin/graphify is not the required graphify executable"
  assert_contains "$output" 'conflict would stop this run'
}

# The assignment has to prefix the shell that interprets the installer: in a
# pipeline a prefix applies only to the command it precedes.
test_mise_installer_receives_the_install_path() {
  local temp_dir seen
  new_sandbox; temp_dir="$SANDBOX"

  stub_platform "$temp_dir" Linux apt-get 69
  stub_commands "$temp_dir/bin" "${BASE_TOOLS[@]}" go node uv td graphify no-mistakes opencode claude
  # Written after stub_commands, which also provides a plain curl stub. Emits an
  # installer that records the variable it was given; the pipeline runs it under
  # sh, which inherits HOME.
  cat > "$temp_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
cat <<'INSTALLER'
printf '%s\n' "${MISE_INSTALL_PATH:-UNSET}" > "$HOME/installer-saw"
INSTALLER
EOF
  chmod +x "$temp_dir/bin/curl"
  stub_sergeant_install "$temp_dir/home"

  set +e
  HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/home/.local/bin" \
    PATH="$temp_dir/bin:$SYSTEM_PATH" "$BOOTSTRAP" >/dev/null 2>&1
  set -e

  [[ -f "$temp_dir/home/installer-saw" ]] || fail 'the mise installer was never executed'
  seen="$(cat "$temp_dir/home/installer-saw")"
  [[ "$seen" == "$temp_dir/home/.local/bin/mise" ]] || \
    fail "the mise installer saw MISE_INSTALL_PATH='$seen'"
}

# ── Empty manifest ────────────────────────────────────────────────────────────

# A checkout whose bin/ cannot be resolved must fail loudly in every mode rather
# than report a complete installation over an empty plan.
test_empty_manifest_fails_every_mode() {
  local temp_dir mode status output
  new_sandbox; temp_dir="$SANDBOX"

  mkdir -p "$temp_dir/fake/bin" "$temp_dir/home"
  cp "$ROOT_DIR/bin/_sgt-install-manifest.sh" "$temp_dir/fake/bin/"
  for script in sgt-bootstrap sgt-install sgt-uninstall; do
    cp "$FIXTURE_ROOT/bin/$script" "$temp_dir/fake/bin/$script"
  done
  # Move the manifest's inputs out of reach: bin/ now holds only copies whose
  # own root resolves to a directory with no installable commands.
  mkdir -p "$temp_dir/fake2"
  mv "$temp_dir/fake/bin" "$temp_dir/fake2/notbin"

  for mode in '--dry-run' '--verify-only' ''; do
    set +e
    output="$(HOME="$temp_dir/home" "$temp_dir/fake2/notbin/sgt-bootstrap" $mode 2>&1)"
    status=$?
    set -e
    [[ "$status" -ne 0 ]] || fail "empty manifest succeeded for mode '${mode:-install}'"
    assert_contains "$output" 'no installable commands found'
  done

  set +e
  output="$(HOME="$temp_dir/home" "$temp_dir/fake2/notbin/sgt-install" 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail 'sgt-install succeeded with an empty manifest'
  assert_contains "$output" 'no installable commands found'
}

# ── Git hooks, in an isolated checkout ────────────────────────────────────────

# Builds a throwaway Sergeant-shaped checkout so hook installation is never
# asserted against, or performed on, the repository running the tests.
# Returns non-zero when git is unavailable, so the caller reports an explicit
# skip rather than silently covering nothing.
require_git() {
  command -v git >/dev/null 2>&1 && return 0
  printf 'SKIP: %s (git is not available on this host)\n' "$1"
  return 1
}

make_fake_checkout() {
  local root="$1"
  mkdir -p "$root/bin" "$root/scripts/hooks"
  cp "$ROOT_DIR/bin/_sgt-install-manifest.sh" "$root/bin/"
  cp "$ROOT_DIR/bin/sgt-install" "$root/bin/"
  cp "$ROOT_DIR/bin/sgt-uninstall" "$root/bin/"
  printf '#!/usr/bin/env bash\nprintf sgt-fake\n' > "$root/bin/sgt-fake"
  chmod +x "$root/bin/sgt-fake"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$root/scripts/hooks/pre-push"
  chmod +x "$root/scripts/hooks/pre-push"
  git init -q "$root"
}

test_install_links_git_hooks_into_its_own_checkout() {
  local temp_dir
  new_sandbox; temp_dir="$SANDBOX"

  require_git "git hook installation" || return 0

  make_fake_checkout "$temp_dir/checkout"
  mkdir -p "$temp_dir/bin" "$temp_dir/home"

  HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/bin" \
    "$temp_dir/checkout/bin/sgt-install" >/dev/null

  [[ "$(readlink "$temp_dir/checkout/.git/hooks/pre-push")" == \
     "$temp_dir/checkout/scripts/hooks/pre-push" ]] || \
    fail 'sgt-install did not link the hook into its own checkout'
}

# --git-dir prints the relative string ".git" for a normal clone, so a
# cwd-relative resolution would install Sergeant's hook into whatever repository
# the user happens to be standing in.
test_install_never_touches_hooks_of_an_unrelated_repository() {
  local temp_dir
  new_sandbox; temp_dir="$SANDBOX"

  require_git "foreign-repository hook isolation" || return 0

  make_fake_checkout "$temp_dir/checkout"
  git init -q "$temp_dir/other"
  printf '#!/bin/sh\necho mine\n' > "$temp_dir/other/.git/hooks/pre-push"
  chmod +x "$temp_dir/other/.git/hooks/pre-push"
  mkdir -p "$temp_dir/bin" "$temp_dir/home"

  ( cd "$temp_dir/other" && \
    HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/bin" \
      "$temp_dir/checkout/bin/sgt-install" >/dev/null )

  [[ ! -L "$temp_dir/other/.git/hooks/pre-push" ]] || \
    fail 'sgt-install replaced the pre-push hook of an unrelated repository'
  [[ "$(cat "$temp_dir/other/.git/hooks/pre-push")" == '#!/bin/sh'* ]] || \
    fail "an unrelated repository's hook was modified"
  [[ "$(readlink "$temp_dir/checkout/.git/hooks/pre-push")" == \
     "$temp_dir/checkout/scripts/hooks/pre-push" ]] || \
    fail 'the hook was not installed into the owning checkout'
}

test_install_preserves_a_users_own_hook() {
  local temp_dir output status
  new_sandbox; temp_dir="$SANDBOX"

  require_git "user hook preservation" || return 0

  make_fake_checkout "$temp_dir/checkout"
  printf '#!/bin/sh\necho mine\n' > "$temp_dir/checkout/.git/hooks/pre-push"
  chmod +x "$temp_dir/checkout/.git/hooks/pre-push"
  mkdir -p "$temp_dir/bin" "$temp_dir/home"

  set +e
  output="$(HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/bin" \
    "$temp_dir/checkout/bin/sgt-install" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail 'sgt-install reported success while preserving a user hook'
  assert_contains "$output" 'preserved existing hook'
  [[ "$(cat "$temp_dir/checkout/.git/hooks/pre-push")" == '#!/bin/sh'* ]] || \
    fail "the user's own pre-push hook was replaced"
}

# Linked worktrees share one hooks directory with their primary checkout, so a
# hook installed by a sibling Sergeant checkout must be repointed, not reported
# as a user conflict that fails the install.
test_install_repoints_a_hook_owned_by_another_sergeant_checkout() {
  local temp_dir output status
  new_sandbox; temp_dir="$SANDBOX"
  require_git "sibling-checkout hook ownership" || return 0

  make_fake_checkout "$temp_dir/checkout"
  make_fake_checkout "$temp_dir/sibling"
  ln -s "$temp_dir/sibling/scripts/hooks/pre-push" \
    "$temp_dir/checkout/.git/hooks/pre-push"
  mkdir -p "$temp_dir/bin" "$temp_dir/home"

  set +e
  output="$(HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/bin" \
    "$temp_dir/checkout/bin/sgt-install" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || \
    fail "a sibling checkout's hook was treated as a conflict: $output"
  [[ "$(readlink "$temp_dir/checkout/.git/hooks/pre-push")" == \
     "$temp_dir/checkout/scripts/hooks/pre-push" ]] || \
    fail "the sibling checkout's hook was not repointed"
}

test_hooks_only_reports_its_work_and_creates_no_command_directory() {
  local temp_dir output
  new_sandbox; temp_dir="$SANDBOX"
  require_git "hooks-only reporting" || return 0

  make_fake_checkout "$temp_dir/checkout"
  mkdir -p "$temp_dir/home"

  output="$(HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/should-not-exist" \
    "$temp_dir/checkout/bin/sgt-install" --hooks-only)"

  assert_contains "$output" 'linked hook'
  assert_contains "$output" 'Installed 1 entries'
  [[ ! -e "$temp_dir/should-not-exist" ]] || \
    fail 'sgt-install --hooks-only created the command directory'
}

test_hooks_only_fails_when_no_hooks_directory_is_owned() {
  local temp_dir output status
  new_sandbox; temp_dir="$SANDBOX"
  require_git "hooks-only failure reporting" || return 0

  make_fake_checkout "$temp_dir/checkout"
  # A wider-scope hooksPath redirects git away from this repository, so there is
  # no hooks directory this checkout may own.
  printf '[core]\n\thooksPath = %s\n' "$temp_dir/global-hooks" > "$GIT_CONFIG_GLOBAL"

  set +e
  output="$(HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/bin" \
    "$temp_dir/checkout/bin/sgt-install" --hooks-only 2>&1)"
  status=$?
  set -e
  : > "$GIT_CONFIG_GLOBAL"

  [[ "$status" -ne 0 ]] || fail 'sgt-install --hooks-only reported success installing no hooks'
  assert_contains "$output" 'no git hooks were installed'
  [[ ! -e "$temp_dir/global-hooks" ]] || \
    fail 'sgt-install wrote into a global hooks directory'
}

# ── sgt-uninstall ─────────────────────────────────────────────────────────────

test_uninstall_removes_only_what_this_checkout_installed() {
  local temp_dir output
  new_sandbox; temp_dir="$SANDBOX"

  require_git "uninstall ownership" || return 0

  make_fake_checkout "$temp_dir/checkout"
  mkdir -p "$temp_dir/bin" "$temp_dir/home" "$temp_dir/mine"
  HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/bin" \
    "$temp_dir/checkout/bin/sgt-install" >/dev/null

  printf 'user command\n' > "$temp_dir/mine/sgt-theirs"
  ln -s "$temp_dir/mine/sgt-theirs" "$temp_dir/bin/sgt-theirs"
  printf 'real file\n' > "$temp_dir/bin/sgt-realfile"

  output="$(HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/bin" \
    "$temp_dir/checkout/bin/sgt-uninstall")"

  [[ ! -e "$temp_dir/bin/sgt-fake" && ! -L "$temp_dir/bin/sgt-fake" ]] || \
    fail 'sgt-uninstall left a command it installed'
  [[ ! -e "$temp_dir/checkout/.git/hooks/pre-push" ]] || \
    fail 'sgt-uninstall left the git hook it installed'
  [[ -L "$temp_dir/bin/sgt-theirs" ]] || fail 'sgt-uninstall removed a foreign link'
  [[ -f "$temp_dir/bin/sgt-realfile" ]] || fail 'sgt-uninstall removed a real user file'
  assert_contains "$output" 'kept (not owned by this checkout)'
  assert_contains "$output" 'removed hook'
}

test_uninstall_removes_a_link_for_a_command_no_longer_shipped() {
  local temp_dir
  new_sandbox; temp_dir="$SANDBOX"

  require_git "uninstall stale sweep" || return 0

  make_fake_checkout "$temp_dir/checkout"
  mkdir -p "$temp_dir/bin" "$temp_dir/home"
  ln -s "$temp_dir/checkout/bin/sgt-was-removed" "$temp_dir/bin/sgt-was-removed"

  HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/bin" \
    "$temp_dir/checkout/bin/sgt-uninstall" >/dev/null

  [[ ! -L "$temp_dir/bin/sgt-was-removed" ]] || \
    fail 'sgt-uninstall left a dangling link for a removed command'
}

# ── Manifest ──────────────────────────────────────────────────────────────────

test_manifest_excludes_non_regular_and_deprecated_entries() {
  local sources
  sources="$(_sgt_install_sources "$FIXTURE_ROOT")"

  assert_contains "$sources" "$FIXTURE_ROOT/bin/sgt-dispatch"
  assert_contains "$sources" "$FIXTURE_ROOT/bin/_sgt-lib.sh"
  assert_contains "$sources" "$FIXTURE_ROOT/bin/wiki-daily-digest"
  assert_not_contains "$sources" "$FIXTURE_ROOT/bin/oc-inject"
  assert_not_contains "$sources" '__pycache__'
}

test_linux_dry_run_plans_apt_packages
test_macos_dry_run_plans_homebrew_packages
test_unsupported_platform_blocks_install_only
test_missing_package_manager_blocks_install_only
test_modes_are_mutually_exclusive
test_unknown_option_fails_clearly
test_dry_run_does_not_plan_installed_packages
test_dry_run_plans_workspace_tools_without_changes
test_dry_run_plans_no_global_agent_configuration
test_dry_run_reports_existing_and_conflicting_commands
test_python_yq_is_replaced_with_mikefarah_yq
test_managed_tool_counts_only_when_the_install_dir_is_on_path
test_verify_only_reports_missing_without_installing
test_verify_only_reports_wrong_command_link_as_missing
test_verify_only_does_not_require_deprecated_oc_inject
test_bootstrap_reports_preserved_command_conflicts
test_package_manager_failure_is_propagated
test_linux_uses_noninteractive_sudo_when_not_root
test_missing_sudo_fails_before_touching_packages
test_workspace_installer_failure_is_propagated
test_bootstrap_makes_no_global_agent_configuration_writes
test_repeated_run_preserves_existing_tools
test_bootstrap_resolves_repo_root_through_installed_symlink
test_install_links_runtime_helpers
test_installed_commands_resolve_their_helpers
test_install_preserves_existing_user_files
test_install_reports_preserved_conflicts
test_install_repoints_dangling_sergeant_links
test_install_never_writes_through_a_directory_symlink
test_install_preserves_a_users_own_symlinked_commands
test_install_repoints_another_sergeant_checkout
test_install_sweeps_links_for_removed_commands
test_install_removes_deprecated_oc_inject_links
test_install_keeps_foreign_oc_inject_links
test_install_is_idempotent
test_install_warns_when_target_is_not_on_path
test_dry_run_invokes_no_third_party_command
test_verify_only_invokes_no_third_party_command
test_authentication_is_always_reported_as_manual
test_verify_only_accepts_one_harness_and_no_optional_tools
test_verify_only_does_not_prepend_the_install_directory_to_path
test_conflicts_stop_the_run_before_any_package_is_installed
test_dry_run_reports_managed_tool_conflicts
test_non_executable_tool_is_not_treated_as_installed
test_dangling_managed_link_is_reclaimed_not_a_conflict
test_failed_mise_download_is_reported
test_hook_conflict_stops_the_run_before_any_package_is_installed
test_dry_run_reports_the_hook_plan
test_dry_run_plan_matches_the_source_installer_commands
test_source_installed_tool_conflict_stops_the_run
test_dry_run_reports_source_installed_tool_conflicts
test_mise_installer_receives_the_install_path
test_empty_manifest_fails_every_mode
test_install_links_git_hooks_into_its_own_checkout
test_install_never_touches_hooks_of_an_unrelated_repository
test_install_preserves_a_users_own_hook
test_install_repoints_a_hook_owned_by_another_sergeant_checkout
test_hooks_only_reports_its_work_and_creates_no_command_directory
test_hooks_only_fails_when_no_hooks_directory_is_owned
test_uninstall_removes_only_what_this_checkout_installed
test_uninstall_removes_a_link_for_a_command_no_longer_shipped
test_manifest_excludes_non_regular_and_deprecated_entries

printf 'PASS: sgt-bootstrap and sgt-install behavior\n'
