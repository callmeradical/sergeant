#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
DOCTOR="$ROOT/bin/sgt-doctor"
trap teardown_fixture EXIT

make_doctor_tmux() {
  cat > "$TEST_TMP/bin/tmux" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-V" ]]; then
  echo 'tmux 1.0.0'
  exit 0
fi
if [[ "${1:-}" == "display-message" ]]; then
  case "${5:-}" in
    '#{pane_id}')
      [[ "${TMUX_TARGET_MISSING:-0}" == "1" ]] && exit 1
      printf '%s\n' "${TMUX_PANE_ID:-%1}"
      exit 0
      ;;
    '#{pane_dead}|#{pane_start_command}')
      [[ "${TMUX_TARGET_MISSING:-0}" == "1" ]] && exit 1
      printf '%s\n' "${TMUX_PANE_INFO:-0|sgt-worker ${TMUX_REPO_DIR:-}}"
      exit 0
      ;;
  esac
fi
exit 0
EOF
  chmod +x "$TEST_TMP/bin/tmux"
}

make_goose_version_command() {
  local version_output="$1"
  cat > "$TEST_TMP/bin/goose" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" ]]; then
  echo "$version_output"
  exit 0
fi
exit 0
EOF
  chmod +x "$TEST_TMP/bin/goose"
}

test_healthy_installation() {
  local output status
  setup_fixture

  set +e
  output="$("$DOCTOR" 2>&1)"
  status=$?
  set -e

  assert_eq 0 "$status"
  assert_contains "$output" "Sergeant doctor"
  assert_contains "$output" "0 warning(s), 0 failure(s)"
  for check_id in tools.yq tools.git tools.gh tools.tmux tools.python3 tools.td \
    tools.no-mistakes tools.graphify tools.treehouse tools.babydriver tools.mise \
    agents.harness github.auth; do
    assert_contains "$output" "[PASS] $check_id"
  done
  assert_contains "$output" "[PASS] config.repo.app.app"
  assert_contains "$output" "[PASS] td.app.app"
  assert_contains "$output" "[PASS] install.sgt-doctor"
  assert_contains "$output" "[PASS] install._sgt-lib.sh"
  assert_contains "$output" "[PASS] install._sgt-response-lock.sh"
  assert_contains "$output" "[PASS] install.oc-inject"
  assert_contains "$output" "[PASS] install.wiki-daily-digest"
  assert_contains "$output" "[PASS] integrations.opencode-plugin"
  assert_contains "$output" "[PASS] skills.opencode"
  assert_contains "$output" "[PASS] skills.claude"
  assert_contains "$output" "[PASS] runtime.config"
  assert_contains "$output" "[PASS] runtime.fleet"
  assert_contains "$output" "[PASS] fleet.state"
}

test_installed_symlink_runs_against_source_checkout() {
  local output status
  setup_fixture

  set +e
  output="$("$SGT_INSTALL_DIR/sgt-doctor" 2>&1)"
  status=$?
  set -e

  assert_eq 0 "$status"
  assert_contains "$output" "0 warning(s), 0 failure(s)"
}

test_missing_optional_tool_is_degraded() {
  local output status
  setup_fixture
  rm "$TEST_TMP/bin/graphify"

  set +e
  output="$("$DOCTOR" 2>&1)"
  status=$?
  set -e

  assert_eq 1 "$status"
  assert_contains "$output" "[WARN] tools.graphify"
  assert_contains "$output" "1 warning(s), 0 failure(s)"
}

test_missing_required_tool_is_broken() {
  local output status
  setup_fixture
  rm "$TEST_TMP/bin/yq"
  make_unavailable_command yq

  set +e
  output="$("$DOCTOR" 2>&1)"
  status=$?
  set -e

  assert_eq 2 "$status"
  assert_contains "$output" "[FAIL] tools.yq"
  assert_contains "$output" "0 warning(s), 1 failure(s)"
}

test_json_output_filters_projects() {
  local output status
  setup_fixture
  printf '%s\n' 'name: [' > "$SERGEANT_CONFIG/broken.yaml"

  set +e
  output="$("$DOCTOR" --project app --json 2>&1)"
  status=$?
  set -e

  assert_eq 0 "$status"
  assert_contains "$output" '"status":"healthy"'
  assert_contains "$output" '"id":"config.project.app"'
  python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<< "$output" \
    || fail "JSON output is not parseable"
}

test_missing_repository_is_broken() {
  local output status
  setup_fixture
  yq eval -i '.repos[0].path = "missing"' "$SERGEANT_CONFIG/app.yaml"

  set +e
  output="$("$DOCTOR" app 2>&1)"
  status=$?
  set -e

  assert_eq 2 "$status"
  assert_contains "$output" "[FAIL] config.repo.app.app"
  assert_contains "$output" "repository path does not exist"
}

test_broken_installed_link_is_broken() {
  local output status
  setup_fixture
  rm "$SGT_INSTALL_DIR/sgt-list"
  ln -s "$TEST_TMP/missing-sgt-list" "$SGT_INSTALL_DIR/sgt-list"

  set +e
  output="$("$DOCTOR" 2>&1)"
  status=$?
  set -e

  assert_eq 2 "$status"
  assert_contains "$output" "[FAIL] install.sgt-list"
  assert_contains "$output" "broken symlink"
}

test_missing_installed_link_is_degraded() {
  local output status
  setup_fixture
  rm "$SGT_INSTALL_DIR/sgt-list"

  set +e
  output="$("$DOCTOR" 2>&1)"
  status=$?
  set -e

  assert_eq 1 "$status"
  assert_contains "$output" "[WARN] install.sgt-list"
  assert_contains "$output" "symlink is missing"
}

test_mismatched_installed_link_is_degraded() {
  local output status
  setup_fixture
  rm "$SGT_INSTALL_DIR/sgt-list"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$TEST_TMP/other-sgt-list"
  chmod +x "$TEST_TMP/other-sgt-list"
  ln -s "$TEST_TMP/other-sgt-list" "$SGT_INSTALL_DIR/sgt-list"

  set +e
  output="$("$DOCTOR" 2>&1)"
  status=$?
  set -e

  assert_eq 1 "$status"
  assert_contains "$output" "[WARN] install.sgt-list"
  assert_contains "$output" "targets a different checkout"
}

test_orphaned_fleet_worker_is_broken() {
  local output status repo_state
  setup_fixture
  repo_state="$SERGEANT_FLEET/task-123/app"
  mkdir -p "$repo_state"
  printf '%s\n' orphaned > "$repo_state/status"
  printf '%s\n' "$HOME/dev/app" > "$repo_state/worktree"

  set +e
  output="$("$DOCTOR" 2>&1)"
  status=$?
  set -e

  assert_eq 2 "$status"
  assert_contains "$output" "[FAIL] fleet.task-123.app"
  assert_contains "$output" "orphaned worker requires recovery"
}

test_project_filter_ignores_unrelated_fleet_tasks() {
  local output status repo_state
  setup_fixture
  repo_state="$SERGEANT_FLEET/task-123/app"
  mkdir -p "$repo_state"
  printf '%s\n' 'Project: other' > "$SERGEANT_FLEET/task-123/brief.md"
  printf '%s\n' orphaned > "$repo_state/status"
  printf '%s\n' "$HOME/dev/app" > "$repo_state/worktree"

  set +e
  output="$("$DOCTOR" app 2>&1)"
  status=$?
  set -e

  assert_eq 0 "$status"
  assert_contains "$output" "[PASS] fleet.state"
  assert_not_contains "$output" "fleet.task-123.app"
}

test_uninitialized_td_database_is_degraded() {
  local output status
  setup_fixture
  make_td_without_database

  set +e
  output="$("$DOCTOR" 2>&1)"
  status=$?
  set -e

  assert_eq 1 "$status"
  assert_contains "$output" "[WARN] td.app.app"
  assert_contains "$output" "td database is unavailable"
}

test_diagnostics_redact_secrets() {
  local output status
  setup_fixture
  cat > "$TEST_TMP/bin/graphify" <<'EOF'
#!/usr/bin/env bash
  echo 'graphify TOKEN = spacedsecret PASSWORD: two words github_pat_supersecret'
EOF
  chmod +x "$TEST_TMP/bin/graphify"

  set +e
  output="$("$DOCTOR" --json 2>&1)"
  status=$?
  set -e

  assert_eq 0 "$status"
  assert_contains "$output" "[REDACTED]"
  assert_not_contains "$output" "spacedsecret"
  assert_not_contains "$output" "two words"
  assert_not_contains "$output" "github_pat_supersecret"
}

test_human_and_json_output_redact_compound_credentials() {
  local output status
  setup_fixture
  cat > "$TEST_TMP/bin/graphify" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo 'graphify 1.0.0 AWS_SECRET_ACCESS_KEY=supersecret PATH=/usr/bin API_TOKEN="top secret-value" ordinary-text'
  exit 0
fi
exit 0
EOF
  chmod +x "$TEST_TMP/bin/graphify"

  set +e
  output="$("$DOCTOR" 2>&1)"
  status=$?
  set -e

  assert_eq 0 "$status"
  assert_contains "$output" "AWS_SECRET_ACCESS_KEY=[REDACTED] PATH=/usr/bin API_TOKEN=[REDACTED] ordinary-text"
  assert_not_contains "$output" "supersecret"
  assert_not_contains "$output" "top secret-value"
  assert_not_contains "$output" "secret-value"
  assert_contains "$output" "PATH=/usr/bin"
  assert_contains "$output" "ordinary-text"

  set +e
  output="$("$DOCTOR" --json 2>&1)"
  status=$?
  set -e

  assert_eq 0 "$status"
  assert_contains "$output" "AWS_SECRET_ACCESS_KEY=[REDACTED] PATH=/usr/bin API_TOKEN=[REDACTED] ordinary-text"
  assert_not_contains "$output" "supersecret"
  assert_not_contains "$output" "top secret-value"
  assert_not_contains "$output" "secret-value"
  assert_contains "$output" "PATH=/usr/bin"
  assert_contains "$output" "ordinary-text"
  "$REAL_PYTHON3" -c 'import json,sys; json.loads(sys.stdin.read())' <<< "$output" \
    || fail "JSON output is not parseable"
}

test_human_and_json_output_redact_compound_credentials_without_python() {
  local output status
  setup_fixture
  make_unavailable_command python3
  cat > "$TEST_TMP/bin/graphify" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo 'graphify 1.0.0 API_TOKEN="top secret-value" ordinary-text AWS_SECRET_ACCESS_KEY=supersecret PATH=/usr/bin'
  exit 0
fi
exit 0
EOF
  chmod +x "$TEST_TMP/bin/graphify"

  set +e
  output="$("$DOCTOR" 2>&1)"
  status=$?
  set -e

  assert_eq 2 "$status"
  assert_contains "$output" "API_TOKEN=[REDACTED] ordinary-text AWS_SECRET_ACCESS_KEY=[REDACTED] PATH=/usr/bin"
  assert_not_contains "$output" "top secret-value"
  assert_not_contains "$output" "secret-value"
  assert_not_contains "$output" "supersecret"

  set +e
  output="$("$DOCTOR" --json 2>&1)"
  status=$?
  set -e

  assert_eq 2 "$status"
  assert_contains "$output" "API_TOKEN=[REDACTED] ordinary-text AWS_SECRET_ACCESS_KEY=[REDACTED] PATH=/usr/bin"
  assert_not_contains "$output" "top secret-value"
  assert_not_contains "$output" "secret-value"
  assert_not_contains "$output" "supersecret"
  "$REAL_PYTHON3" -c 'import json,sys; json.loads(sys.stdin.read())' <<< "$output" \
    || fail "JSON output is not parseable"
}

test_invalid_project_arguments_exit_64() {
  local output status
  setup_fixture

  set +e
  output="$("$DOCTOR" --project --json 2>&1)"
  status=$?
  set -e
  assert_eq 64 "$status"
  assert_contains "$output" "--project requires a name"

  set +e
  output="$("$DOCTOR" app --project other 2>&1)"
  status=$?
  set -e
  assert_eq 64 "$status"
  assert_contains "$output" "project specified more than once"

  set +e
  output="$("$DOCTOR" -x 2>&1)"
  status=$?
  set -e
  assert_eq 64 "$status"
  assert_contains "$output" "unknown option: -x"
}

test_argument_errors_redact_github_tokens() {
  local output status
  setup_fixture

  set +e
  output="$("$DOCTOR" --ghp_argumentsecret 2>&1)"
  status=$?
  set -e

  assert_eq 64 "$status"
  assert_contains "$output" "[REDACTED]"
  assert_not_contains "$output" "ghp_argumentsecret"
}

test_argument_errors_redact_compound_credentials() {
  local output status
  setup_fixture

  set +e
  output="$("$DOCTOR" '--AWS_SECRET_ACCESS_KEY="top secret-value" PATH=/usr/bin' 2>&1)"
  status=$?
  set -e

  assert_eq 64 "$status"
  assert_contains "$output" 'AWS_SECRET_ACCESS_KEY=[REDACTED] PATH=/usr/bin'
  assert_not_contains "$output" "top secret-value"
  assert_not_contains "$output" "secret-value"
}

test_check_ids_redact_github_tokens() {
  local output status
  setup_fixture

  set +e
  output="$("$DOCTOR" github_pat_projectsecret 2>&1)"
  status=$?
  set -e

  assert_eq 2 "$status"
  assert_contains "$output" "[FAIL] config.project.[REDACTED]"
  assert_not_contains "$output" "github_pat_projectsecret"
}

test_check_ids_redact_compound_credentials() {
  local output status
  setup_fixture

  set +e
  output="$("$DOCTOR" 'AWS_SECRET_ACCESS_KEY="top secret-value" PATH=/usr/bin' 2>&1)"
  status=$?
  set -e

  assert_eq 2 "$status"
  assert_contains "$output" '[FAIL] config.project.AWS_SECRET_ACCESS_KEY=[REDACTED] PATH=/usr/bin'
  assert_not_contains "$output" "top secret-value"
  assert_not_contains "$output" "secret-value"
}

test_empty_agent_skill_directory_is_degraded() {
  local output status
  setup_fixture
  rm -rf "$HOME/.config/opencode/skills/fixture"

  set +e
  output="$("$DOCTOR" 2>&1)"
  status=$?
  set -e

  assert_eq 1 "$status"
  assert_contains "$output" "[WARN] skills.opencode"
  assert_contains "$output" "contains no SKILL.md files"
}

test_failed_graphify_probe_is_degraded() {
  local output status
  setup_fixture
  make_unavailable_command graphify

  set +e
  output="$("$DOCTOR" 2>&1)"
  status=$?
  set -e

  assert_eq 1 "$status"
  assert_contains "$output" "[WARN] tools.graphify"
  assert_contains "$output" "installed command is not usable"
}

test_duplicate_repository_names_are_broken() {
  local output status
  setup_fixture
  yq eval -i '.repos += [{"name":"app","path":"app"}]' "$SERGEANT_CONFIG/app.yaml"

  set +e
  output="$("$DOCTOR" app 2>&1)"
  status=$?
  set -e

  assert_eq 2 "$status"
  assert_contains "$output" "[FAIL] config.project.app"
  assert_contains "$output" "repo names must be unique"
}

test_malformed_project_yaml_is_broken() {
  local output status
  setup_fixture
  printf '%s\n' 'name: [' > "$SERGEANT_CONFIG/broken.yaml"

  set +e
  output="$("$DOCTOR" 2>&1)"
  status=$?
  set -e

  assert_eq 2 "$status"
  assert_contains "$output" "[FAIL] config.project.broken"
  assert_contains "$output" "project YAML cannot be parsed"
}

test_remote_drift_is_degraded() {
  local output status
  setup_fixture
  git -C "$HOME/dev/app" remote set-url origin git@github.com:example/other.git

  set +e
  output="$("$DOCTOR" app 2>&1)"
  status=$?
  set -e

  assert_eq 1 "$status"
  assert_contains "$output" "[WARN] config.repo.app.app"
  assert_contains "$output" "configured URL does not match"
}

test_missing_origin_remote_is_broken() {
  local output status
  setup_fixture
  git -C "$HOME/dev/app" remote remove origin

  set +e
  output="$("$DOCTOR" app 2>&1)"
  status=$?
  set -e

  assert_eq 2 "$status"
  assert_contains "$output" "[FAIL] config.repo.app.app"
  assert_contains "$output" "origin remote is missing"
}

test_dead_tmux_pane_is_broken() {
  local output status repo_state
  setup_fixture
  repo_state="$SERGEANT_FLEET/task-123/app"
  mkdir -p "$repo_state"
  printf '%s\n' in_progress > "$repo_state/status"
  printf '%s\n' "$HOME/dev/app" > "$repo_state/worktree"
  printf '%s\n' %999 > "$repo_state/pane"
  cat > "$TEST_TMP/bin/tmux" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "-V" ]] && { echo 'tmux 1.0.0'; exit 0; }
exit 1
EOF
  chmod +x "$TEST_TMP/bin/tmux"

  set +e
  output="$("$DOCTOR" 2>&1)"
  status=$?
  set -e

  assert_eq 2 "$status"
  assert_contains "$output" "[FAIL] fleet.task-123.app"
  assert_contains "$output" "dead tmux pane"
}

test_tmux_probe_uses_dash_v() {
  local output status
  setup_fixture
  cat > "$TEST_TMP/bin/tmux" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "-V" ]] && { echo 'tmux 3.4'; exit 0; }
exit 1
EOF
  chmod +x "$TEST_TMP/bin/tmux"

  set +e
  output="$("$DOCTOR" 2>&1)"
  status=$?
  set -e

  assert_eq 0 "$status"
  assert_contains "$output" "[PASS] tools.tmux: tmux 3.4"
}

test_stale_nonterminal_worker_is_degraded() {
  local output status repo_state
  setup_fixture
  repo_state="$SERGEANT_FLEET/task-123/app"
  mkdir -p "$repo_state"
  printf '%s\n' in_progress > "$repo_state/status"
  printf '%s\n' "$HOME/dev/app" > "$repo_state/worktree"
  printf '%s\n' %1 > "$repo_state/pane"
  touch -t 202001010000 "$repo_state/status"
  make_doctor_tmux
  export TMUX_REPO_DIR="$repo_state"

  set +e
  output="$("$DOCTOR" 2>&1)"
  status=$?
  set -e

  assert_eq 1 "$status"
  assert_contains "$output" "[WARN] fleet.task-123.app"
  assert_contains "$output" "unchanged for more than seven days"
}

test_doctor_does_not_mutate_runtime_state() {
  local before after
  setup_fixture
  before="$(fixture_digest)"
  "$DOCTOR" >/dev/null
  after="$(fixture_digest)"
  assert_eq "$before" "$after"
}

test_unsynchronized_fleet_status_is_degraded() {
  local output status repo_state
  setup_fixture
  repo_state="$SERGEANT_FLEET/task-123/app"
  mkdir -p "$repo_state"
  printf '%s\n' in_progress > "$repo_state/status"
  printf '%s\n' "$HOME/dev/app" > "$repo_state/worktree"
  printf '%s\n' %1 > "$repo_state/pane"
  printf '%s\n' 'done' > "$HOME/dev/app/.sergeant-status"
  make_doctor_tmux
  export TMUX_REPO_DIR="$repo_state"

  set +e
  output="$("$DOCTOR" 2>&1)"
  status=$?
  set -e

  assert_eq 1 "$status"
  assert_contains "$output" "[WARN] fleet.task-123.app"
  assert_contains "$output" "fleet status is stale"
}

test_live_worker_without_persisted_pane_metadata_is_healthy() {
  local output status repo_state
  setup_fixture
  repo_state="$SERGEANT_FLEET/task-123/app"
  mkdir -p "$repo_state"
  printf '%s\n' in_progress > "$repo_state/status"
  printf '%s\n' "$HOME/dev/app" > "$repo_state/worktree"
  make_doctor_tmux
  export TMUX_REPO_DIR="$repo_state"

  set +e
  output="$("$DOCTOR" 2>&1)"
  status=$?
  set -e

  assert_eq 0 "$status"
  assert_contains "$output" "[PASS] fleet.task-123.app"
  assert_contains "$output" "tmux pane are live"
}

test_reused_tmux_pane_is_broken() {
  local output status repo_state
  setup_fixture
  repo_state="$SERGEANT_FLEET/task-123/app"
  mkdir -p "$repo_state"
  printf '%s\n' in_progress > "$repo_state/status"
  printf '%s\n' "$HOME/dev/app" > "$repo_state/worktree"
  printf '%s\n' %1 > "$repo_state/pane"
  make_doctor_tmux
  export TMUX_PANE_INFO='0|bash /tmp/other-worker'

  set +e
  output="$("$DOCTOR" 2>&1)"
  status=$?
  set -e

  assert_eq 2 "$status"
  assert_contains "$output" "[FAIL] fleet.task-123.app"
  assert_contains "$output" "stale or reused tmux pane"
}

test_remote_worker_without_tmux_metadata_is_degraded() {
  local output status repo_state
  setup_fixture
  repo_state="$SERGEANT_FLEET/task-123/app"
  mkdir -p "$repo_state"
  printf '%s\n' in_progress > "$repo_state/status"
  printf '%s\n' "$HOME/dev/app" > "$repo_state/worktree"
  cat > "$TEST_TMP/bin/tmux" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "-V" ]] && { echo 'tmux 1.0.0'; exit 0; }
exit 1
EOF
  chmod +x "$TEST_TMP/bin/tmux"

  set +e
  output="$("$DOCTOR" 2>&1)"
  status=$?
  set -e

  assert_eq 1 "$status"
  assert_contains "$output" "[WARN] fleet.task-123.app"
  assert_contains "$output" "cannot verify a local tmux pane"
}

test_default_opencode_selection_must_be_usable() {
  local output status
  setup_fixture
  rm -f "$TEST_TMP/bin/opencode" "$TEST_TMP/bin/claude"
  make_fake_command goose

  set +e
  output="$("$DOCTOR" 2>&1)"
  status=$?
  set -e

  assert_eq 2 "$status"
  assert_contains "$output" "[FAIL] agents.harness"
  assert_contains "$output" "default selects opencode, but it is not installed"
}

test_goose_override_is_healthy() {
  local output status
  setup_fixture
  rm -f "$TEST_TMP/bin/opencode" "$TEST_TMP/bin/claude"
  make_goose_version_command "goose 1.10.0"
  export SERGEANT_AGENT=goose

  set +e
  output="$("$DOCTOR" 2>&1)"
  status=$?
  set -e

  unset SERGEANT_AGENT

  assert_eq 0 "$status"
  assert_contains "$output" "[PASS] agents.harness: SERGEANT_AGENT selects goose (goose 1.10.0)"
}

test_goose_override_requires_compatible_version() {
  local output status
  setup_fixture
  rm -f "$TEST_TMP/bin/opencode" "$TEST_TMP/bin/claude"
  make_goose_version_command "goose 1.9.9"
  export SERGEANT_AGENT=goose

  set +e
  output="$("$DOCTOR" 2>&1)"
  status=$?
  set -e

  unset SERGEANT_AGENT

  assert_eq 2 "$status"
  assert_contains "$output" "[FAIL] agents.harness"
  assert_contains "$output" "Goose 1.10+ is required for resumable sessions"
}

test_goose_override_with_unparseable_version_is_degraded() {
  local output status
  setup_fixture
  rm -f "$TEST_TMP/bin/opencode" "$TEST_TMP/bin/claude"
  make_goose_version_command "goose prerelease build"
  export SERGEANT_AGENT=goose

  set +e
  output="$("$DOCTOR" 2>&1)"
  status=$?
  set -e

  unset SERGEANT_AGENT

  assert_eq 1 "$status"
  assert_contains "$output" "[WARN] agents.harness"
  assert_contains "$output" "version output is unparseable"
}

test_explicit_agent_override_must_be_usable() {
  local output status
  setup_fixture
  rm -f "$TEST_TMP/bin/goose"
  export SERGEANT_AGENT=goose

  set +e
  output="$("$DOCTOR" 2>&1)"
  status=$?
  set -e

  unset SERGEANT_AGENT

  assert_eq 2 "$status"
  assert_contains "$output" "[FAIL] agents.harness"
  assert_contains "$output" "SERGEANT_AGENT selects goose, but it is not installed"
}

test_opencode_auto_selection_must_be_usable() {
  local output status
  setup_fixture
  rm -f "$TEST_TMP/bin/opencode"
  export OPENCODE=1

  set +e
  output="$("$DOCTOR" 2>&1)"
  status=$?
  set -e

  unset OPENCODE

  assert_eq 2 "$status"
  assert_contains "$output" "[FAIL] agents.harness"
  assert_contains "$output" "auto-detected opencode, but it is not installed"
}

test_claude_auto_selection_must_be_usable() {
  local output status
  setup_fixture
  rm -f "$TEST_TMP/bin/claude"
  export CLAUDE_CODE_SESSION_ID=session-123

  set +e
  output="$("$DOCTOR" 2>&1)"
  status=$?
  set -e

  unset CLAUDE_CODE_SESSION_ID

  assert_eq 2 "$status"
  assert_contains "$output" "[FAIL] agents.harness"
  assert_contains "$output" "auto-detected claude, but it is not installed"
}

test_missing_response_lock_install_link_is_degraded() {
  local output status
  setup_fixture
  rm "$SGT_INSTALL_DIR/_sgt-response-lock.sh"

  set +e
  output="$("$DOCTOR" 2>&1)"
  status=$?
  set -e

  assert_eq 1 "$status"
  assert_contains "$output" "[WARN] install._sgt-response-lock.sh"
  assert_contains "$output" "symlink is missing"
}

test_broken_response_lock_install_link_is_broken() {
  local output status
  setup_fixture
  rm "$SGT_INSTALL_DIR/_sgt-response-lock.sh"
  ln -s "$TEST_TMP/missing-response-lock" "$SGT_INSTALL_DIR/_sgt-response-lock.sh"

  set +e
  output="$("$DOCTOR" 2>&1)"
  status=$?
  set -e

  assert_eq 2 "$status"
  assert_contains "$output" "[FAIL] install._sgt-response-lock.sh"
  assert_contains "$output" "broken symlink"
}

test_invalid_global_config_does_not_cascade_repo_failures() {
  local output status
  setup_fixture
  printf '%s\n' 'dev_root: [' > "$SERGEANT_CONFIG/config.yaml"

  set +e
  output="$("$DOCTOR" app 2>&1)"
  status=$?
  set -e

  assert_eq 2 "$status"
  assert_contains "$output" "[FAIL] config.global"
  assert_not_contains "$output" "repository path does not exist"
}

test_missing_fleet_metadata_is_reported_without_shell_errors() {
  local output status
  setup_fixture
  mkdir -p "$SERGEANT_FLEET/task-123/app"

  set +e
  output="$("$DOCTOR" 2>&1)"
  status=$?
  set -e

  assert_eq 2 "$status"
  assert_contains "$output" "fleet status is missing"
  assert_not_contains "$output" "No such file or directory"
}

test_healthy_installation
echo "PASS: healthy installation"
test_installed_symlink_runs_against_source_checkout
echo "PASS: installed doctor symlink"
test_missing_optional_tool_is_degraded
echo "PASS: degraded installation"
test_missing_required_tool_is_broken
echo "PASS: broken installation"
test_json_output_filters_projects
echo "PASS: JSON project filter"
test_missing_repository_is_broken
echo "PASS: missing repository"
test_broken_installed_link_is_broken
echo "PASS: broken installed link"
test_missing_installed_link_is_degraded
echo "PASS: missing installed link"
test_mismatched_installed_link_is_degraded
echo "PASS: mismatched installed link"
test_orphaned_fleet_worker_is_broken
echo "PASS: orphaned fleet worker"
test_project_filter_ignores_unrelated_fleet_tasks
echo "PASS: project-scoped fleet filter"
test_uninitialized_td_database_is_degraded
echo "PASS: uninitialized td database"
test_diagnostics_redact_secrets
echo "PASS: secret redaction"
test_human_and_json_output_redact_compound_credentials
echo "PASS: compound credential output redaction"
test_human_and_json_output_redact_compound_credentials_without_python
echo "PASS: compound credential output redaction without python"
test_invalid_project_arguments_exit_64
echo "PASS: invalid project arguments"
test_check_ids_redact_github_tokens
echo "PASS: check ID redaction"
test_check_ids_redact_compound_credentials
echo "PASS: compound credential check ID redaction"
test_argument_errors_redact_github_tokens
echo "PASS: argument error redaction"
test_argument_errors_redact_compound_credentials
echo "PASS: compound credential argument redaction"
test_empty_agent_skill_directory_is_degraded
echo "PASS: empty agent skill directory"
test_failed_graphify_probe_is_degraded
echo "PASS: failed graphify probe"
test_duplicate_repository_names_are_broken
echo "PASS: duplicate repository names"
test_malformed_project_yaml_is_broken
echo "PASS: malformed project YAML"
test_remote_drift_is_degraded
echo "PASS: remote drift"
test_missing_origin_remote_is_broken
echo "PASS: missing origin remote"
test_dead_tmux_pane_is_broken
echo "PASS: dead tmux pane"
test_tmux_probe_uses_dash_v
echo "PASS: tmux dash-V probe"
test_stale_nonterminal_worker_is_degraded
echo "PASS: stale fleet worker"
test_doctor_does_not_mutate_runtime_state
echo "PASS: read-only diagnostics"
test_unsynchronized_fleet_status_is_degraded
echo "PASS: stale fleet metadata"
test_live_worker_without_persisted_pane_metadata_is_healthy
echo "PASS: inferred live fleet pane"
test_reused_tmux_pane_is_broken
echo "PASS: reused tmux pane"
test_remote_worker_without_tmux_metadata_is_degraded
echo "PASS: remote fleet worker"
test_default_opencode_selection_must_be_usable
echo "PASS: default opencode selection"
test_goose_override_is_healthy
echo "PASS: goose override"
test_goose_override_requires_compatible_version
echo "PASS: goose minimum version"
test_goose_override_with_unparseable_version_is_degraded
echo "PASS: goose unparseable version"
test_explicit_agent_override_must_be_usable
echo "PASS: explicit agent override"
test_opencode_auto_selection_must_be_usable
echo "PASS: opencode auto selection"
test_claude_auto_selection_must_be_usable
echo "PASS: claude auto selection"
test_missing_response_lock_install_link_is_degraded
echo "PASS: missing response lock install link"
test_broken_response_lock_install_link_is_broken
echo "PASS: broken response lock install link"
test_invalid_global_config_does_not_cascade_repo_failures
echo "PASS: invalid global config"
test_missing_fleet_metadata_is_reported_without_shell_errors
echo "PASS: missing fleet metadata"
