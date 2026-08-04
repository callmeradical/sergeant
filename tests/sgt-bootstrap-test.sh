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

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="$ROOT_DIR/bin/sgt-bootstrap"
INSTALL="$ROOT_DIR/bin/sgt-install"

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
HOST_MKDIR="$(host_utility mkdir)"
HOST_READLINK="$(host_utility readlink)"
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
stub_sergeant_install() {
  local home_dir="$1" source_file target
  mkdir -p "$home_dir/.local/bin"
  while IFS= read -r source_file; do
    [[ -n "$source_file" ]] || continue
    target="$home_dir/.local/bin/${source_file##*/}"
    [[ -e "$target" || -L "$target" ]] || ln -s "$source_file" "$target"
  done <<EOF
$(_sgt_install_sources "$ROOT_DIR")
EOF
}

# Minimal external commands the bootstrap itself needs on a restricted PATH.
stub_platform() {
  local temp_dir="$1" platform="$2" manager="$3" manager_exit="$4"
  mkdir -p "$temp_dir/bin" "$temp_dir/home"
  ln -s "$HOST_BASH" "$temp_dir/bin/bash"
  # Real coreutils the bootstrap genuinely shells out to. Stubbing the platform
  # must not hide a missing dependency, so this is the actual binary.
  ln -s "$HOST_READLINK" "$temp_dir/bin/readlink"
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
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  stub_platform "$temp_dir" Linux apt-get 99

  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin" "$BOOTSTRAP" --dry-run)"

  assert_contains "$output" 'Platform: Linux (apt)'
  assert_contains "$output" 'apt-get update'
  assert_contains "$output" 'apt-get install -y'
  assert_contains "$output" 'git gh tmux jq shellcheck'
}

test_macos_dry_run_plans_homebrew_packages() {
  local temp_dir output
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  stub_platform "$temp_dir" Darwin brew 93

  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin" "$BOOTSTRAP" --dry-run)"

  assert_contains "$output" 'Platform: macOS (Homebrew)'
  assert_contains "$output" 'brew install git gh tmux jq shellcheck curl'
}

test_unsupported_platform_fails_clearly() {
  local temp_dir output status
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  stub_platform "$temp_dir" FreeBSD '' 0

  set +e
  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin:$SYSTEM_PATH" "$BOOTSTRAP" --dry-run 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 1 ]] || fail "expected unsupported platform exit 1, got $status"
  assert_contains "$output" 'unsupported platform: FreeBSD'
}

test_missing_package_manager_fails_clearly() {
  local temp_dir output status
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  stub_platform "$temp_dir" Linux '' 0

  set +e
  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin" "$BOOTSTRAP" --dry-run 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 1 ]] || fail "expected missing apt-get exit 1, got $status"
  assert_contains "$output" 'requires an apt-compatible package manager'
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
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  stub_platform "$temp_dir" Linux apt-get 91
  stub_commands "$temp_dir/bin" git gh tmux jq shellcheck curl \
    mise go node uv td graphify no-mistakes opencode claude yq

  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin" "$BOOTSTRAP" --dry-run)"

  assert_not_contains "$output" 'apt-get install'
  assert_not_contains "$output" 'link managed executables'
  assert_not_contains "$output" 'go install'
  assert_not_contains "$output" 'uv tool install'
}

test_dry_run_plans_workspace_tools_without_changes() {
  local temp_dir output
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

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
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  stub_platform "$temp_dir" Linux apt-get 90

  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin" "$BOOTSTRAP" --dry-run)"

  assert_not_contains "$output" 'skill'
  assert_not_contains "$output" 'oc-inject'
  assert_not_contains "$output" 'plugin'
  assert_no_global_agent_config "$temp_dir/home" 'dry-run'
}

test_dry_run_reports_existing_and_conflicting_commands() {
  local temp_dir output
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  stub_platform "$temp_dir" Linux apt-get 84
  mkdir -p "$temp_dir/home/.local/bin"
  ln -s "$ROOT_DIR/bin/sgt-dispatch" "$temp_dir/home/.local/bin/sgt-dispatch"
  printf 'custom command\n' > "$temp_dir/home/.local/bin/sgt-list"

  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin" "$BOOTSTRAP" --dry-run)"

  assert_contains "$output" 'preserve Sergeant command sgt-dispatch'
  assert_contains "$output" 'conflict at Sergeant command sgt-list'
  [[ "$(cat "$temp_dir/home/.local/bin/sgt-list")" == 'custom command' ]] || \
    fail 'dry-run modified an existing command'
}

test_python_yq_is_replaced_with_mikefarah_yq() {
  local temp_dir output
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  stub_platform "$temp_dir" Linux apt-get 87
  stub_commands "$temp_dir/bin" git gh tmux jq shellcheck curl \
    mise go node uv td graphify no-mistakes opencode claude
  cat > "$temp_dir/bin/yq" <<'EOF'
#!/usr/bin/env bash
printf 'yq 3.4.3\n'
EOF
  chmod +x "$temp_dir/bin/yq"

  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin" "$BOOTSTRAP" --dry-run)"

  assert_contains "$output" 'mise install yq@latest'
}

test_managed_link_is_found_outside_original_path() {
  local temp_dir output
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  stub_platform "$temp_dir" Linux apt-get 86
  mkdir -p "$temp_dir/home/.local/bin"
  stub_commands "$temp_dir/bin" git gh tmux jq shellcheck curl \
    mise go node uv yq td graphify no-mistakes opencode
  cat > "$temp_dir/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$temp_dir/claude"
  ln -s "$temp_dir/claude" "$temp_dir/home/.local/bin/claude"

  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin" "$BOOTSTRAP" --dry-run)"

  assert_not_contains "$output" 'claude@latest'
}

# ── Verification ──────────────────────────────────────────────────────────────

test_verify_only_reports_missing_without_installing() {
  local temp_dir output status
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  mkdir -p "$temp_dir/bin" "$temp_dir/home"
  ln -s "$HOST_BASH" "$temp_dir/bin/bash"
  cat > "$temp_dir/bin/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Linux\n'
EOF
  cat > "$temp_dir/bin/apt-get" <<EOF
#!/usr/bin/env bash
printf 'called\n' > '$temp_dir/apt-called'
EOF
  chmod +x "$temp_dir/bin/uname" "$temp_dir/bin/apt-get"

  set +e
  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin" "$BOOTSTRAP" --verify-only 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 1 ]] || fail "expected verify exit 1, got $status"
  assert_contains "$output" 'MISSING: git'
  assert_contains "$output" 'MISSING: mise'
  assert_contains "$output" 'MISSING: td'
  assert_contains "$output" 'MISSING: graphify'
  assert_contains "$output" 'MISSING: no-mistakes'
  assert_contains "$output" 'MISSING: opencode'
  assert_contains "$output" 'MISSING: claude'
  assert_contains "$output" 'MISSING: Sergeant command sgt-list'
  [[ ! -e "$temp_dir/apt-called" ]] || fail 'verify-only called apt-get'
  assert_no_global_agent_config "$temp_dir/home" 'verify-only'
}

test_verify_only_does_not_require_deprecated_oc_inject() {
  local temp_dir output status
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  stub_platform "$temp_dir" Linux apt-get 95
  stub_commands "$temp_dir/bin" git gh tmux jq shellcheck curl \
    mise go node uv yq td graphify no-mistakes opencode claude
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
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  stub_platform "$temp_dir" Linux apt-get 83
  stub_commands "$temp_dir/bin" git gh tmux jq shellcheck curl \
    mise go node uv yq td graphify no-mistakes opencode claude
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
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  mkdir -p "$temp_dir/bin" "$temp_dir/home"
  ln -s "$HOST_BASH" "$temp_dir/bin/bash"
  cat > "$temp_dir/bin/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Linux\n'
EOF
  cat > "$temp_dir/bin/apt-get" <<EOF
#!/usr/bin/env bash
printf 'called\n' > '$temp_dir/apt-called'
exit 42
EOF
  chmod +x "$temp_dir/bin/uname" "$temp_dir/bin/apt-get"

  set +e
  HOME="$temp_dir/home" PATH="$temp_dir/bin" SGT_BOOTSTRAP_EUID=0 "$BOOTSTRAP" >/dev/null 2>&1
  status=$?
  set -e

  [[ "$status" -eq 42 ]] || fail "expected apt-get exit 42, got $status"
  [[ -f "$temp_dir/apt-called" ]] || fail 'expected apt-get to be called'
}

test_linux_uses_noninteractive_sudo_when_not_root() {
  local temp_dir status
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

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
  [[ "$(cat "$temp_dir/sudo-call")" == '-n apt-get update' ]] || \
    fail 'apt was not invoked through noninteractive sudo'
}

test_missing_sudo_fails_before_touching_packages() {
  local temp_dir output status
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

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
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  stub_platform "$temp_dir" Linux apt-get 89
  ln -s "$HOST_MKDIR" "$temp_dir/bin/mkdir"
  stub_commands "$temp_dir/bin" git gh tmux jq shellcheck yq curl \
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
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  stub_platform "$temp_dir" Linux apt-get 97
  stub_commands "$temp_dir/bin" git gh tmux jq shellcheck curl node yq \
    mise go uv td graphify no-mistakes opencode claude
  stub_sergeant_install "$temp_dir/home"

  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin:$SYSTEM_PATH" "$BOOTSTRAP")"

  assert_not_contains "$output" 'skill'
  assert_not_contains "$output" 'oc-inject'
  assert_no_global_agent_config "$temp_dir/home" 'bootstrap'
}

test_repeated_run_preserves_existing_tools() {
  local temp_dir command_name
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

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
  stub_commands "$temp_dir/bin" git gh tmux jq shellcheck yq curl node opencode claude
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

test_authentication_is_reported_as_manual_action() {
  local temp_dir output
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  stub_platform "$temp_dir" Linux apt-get 92
  stub_commands "$temp_dir/bin" git tmux jq shellcheck yq curl node \
    mise go uv td graphify no-mistakes opencode claude
  cat > "$temp_dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == 'auth' ]] && exit 1
exit 0
EOF
  chmod +x "$temp_dir/bin/gh"
  stub_sergeant_install "$temp_dir/home"

  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin:$SYSTEM_PATH" "$BOOTSTRAP")"

  assert_contains "$output" 'MANUAL: run gh auth login'
}

test_bootstrap_reports_preserved_command_conflicts() {
  local temp_dir output status
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  stub_platform "$temp_dir" Linux apt-get 88
  mkdir -p "$temp_dir/home/.local/bin"
  printf 'custom command\n' > "$temp_dir/home/.local/bin/sgt-list"
  stub_sergeant_install "$temp_dir/home"
  stub_commands "$temp_dir/bin" git gh tmux jq shellcheck yq curl node \
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

test_managed_tool_conflict_is_preserved() {
  local temp_dir output status
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  stub_platform "$temp_dir" Linux apt-get 85
  mkdir -p "$temp_dir/home/.local/bin"
  printf 'not really uv\n' > "$temp_dir/home/.local/bin/uv"
  stub_commands "$temp_dir/bin" git gh tmux jq shellcheck yq curl node \
    mise go td graphify no-mistakes opencode claude

  set +e
  output="$(HOME="$temp_dir/home" PATH="$temp_dir/bin:$SYSTEM_PATH" "$BOOTSTRAP" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 1 ]] || fail "expected managed tool conflict exit 1, got $status"
  assert_contains "$output" 'CONFLICT:'
  [[ "$(cat "$temp_dir/home/.local/bin/uv")" == 'not really uv' ]] || \
    fail 'bootstrap overwrote a conflicting managed tool'
}

# A bootstrap invoked through its installed symlink must still resolve the
# checkout it belongs to. Resolving to $HOME instead would make it enumerate no
# Sergeant commands at all and silently report a complete installation.
test_bootstrap_resolves_repo_root_through_installed_symlink() {
  local temp_dir output
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

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
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

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
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

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
  local temp_dir
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  mkdir -p "$temp_dir/home/.config/opencode/plugins" "$temp_dir/bin"
  printf 'custom command\n' > "$temp_dir/bin/sgt-list"
  printf 'custom plugin\n' > "$temp_dir/home/.config/opencode/plugins/oc-inject.js"

  HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/bin" "$INSTALL" >/dev/null

  [[ "$(cat "$temp_dir/bin/sgt-list")" == 'custom command' ]] || \
    fail 'sgt-install overwrote an existing command'
  [[ "$(cat "$temp_dir/home/.config/opencode/plugins/oc-inject.js")" == 'custom plugin' ]] || \
    fail 'sgt-install overwrote existing OpenCode configuration'
}

test_install_reports_preserved_conflicts() {
  local temp_dir output
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  mkdir -p "$temp_dir/bin" "$temp_dir/home"
  printf 'custom command\n' > "$temp_dir/bin/sgt-list"

  output="$(HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/bin" "$INSTALL")"

  assert_contains "$output" 'preserved existing'
  assert_contains "$output" 'Preserved 1 existing'
}

test_install_repoints_stale_sergeant_links() {
  local temp_dir
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  mkdir -p "$temp_dir/bin" "$temp_dir/home"
  ln -s /nonexistent/other-checkout/bin/sgt-list "$temp_dir/bin/sgt-list"

  HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/bin" "$INSTALL" >/dev/null

  [[ "$(readlink "$temp_dir/bin/sgt-list")" == "$ROOT_DIR/bin/sgt-list" ]] || \
    fail 'sgt-install did not repoint a stale Sergeant link to this checkout'
}

test_install_removes_deprecated_oc_inject_links() {
  local temp_dir output
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  mkdir -p "$temp_dir/bin" "$temp_dir/home/.config/opencode/plugins"
  ln -s "$ROOT_DIR/bin/oc-inject" "$temp_dir/bin/oc-inject"
  ln -s "$ROOT_DIR/opencode/plugins/oc-inject.js" \
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
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  mkdir -p "$temp_dir/bin" "$temp_dir/home/.config/opencode/plugins"
  ln -s "$HOST_BASH" "$temp_dir/bin/oc-inject"

  HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/bin" "$INSTALL" >/dev/null

  [[ -L "$temp_dir/bin/oc-inject" ]] || \
    fail 'sgt-install removed an oc-inject link it does not own'
}

test_install_is_idempotent() {
  local temp_dir first second
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  mkdir -p "$temp_dir/bin" "$temp_dir/home"
  first="$(HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/bin" "$INSTALL")"
  second="$(HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/bin" "$INSTALL")"

  [[ "$first" == "$second" ]] || fail 'sgt-install is not idempotent'
}

test_install_installs_git_hooks() {
  local temp_dir git_dir hooks_dir created=false
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  # sgt-install guards its hook step on git being available, so an environment
  # without git has nothing to assert. Report the skip rather than hide it.
  if ! command -v git >/dev/null 2>&1; then
    printf 'SKIP: git hooks (git is not available on this host)\n'
    return 0
  fi

  git_dir="$(git -C "$ROOT_DIR" rev-parse --git-dir)"
  hooks_dir="$git_dir/hooks"
  if [[ ! -d "$hooks_dir" ]]; then
    mkdir -p "$hooks_dir"
    created=true
  fi

  mkdir -p "$temp_dir/bin" "$temp_dir/home"
  HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/bin" "$INSTALL" >/dev/null

  if [[ "$(readlink "$hooks_dir/pre-push" 2>/dev/null || true)" != "$ROOT_DIR/scripts/hooks/pre-push" ]]; then
    "$created" && rm -rf "$hooks_dir"
    fail 'sgt-install did not link scripts/hooks/pre-push into the git hooks directory'
  fi
  "$created" && rm -rf "$hooks_dir"
  return 0
}

test_install_warns_when_target_is_not_on_path() {
  local temp_dir output
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  mkdir -p "$temp_dir/bin" "$temp_dir/home"

  output="$(HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/bin" "$INSTALL")"
  assert_contains "$output" 'is not on your PATH'

  output="$(HOME="$temp_dir/home" SGT_INSTALL_DIR="$temp_dir/bin" \
    PATH="$temp_dir/bin:$PATH" "$INSTALL")"
  assert_not_contains "$output" 'is not on your PATH'
}

# ── Manifest ──────────────────────────────────────────────────────────────────

test_manifest_excludes_non_regular_and_deprecated_entries() {
  local sources
  sources="$(_sgt_install_sources "$ROOT_DIR")"

  assert_contains "$sources" "$ROOT_DIR/bin/sgt-dispatch"
  assert_contains "$sources" "$ROOT_DIR/bin/_sgt-lib.sh"
  assert_contains "$sources" "$ROOT_DIR/bin/wiki-daily-digest"
  assert_not_contains "$sources" "$ROOT_DIR/bin/oc-inject"
  assert_not_contains "$sources" '__pycache__'
}

test_linux_dry_run_plans_apt_packages
test_macos_dry_run_plans_homebrew_packages
test_unsupported_platform_fails_clearly
test_missing_package_manager_fails_clearly
test_modes_are_mutually_exclusive
test_unknown_option_fails_clearly
test_dry_run_does_not_plan_installed_packages
test_dry_run_plans_workspace_tools_without_changes
test_dry_run_plans_no_global_agent_configuration
test_dry_run_reports_existing_and_conflicting_commands
test_python_yq_is_replaced_with_mikefarah_yq
test_managed_link_is_found_outside_original_path
test_verify_only_reports_missing_without_installing
test_verify_only_does_not_require_deprecated_oc_inject
test_verify_only_reports_wrong_command_link_as_missing
test_package_manager_failure_is_propagated
test_linux_uses_noninteractive_sudo_when_not_root
test_missing_sudo_fails_before_touching_packages
test_workspace_installer_failure_is_propagated
test_bootstrap_makes_no_global_agent_configuration_writes
test_repeated_run_preserves_existing_tools
test_authentication_is_reported_as_manual_action
test_bootstrap_reports_preserved_command_conflicts
test_managed_tool_conflict_is_preserved
test_bootstrap_resolves_repo_root_through_installed_symlink
test_install_links_runtime_helpers
test_installed_commands_resolve_their_helpers
test_install_preserves_existing_user_files
test_install_reports_preserved_conflicts
test_install_repoints_stale_sergeant_links
test_install_removes_deprecated_oc_inject_links
test_install_keeps_foreign_oc_inject_links
test_install_is_idempotent
test_install_installs_git_hooks
test_install_warns_when_target_is_not_on_path
test_manifest_excludes_non_regular_and_deprecated_entries

printf 'PASS: sgt-bootstrap and sgt-install behavior\n'
