#!/usr/bin/env bash
# Regression for GH #197: two independent review invocations may reuse a
# reviewer-local finding ID without the second being refused as "diverged".
#
# Seam: dedup marker includes TASK_ID, isolating each review invocation.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"

REPO="$TEST_ROOT/app"
WORKTREE_BASE="$TEST_ROOT/worktrees"
mkdir -p "$TEST_ROOT/config" "$TEST_ROOT/fake-bin" "$REPO" "$WORKTREE_BASE"
git -C "$REPO" init -q

cat > "$TEST_ROOT/config/test.yaml" <<EOF
name: test
repos:
  - name: app
    path: $REPO
EOF

# Write fake sgt-notify into real bin/ so the symlink-resolved SCRIPT_DIR finds it.
REAL_NOTIFY="$ROOT_DIR/bin/sgt-notify"
BACKUP_NOTIFY="$ROOT_DIR/bin/sgt-notify.bak.$$"
cp "$REAL_NOTIFY" "$BACKUP_NOTIFY"
cat > "$REAL_NOTIFY" <<'NOTIFY'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${NOTIFY_LOG:-/dev/null}"
NOTIFY
chmod +x "$REAL_NOTIFY"
trap 'cp "$BACKUP_NOTIFY" "$REAL_NOTIFY"; rm -f "$BACKUP_NOTIFY"; rm -rf "$TEST_ROOT"' EXIT

cat > "$TEST_ROOT/fake-bin/td" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --version) printf 'td version 1.0.0\n'; exit 0 ;;
  create) [[ "${2:-}" != "--help" ]] || {
    printf 'Usage: td create ... --description <text> --json --work-dir <path>\n'
    exit 0
  } ;;
esac
printf '%s\n' "$*" >> "${TD_LOG:-/dev/null}"
desc_arg=""
prev=""
for arg in "$@"; do
  [[ "$prev" == "--description" ]] && { desc_arg="$arg"; break; }
  prev="$arg"
done
[[ -z "$desc_arg" || -z "${TD_DESC:-}" ]] || printf '%s' "$desc_arg" > "$TD_DESC"
case "$1" in
  list) printf '%s\n' "${TD_LIST_RESULT:-[]}" ;;
  create)
    count="$(wc -l < "${TD_IDS:-/dev/null}" 2>/dev/null | tr -d ' ' || echo 0)"
    id="td-c-$((count+1))"
    printf '{"id":"%s"}\n' "$id"
    printf '%s\n' "$id" >> "${TD_IDS:-/dev/null}"
    ;;
  update|reopen|defer) printf '{"id":"%s"}\n' "$2" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/td"

cat > "$TEST_ROOT/fake-bin/yq" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  '.repos | length') printf '1\n' ;;
  '.repos[0].name') printf 'app\n' ;;
  '.repos[0].path') printf '%s\n' "$REPO_PATH" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/yq"

PASS=0; FAIL=0
_pass() { PASS=$(( PASS + 1 )); printf 'PASS: %s\n' "$1"; }
_fail() { FAIL=$(( FAIL + 1 )); printf 'FAIL: %s\n' "$1" >&2; }

# run_route <input-json> <task-id> [td-list-result]
# Runs sgt-review-findings in a fresh worktree so each invocation is isolated.
run_route() {
  local input="$1" task_id="$2" td_list="${3:-[]}"
  local wt="$WORKTREE_BASE/$task_id"
  local ids="$TEST_ROOT/ids-$task_id"
  local desc="$TEST_ROOT/desc-$task_id"
  local fleet="$TEST_ROOT/fleet-$task_id"
  mkdir -p "$wt" "$fleet"
  : > "$ids"
  export SERGEANT_FLEET="$fleet"
  set +e
  output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
    REPO_PATH="$REPO" TD_IDS="$ids" TD_LOG="/dev/null" \
    NOTIFY_LOG="/dev/null" MV_LOG="/dev/null" \
    TD_DESC="$desc" TD_LIST_RESULT="$td_list" \
    SERGEANT_CONFIG="$TEST_ROOT/config" \
    "$ROOT_DIR/bin/sgt-review-findings" test app \
      --input "$input" --axis standards --source code-review \
      --branch fix/review --head-sha abc1234 \
      --parent-task td-parent --task-id "$task_id" \
      --worktree "$wt" 2>&1)"
  route_status=$?
  set -e
  last_ids="$ids"
  last_desc="$desc"
}

# ── Shared finding JSONs ──────────────────────────────────────────────────────
printf '{"findings":[{"id":"spec-1","severity":"warning","disposition":"actionable","summary":"Finding from invocation 1","evidence":"file:10","paths":["file"],"acceptance_criteria":"ac","recommendation":"rec"}]}\n' \
  > "$TEST_ROOT/inv1.json"
printf '{"findings":[{"id":"spec-1","severity":"info","disposition":"actionable","summary":"Different finding from invocation 2","evidence":"file:20","paths":["file"],"acceptance_criteria":"ac2","recommendation":"rec2"}]}\n' \
  > "$TEST_ROOT/inv2.json"

# ── Test 1: first invocation creates a td task ────────────────────────────────
run_route "$TEST_ROOT/inv1.json" fleet-inv-1
[[ "$route_status" -eq 0 ]] || { _fail "first invocation failed: $output"; }
inv1_td="$(grep '^td-c-' "$last_ids" | head -1)"
[[ -n "$inv1_td" ]] && _pass "first invocation created td task $inv1_td" || \
  _fail "first invocation created no td task (output: $output)"

# ── Test 2: exact retry (same task-id, same finding) deduplicates ─────────────
# Build the td list as it would appear after the first invocation.
inv1_stored_desc="$(cat "$last_desc" 2>/dev/null || true)"
inv1_desc_json="$(python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" <<< "$inv1_stored_desc")"
td_list_with_inv1="[{\"id\":\"$inv1_td\",\"status\":\"open\",\"defer_until\":\"\",\"labels\":\"independent-review,finding,standards\",\"description\":$inv1_desc_json}]"

run_route "$TEST_ROOT/inv1.json" fleet-inv-1 "$td_list_with_inv1"
[[ "$route_status" -eq 0 ]] || { _fail "exact retry failed: $output"; }
retry_created="$(grep '^td-c-' "$last_ids" 2>/dev/null | head -1 || true)"
if [[ -z "$retry_created" ]]; then
  _pass "exact retry (same task-id, same content): deduplicated — no new task created"
else
  _fail "exact retry created new task $retry_created instead of deduplicating"
fi

# ── Test 3: second invocation (different task-id), same local finding ID → new task ─
# This is the core GH #197 regression: distinct fleet tasks with the same
# reviewer-local finding ID must route independently.
run_route "$TEST_ROOT/inv2.json" fleet-inv-2 "$td_list_with_inv1"
[[ "$route_status" -eq 0 ]] || {
  _fail "GH#197: second invocation (different task-id, different content) refused: $output"
}
inv2_td="$(grep '^td-c-' "$last_ids" 2>/dev/null | head -1 || true)"
if [[ -n "$inv2_td" ]]; then
  _pass "GH#197: second invocation (fleet-inv-2) created new td task $inv2_td"
else
  _fail "GH#197: second invocation created no new td task (output: $output)"
fi

# ── Test 4: same invocation, tampered content → diverged, refused ─────────────
printf '{"findings":[{"id":"spec-1","severity":"error","disposition":"actionable","summary":"TAMPERED","evidence":"file:10","paths":["file"],"acceptance_criteria":"ac","recommendation":"rec"}]}\n' \
  > "$TEST_ROOT/tampered.json"
run_route "$TEST_ROOT/tampered.json" fleet-inv-1 "$td_list_with_inv1"
if [[ "$route_status" -ne 0 ]] || [[ "$output" == *REFUSED* ]]; then
  _pass "same invocation + tampered content: correctly refused (diverged)"
else
  _fail "same invocation + tampered content accepted (should be refused)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
