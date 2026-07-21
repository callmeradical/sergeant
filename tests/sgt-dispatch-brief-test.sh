#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/config" "$TEST_ROOT/fleet" "$TEST_ROOT/fake-bin" "$TEST_ROOT/repo"

cat > "$TEST_ROOT/config/test.yaml" <<EOF
name: test
repos:
  - name: app
    path: $TEST_ROOT/repo
    role: Test fixture
EOF

cat > "$TEST_ROOT/fake-bin/tmux" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "new-window" ]]; then
  printf '%%42\n'
fi
exit 0
EOF
chmod +x "$TEST_ROOT/fake-bin/tmux"

cat > "$TEST_ROOT/fake-bin/td" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

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

PATH="$TEST_ROOT/fake-bin:$PATH" \
SERGEANT_CONFIG="$TEST_ROOT/config" \
SERGEANT_FLEET="$TEST_ROOT/fleet" \
SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test "Harden worker loop" --repos app >/dev/null

brief="$(printf '%s\n' "$TEST_ROOT"/app-sgt-*/.sergeant-brief.md)"
[[ -f "$brief" ]] || { printf 'brief was not generated\n' >&2; exit 1; }

assert_contains() {
  local expected="$1"
  grep -Fq "$expected" "$brief" || {
    printf 'missing brief contract: %s\n' "$expected" >&2
    exit 1
  }
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
assert_contains "failing focused test"
assert_contains "minimum implementation"
assert_contains "full required suite once at the end"
assert_contains "Run no-mistakes when available or required"
assert_contains "separate parallel subagents"
assert_contains "Standards axis"
assert_contains "Fowler smell heuristic"
assert_contains "skip findings enforced by tooling"
assert_contains "Spec axis"
assert_contains "If no spec exists, report this axis as skipped"
assert_contains "Do not blend or rerank the axes"
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
assert_contains ".sergeant-response-ack"
assert_contains "consume/remove the response transport atomically"
assert_contains "return status to \`in_progress\`"
assert_contains "proof conditions"
assert_contains "the turn publishes \`needs_input\` or \`blocked\` and a resumable session ID was captured"
assert_contains "the turn publishes \`done\` with a non-empty \`.sergeant-result\`"
assert_contains "the turn publishes explicit terminal \`failed: <reason>\`, which is unrecoverable and must clean response plaintext"
assert_contains "For unexpected exit, invalid status, or missing resumable session, retain the response transport for retry"
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
  "### 6. Independent two-axis review" \
  "### 7. Remediate and repeat" \
  "### 8. Complete delivery and td lifecycle"

assert_order \
  "Surface \`wayfinder\`, \`to-spec\`, and Sergeant's custom \`to-tickets\`" \
  "canonical \`diagnosing-bugs\` skill" \
  "canonical \`prototype\` skill" \
  "canonical \`tdd\` skill before implementation" \
  "canonical \`resolving-merge-conflicts\` skill" \
  "canonical \`code-review\` skill"

task_dir="$(printf '%s\n' "$TEST_ROOT"/fleet/*)"
[[ "$(cat "$task_dir/app/pane")" == "%42" ]] || {
  printf 'dispatch did not record the spawned pane target\n' >&2
  exit 1
}

printf 'sgt-dispatch brief contract: ok\n'
