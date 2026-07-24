#!/usr/bin/env bash

set -euo pipefail
export TMUX=fixture TMUX_PANE=%11

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p \
  "$TEST_ROOT/config" \
  "$TEST_ROOT/fleet" \
  "$TEST_ROOT/fake-bin" \
  "$TEST_ROOT/repo" \
  "$TEST_ROOT/role-repo" \
  "$TEST_ROOT/group-repo"

cat > "$TEST_ROOT/config/test.yaml" <<EOF
name: test
repos:
  - name: app
    path: $TEST_ROOT/repo
    role: Test fixture
  - name: role-ui
    path: $TEST_ROOT/role-repo
    role: User-Facing Output
  - name: group-ui
    path: $TEST_ROOT/group-repo
    group: FRONTEND
groups:
  FRONTEND:
    description: UI fixture group
EOF

cat > "$TEST_ROOT/fake-bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  new-window)
    for repo_state in "$SERGEANT_FLEET"/*/*; do
      [[ -d "$repo_state" ]] || continue
      notification_id="$(cat "$repo_state/notification_id")"
      worktree="$(cat "$repo_state/worktree")"
      printf '%s|0|%%42|4242|123456|fixture-worker-command\n' "$notification_id" \
        > "$worktree/.sergeant-notification-ack"
      printf '0|%%42|4242|123456|fixture-worker-command\n' \
        > "$repo_state/notification_delivered_pane_identity"
      printf '%s\n' "$notification_id" > "$repo_state/notification_delivered"
    done
    printf '%%42\n'
    ;;
  display-message)
    [[ "$*" == *'-t %11'* ]] && printf '0|%%11|1111|111111|coordinator-command\n' || \
      printf '0|%%42|4242|123456|fixture-worker-command\n'
    ;;
esac
exit 0
EOF
chmod +x "$TEST_ROOT/fake-bin/tmux"

cat > "$TEST_ROOT/fake-bin/td" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

if [[ "${1:-}" == "--version" ]]; then
  printf 'td version v0.51.2\n'
  exit 0
fi
if [[ "${1:-}" == "create" && "${2:-}" == "--help" ]]; then
  printf '%s\n' 'Usage: td create TITLE --description TEXT --json --work-dir DIR'
  exit 0
fi

work_dir=""
args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-dir|-w)
      work_dir="$2"
      shift 2
      ;;
    --json)
      shift
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done

set -- "${args[@]}"
case "${1:-}" in
  list)
    printf '[]\n'
    ;;
  create)
    printf '{"id":"td-app-1"}\n'
    ;;
  delete)
    printf '{"id":"td-app-1","deleted":true}\n'
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/td"

git -C "$TEST_ROOT/repo" init -q
git -C "$TEST_ROOT/repo" config user.name "Sergeant Test"
git -C "$TEST_ROOT/repo" config user.email "sergeant@example.invalid"
touch "$TEST_ROOT/repo/README.md"
git -C "$TEST_ROOT/repo" add README.md
git -C "$TEST_ROOT/repo" commit -qm "test fixture"

for repo_dir in "$TEST_ROOT/role-repo" "$TEST_ROOT/group-repo"; do
  git -C "$repo_dir" init -q
  git -C "$repo_dir" config user.name "Sergeant Test"
  git -C "$repo_dir" config user.email "sergeant@example.invalid"
  touch "$repo_dir/README.md"
  git -C "$repo_dir" add README.md
  git -C "$repo_dir" commit -qm "test fixture"
done

PATH="$TEST_ROOT/fake-bin:$PATH" \
SERGEANT_CONFIG="$TEST_ROOT/config" \
SERGEANT_FLEET="$TEST_ROOT/fleet" \
SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test "Harden worker loop" --repos app >/dev/null

brief="$(printf '%s\n' "$TEST_ROOT"/app-sgt-*/.sergeant-brief.md)"
[[ -f "$brief" ]] || { printf 'brief was not generated\n' >&2; exit 1; }

task_dir="$(printf '%s\n' "$TEST_ROOT"/fleet/*)"
fleet_intent="$task_dir/.sergeant-intent.md"
worktree_intent="$(dirname "$brief")/.sergeant-intent.md"
[[ -f "$fleet_intent" && -f "$worktree_intent" ]] || {
  printf 'canonical intent was not generated in fleet state and worktree\n' >&2
  exit 1
}
cmp -s "$fleet_intent" "$worktree_intent" || {
  printf 'fleet and worktree intent revisions differ\n' >&2
  exit 1
}
[[ "$(grep -c '^## ' "$fleet_intent")" -eq 8 ]] || {
  printf 'canonical intent does not contain exactly eight sections\n' >&2
  exit 1
}
for section in \
  'Objective' \
  'Required Invariants' \
  'Approved Tradeoffs' \
  'Out Of Scope' \
  'State Transitions' \
  'Failure Windows' \
  'Negative Test Matrix' \
  'Validation Evidence'; do
  grep -Fxq "## $section" "$fleet_intent" || {
    printf 'canonical intent is missing section: %s\n' "$section" >&2
    exit 1
  }
done
grep -Fq 'Intent path: standard-isolated' "$fleet_intent" || {
  printf 'normal dispatch did not use the named lighter intent path\n' >&2
  exit 1
}
grep -Fxq 'Harden worker loop' "$fleet_intent" || {
  printf 'canonical intent did not preserve the dispatch objective\n' >&2
  exit 1
}

cat > "$TEST_ROOT/approved-intent.md" <<'EOF'
# Sergeant Intent

## Objective

Apply the approved database migration.

## Required Invariants

Existing records remain readable.

## Approved Tradeoffs

A bounded maintenance window is approved.

## Out Of Scope

No schema cleanup.

## State Transitions

Validate, migrate, verify, then publish.

## Failure Windows

Rollback before publication if verification fails.

## Negative Test Matrix

Cover invalid legacy rows and interrupted migration recovery.

## Validation Evidence

Record migration dry-run, rollback, and native test evidence.
EOF

PATH="$TEST_ROOT/fake-bin:$PATH" \
SERGEANT_CONFIG="$TEST_ROOT/config" \
SERGEANT_FLEET="$TEST_ROOT/fleet" \
SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test "Deploy database migration" --repos app \
    --intent-file "$TEST_ROOT/approved-intent.md" >/dev/null

safety_intent="$(grep -rlFx 'Apply the approved database migration.' "$TEST_ROOT"/fleet/*/.sergeant-intent.md)"
[[ -f "$safety_intent" ]] || {
  printf 'explicit safety intent was not persisted\n' >&2
  exit 1
}
safety_task_dir="$(dirname "$safety_intent")"
cmp -s "$TEST_ROOT/approved-intent.md" "$safety_intent"
actual_revision="$(bash -c 'source "$1/bin/_sgt-intent.sh"; _sgt_intent_revision "$2"' \
  _ "$ROOT_DIR" "$safety_intent")"
[[ "$actual_revision" =~ ^[a-f0-9]{64}$ ]]
cmp -s "$safety_intent" "$(cat "$safety_task_dir/app/worktree")/.sergeant-intent.md"
if grep -Fq "$TEST_ROOT/approved-intent.md" "$(cat "$safety_task_dir/app/worktree")/.sergeant-brief.md"; then
  printf 'worker brief leaked the private intent source path\n' >&2
  exit 1
fi

assert_intent_rejected_without_mutation() {
  local expected="$1"
  shift
  local before_fleet before_worktrees output status
  before_fleet="$(find "$TEST_ROOT/fleet" -mindepth 1 -maxdepth 1 -type d | wc -l)"
  before_worktrees="$(find "$TEST_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'app-sgt-*' | wc -l)"
  set +e
  output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
    SERGEANT_CONFIG="$TEST_ROOT/config" \
    SERGEANT_FLEET="$TEST_ROOT/fleet" \
    SGT_WIKI_DISABLED=1 \
      "$ROOT_DIR/bin/sgt-dispatch" test "$@" 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 && "$output" == *"$expected"* ]] || {
    printf 'intent input was not rejected as expected (%s): %s\n' "$expected" "$output" >&2
    exit 1
  }
  [[ "$(find "$TEST_ROOT/fleet" -mindepth 1 -maxdepth 1 -type d | wc -l)" == "$before_fleet" ]]
  [[ "$(find "$TEST_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'app-sgt-*' | wc -l)" == "$before_worktrees" ]]
}

assert_intent_rejected_without_mutation \
  'requires --intent-file' 'Deploy database migration' --repos app
for plural_objective in \
  'Rotate credentials' \
  'Reconcile payments' \
  'Back up databases' \
  'Deploy migrations' \
  'Audit state transitions'; do
  assert_intent_rejected_without_mutation \
    'requires --intent-file' "$plural_objective" --repos app
done
assert_intent_rejected_without_mutation \
  'intent file not found' 'Deploy database migration' --repos app --intent-file "$TEST_ROOT/missing.md"
assert_intent_rejected_without_mutation \
  'intent path traversal is not allowed' 'Deploy database migration' --repos app --intent-file '../approved-intent.md'
mkdir "$TEST_ROOT/traversal-component"
assert_intent_rejected_without_mutation \
  'intent path traversal is not allowed' 'Deploy database migration' --repos app --intent-file "$TEST_ROOT/traversal-component/../approved-intent.md"
assert_intent_rejected_without_mutation \
  '--intent-file requires a path' 'Deploy database migration' --repos app --intent-file
ln -s "$TEST_ROOT/approved-intent.md" "$TEST_ROOT/symlink-intent.md"
assert_intent_rejected_without_mutation \
  'intent file must not traverse a symlink' 'Deploy database migration' --repos app --intent-file "$TEST_ROOT/symlink-intent.md"
mkdir "$TEST_ROOT/intent-source"
cp "$TEST_ROOT/approved-intent.md" "$TEST_ROOT/intent-source/intent.md"
ln -s "$TEST_ROOT/intent-source" "$TEST_ROOT/intent-parent-link"
assert_intent_rejected_without_mutation \
  'intent file must not traverse a symlink' 'Deploy database migration' --repos app --intent-file "$TEST_ROOT/intent-parent-link/intent.md"
cp "$TEST_ROOT/approved-intent.md" "$TEST_ROOT/malformed-intent.md"
printf '\n## Objective\nDuplicate objective.\n' >> "$TEST_ROOT/malformed-intent.md"
assert_intent_rejected_without_mutation \
  'intent sections must appear exactly once' 'Deploy database migration' --repos app --intent-file "$TEST_ROOT/malformed-intent.md"
cp "$TEST_ROOT/approved-intent.md" "$TEST_ROOT/control-intent.md"
printf '\001' >> "$TEST_ROOT/control-intent.md"
assert_intent_rejected_without_mutation \
  'intent file contains unsupported control characters' 'Deploy database migration' --repos app --intent-file "$TEST_ROOT/control-intent.md"
dd if=/dev/zero of="$TEST_ROOT/oversized-intent.md" bs=65537 count=1 2>/dev/null
assert_intent_rejected_without_mutation \
  'intent file exceeds 65536 bytes' 'Deploy database migration' --repos app --intent-file "$TEST_ROOT/oversized-intent.md"

assert_contains() {
  local expected="$1"
  grep -Fq "$expected" "$brief" || {
    printf 'missing brief contract: %s\n' "$expected" >&2
    exit 1
  }
}

assert_not_contains() {
  local unexpected="$1"
  if grep -Fq "$unexpected" "$brief"; then
    printf 'unexpected brief contract: %s\n' "$unexpected" >&2
    exit 1
  fi
}

line_of() {
  grep -nF "$1" "$brief" | cut -d: -f1 | sed -n '1p'
}

assert_order() {
  local previous=0 marker line
  for marker in "$@"; do
    line="$(line_of "$marker")"
    [[ -n "$line" && "$line" -gt "$previous" ]] || {
      printf 'brief contract is out of order at: %s\n' "$marker" >&2
      exit 1
    }
    previous="$line"
  done
}

assert_contains "merge-base with the current origin/main"
assert_contains "**td task:** td-app-1"
assert_contains "td start td-app-1 --work-dir ."
assert_contains "td handoff td-app-1 --work-dir ."
assert_contains "td review td-app-1 --work-dir ."
assert_contains "commit list and diff scope"
assert_contains "If no originating spec exists, record that explicitly"
assert_contains ".sergeant-intent.md is the canonical source"
assert_contains "implementation decisions, independent reviews, PR description, and the one final no-mistakes"
assert_contains "Intent revision: $([[ -f "$task_dir/intent_revision" ]] && cat "$task_dir/intent_revision")"
assert_contains "Successor and recovery work must inherit this exact revision"
assert_contains "audited human decision creates a new intent revision"
assert_contains "safety-sensitive or stateful"
assert_contains "State Transitions, Failure Windows, and Negative Test Matrix"
assert_contains "mutation before validation"
assert_contains "partial publication and rollback"
assert_contains "identity and provenance"
assert_contains "stale and legacy states"
assert_contains "suppressed failures"
assert_contains "race windows"
assert_contains "missing negative tests"
assert_contains "zero blockers"
assert_contains "failing focused test"
assert_contains "minimum implementation"
assert_contains "full required suite once at the end"
assert_contains "Never run no-mistakes from this agent process"
assert_contains '.sergeant-validation-ready'
assert_contains 'sgt-validate'
assert_contains "without \`--yes\`"
assert_not_contains "An explicit user instruction to run no-mistakes overrides this default"
assert_not_contains 'no-mistakes axi run --intent'
assert_not_contains "Run no-mistakes when available or required"
assert_contains "### 6. Route no-mistakes findings"
assert_contains "coordinator owns every no-mistakes gate and finding"
assert_contains "Do not approve a validation gate"
assert_contains "separate deduplicated td work"
assert_contains "separate parallel subagents"
assert_contains "Standards axis"
assert_contains "Fowler smell heuristic"
assert_contains "skip findings enforced by tooling"
assert_contains "Spec axis"
assert_contains "If no spec exists, report this axis as skipped"
assert_contains "Do not blend or rerank the axes"
assert_not_contains "Accessibility axis"
assert_contains "blocking findings are zero"
assert_contains "required CI is green"
assert_contains "no unresolved non-outdated review threads"
assert_contains "dependency order is satisfied"
assert_contains "Do not write \`done\` merely because a PR exists"
assert_contains "handoff before td review"
assert_contains "td review only after implementation and review evidence is ready"
assert_contains "### 2. Route the work"
assert_contains "read the full td issue/spec/comments"
assert_contains "check for redundant or prior work"
assert_contains "wayfinding/spec/ticketing blocker"
assert_contains "fast deterministic red-capable command"
assert_contains "rank falsifiable hypotheses"
assert_contains "throwaway prototype"
assert_contains "never promote prototype code directly"
assert_contains "tracer-bullet vertical slices"
assert_contains "Trace both intents to their issues/specs"
assert_contains "never abort automatically"
assert_contains "public behavioral seams"
assert_contains "needs_input rather than guessing"
assert_contains "one vertical slice, test, and minimum implementation at a time"
assert_contains "Reject tautological tests, internal mocking, and horizontal slicing"
assert_contains "Do not speculate ahead"
assert_contains "Supported nonterminal statuses are \`in_progress\`, \`needs_input\`, and \`blocked\`"
assert_contains ".sergeant-message"
assert_contains "2-4 options when useful"
assert_contains "remains alive and waits for a response"
assert_contains ".sergeant-response"
assert_contains ".sergeant-response-id"
assert_contains "sgt-ack-response"
assert_contains ".sergeant-response-applied"
assert_contains "archives replay evidence"
assert_contains "\`done\` with a non-empty result"
assert_contains "\`failed: <nonblank reason>\`"
assert_contains "later \`needs_input\`/\`blocked\` gate generation"
assert_contains "Unexpected exit or invalid proof retains active transport"
assert_contains ".sergeant-gate-generation"
assert_contains "A repeated blocker message is still a new gate only when the generation advances"
assert_contains "Surface \`wayfinder\`, \`to-spec\`, and Sergeant's custom \`to-tickets\` as escalation or planning paths"
assert_contains "Do not silently execute them as implementation"
assert_contains "load and use the canonical \`diagnosing-bugs\` skill"
assert_contains "load and use the canonical \`prototype\` skill"
assert_contains "load and use the canonical \`tdd\` skill before implementation"
assert_contains "load and use the canonical \`resolving-merge-conflicts\` skill"
assert_contains "load and use the canonical \`code-review\` skill"
assert_contains "If a canonical skill cannot be loaded, follow the embedded rules"

assert_order \
  "### 1. Pin scope and source of truth" \
  "### 2. Route the work" \
  "### 3. Implement approved work with TDD" \
  "### 4. Escalate and resume" \
  "### 5. Validate" \
  "### 6. Route no-mistakes findings" \
  "### 7. Independent two-axis review" \
  "### 8. Remediate and repeat" \
  "### 9. Complete delivery and td lifecycle"

assert_order \
  "Surface \`wayfinder\`, \`to-spec\`, and Sergeant's custom \`to-tickets\`" \
  "canonical \`diagnosing-bugs\` skill" \
  "canonical \`prototype\` skill" \
  "canonical \`tdd\` skill before implementation" \
  "canonical \`resolving-merge-conflicts\` skill" \
  "canonical \`code-review\` skill"

[[ "$(cat "$task_dir/app/pane")" == "%42" ]] || {
  printf 'dispatch did not record the spawned pane target\n' >&2
  exit 1
}

cat >> "$TEST_ROOT/config/test.yaml" <<'EOF'
defaults:
  agent_instructions: |
    User override: run no-mistakes for this worker before completion.
EOF

PATH="$TEST_ROOT/fake-bin:$PATH" \
SERGEANT_CONFIG="$TEST_ROOT/config" \
SERGEANT_FLEET="$TEST_ROOT/fleet" \
SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test "Ship worker loop" --repos app >/dev/null

brief="$(grep -rl '^Ship worker loop$' "$TEST_ROOT"/app-sgt-*/.sergeant-brief.md | sed -n '1p')"
assert_contains "User override: run no-mistakes for this worker before completion."

write_routing_config() {
  local role="$1"
  local group="$2"
  local group_description="$3"
  local group_instructions="$4"
  local default_instructions="${5:-Maintain fleet automation}"
  local repo_instructions="${6:-Maintain repository automation}"
  if [[ "$group" != "FRONTEND" ]]; then
    cat > "$TEST_ROOT/config/test.yaml" <<EOF
name: test
defaults:
  agent_instructions: $default_instructions
repos:
  - name: app
    path: $TEST_ROOT/repo
    role: $role
    group: $group
    agent_instructions: $repo_instructions
  - name: role-ui
    path: $TEST_ROOT/role-repo
    role: User-Facing Output
  - name: group-ui
    path: $TEST_ROOT/group-repo
    group: FRONTEND
groups:
  FRONTEND:
    description: UI fixture group
  $group:
    description: $group_description
    agent_instructions: $group_instructions
EOF
    return
  fi

  cat > "$TEST_ROOT/config/test.yaml" <<EOF
name: test
defaults:
  agent_instructions: $default_instructions
repos:
  - name: app
    path: $TEST_ROOT/repo
    role: $role
    group: $group
    agent_instructions: $repo_instructions
  - name: role-ui
    path: $TEST_ROOT/role-repo
    role: User-Facing Output
  - name: group-ui
    path: $TEST_ROOT/group-repo
    group: FRONTEND
groups:
  FRONTEND:
    description: $group_description
    agent_instructions: $group_instructions
EOF
}

dispatch_and_assert_accessibility() {
  local mission="$1"
  local role="$2"
  local group="$3"
  local group_description="$4"
  local group_instructions="$5"
  local default_instructions="${6:-Maintain fleet automation}"
  local repo_instructions="${7:-Maintain repository automation}"

  write_routing_config "$role" "$group" "$group_description" "$group_instructions" "$default_instructions" "$repo_instructions"
  PATH="$TEST_ROOT/fake-bin:$PATH" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" \
  SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-dispatch" test "$mission" --repos app >/dev/null

  brief="$(grep -rl "^${mission}$" "$TEST_ROOT"/app-sgt-*/.sergeant-brief.md)"
  [[ -f "$brief" ]] || { printf 'UI-facing brief was not generated\n' >&2; exit 1; }
  assert_contains "Accessibility axis"
  assert_contains "independent accessibility review"
}

ui_triggers=(
  "fRoNtEnD"
  "uI"
  "vIsUaL"
  "iNtErAcTiOn"
  "aCcEsSiBiLiTy"
  "uSeR-fAcInG OuTpUt"
)

for i in "${!ui_triggers[@]}"; do
  trigger="${ui_triggers[$i]}"
  dispatch_and_assert_accessibility "Improve $trigger behavior mission-$i" "Backend service" "product" "Internal services" "Maintain deployment automation"
  dispatch_and_assert_accessibility "Maintain backend behavior role-$i" "$trigger application" "product" "Internal services" "Maintain deployment automation"
  dispatch_and_assert_accessibility "Maintain backend behavior instructions-$i" "Backend service" "product" "Internal services" "Review $trigger behavior"
done

dispatch_and_assert_accessibility "Maintain backend behavior group-name" "Backend service" "FRONTEND" "Internal services" "Maintain deployment automation"
dispatch_and_assert_accessibility "Maintain backend behavior group-description" "Backend service" "apps" "SvelteKit frontend applications" "Maintain deployment automation"
dispatch_and_assert_accessibility "Maintain backend behavior default-instructions" "Backend service" "product" "Internal services" "Maintain deployment automation" "Review frontend behavior"
dispatch_and_assert_accessibility "Maintain backend behavior repo-instructions" "Backend service" "product" "Internal services" "Maintain deployment automation" "Maintain fleet automation" "Review frontend behavior"

write_routing_config "Frontendish visualizer" "product" "Internal service repositories" "Maintain interactional accessibilitytree user-facing outputs"
PATH="$TEST_ROOT/fake-bin:$PATH" \
SERGEANT_CONFIG="$TEST_ROOT/config" \
SERGEANT_FLEET="$TEST_ROOT/fleet" \
SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test "Maintain nonvisual backend mission" --repos app >/dev/null
brief="$(grep -rl "^Maintain nonvisual backend mission$" "$TEST_ROOT"/app-sgt-*/.sergeant-brief.md)"
assert_not_contains "Accessibility axis"

for repo_name in role-ui group-ui; do
  PATH="$TEST_ROOT/fake-bin:$PATH" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" \
  SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-dispatch" test "Ship worker loop" --repos "$repo_name" >/dev/null

  brief="$(printf '%s\n' "$TEST_ROOT"/"$repo_name"-sgt-*/.sergeant-brief.md)"
  [[ -f "$brief" ]] || { printf 'UI-triggered brief was not generated for %s\n' "$repo_name" >&2; exit 1; }
  assert_contains "Accessibility axis"
  assert_contains "independent accessibility review"
done
printf 'sgt-dispatch brief contract: ok\n'
