#!/usr/bin/env bash
# sgt-context prints the project-level agent_instructions once, not once per
# repository, and keeps the group and repository layers per repository (#387).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/config"
cat > "$TEST_ROOT/config/test.yaml" <<YAML
name: test
defaults:
  agent_instructions: |
    PROJECT-LAYER-RULE
repos:
  - name: api
    path: $TEST_ROOT/api
    group: BACKEND
    agent_instructions: |
      API-REPO-RULE
  - name: web
    path: $TEST_ROOT/web
  - name: docs
    path: $TEST_ROOT/docs
groups:
  BACKEND:
    description: Backend fixture group
    agent_instructions: |
      BACKEND-GROUP-RULE
YAML

output="$(SERGEANT_CONFIG="$TEST_ROOT/config" "$ROOT_DIR/bin/sgt-context" test)"

fail() {
  printf 'FAIL: %s\n%s\n' "$1" "$output" >&2
  exit 1
}

count() {
  printf '%s\n' "$output" | grep -cF -- "$1" || true
}

[[ "$(count 'PROJECT-LAYER-RULE')" -eq 1 ]] || fail 'project instructions are not printed exactly once'
[[ "$(count 'BACKEND-GROUP-RULE')" -eq 1 ]] || fail 'group instructions are not printed exactly once'
[[ "$(count 'API-REPO-RULE')" -eq 1 ]] || fail 'repository instructions are not printed exactly once'

line_of() {
  printf '%s\n' "$output" | grep -nF -- "$1" | cut -d: -f1 | sed -n '1p'
}

project_section="$(line_of '## Project instructions')"
repos_section="$(line_of '## Repositories')"
[[ -n "$project_section" ]] || fail 'no Project instructions section'
[[ "$project_section" -lt "$(line_of 'PROJECT-LAYER-RULE')" ]] || fail 'project rule is outside its section'
[[ "$(line_of 'PROJECT-LAYER-RULE')" -lt "$repos_section" ]] || fail 'project rule is not before the repositories'

# Group and repository layers stay under their repository, in layer order.
api="$(line_of '### api')"
web="$(line_of '### web')"
group_rule="$(line_of 'BACKEND-GROUP-RULE')"
repo_rule="$(line_of 'API-REPO-RULE')"
[[ "$api" -lt "$group_rule" && "$group_rule" -lt "$repo_rule" && "$repo_rule" -lt "$web" ]] ||
  fail 'group and repository layers are not under their repository in order'

# The output states that the project layer applies to every repository first.
printf '%s\n' "$output" | grep -qF 'apply to every repository' ||
  fail 'output does not state that project instructions apply to every repository'

printf 'PASS: sgt-context prints project instructions once\n'
