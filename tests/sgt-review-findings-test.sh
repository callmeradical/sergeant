#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

REPO="$TEST_ROOT/app"
WORKTREE="$TEST_ROOT/worktree"
mkdir -p "$TEST_ROOT/config" "$TEST_ROOT/fake-bin" "$REPO" "$WORKTREE"
git -C "$REPO" init -q
cat > "$TEST_ROOT/config/test.yaml" <<EOF
name: test
repos:
  - name: app
    path: $REPO
EOF

cat > "$TEST_ROOT/fake-bin/td" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TD_LOG"
case "$1" in
  list) printf '%s\n' "${TD_LIST_RESULT:-[]}" ;;
  create)
    [[ "${TD_FAIL_CREATE:-0}" != "1" ]] || exit 23
    count="$(wc -l < "$TD_IDS")"
    printf '{"id":"td-created-%s"}\n' "$((count + 1))"
    printf 'td-created-%s\n' "$((count + 1))" >> "$TD_IDS"
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

cat > "$TEST_ROOT/fake-bin/sgt-notify" <<'EOF'
#!/usr/bin/env bash
if [[ -e "$ROUTER_WORKTREE/.sergeant-status" && "$(cat "$ROUTER_WORKTREE/.sergeant-status")" == "blocked" ]]; then
  printf 'status published before notification\n' >&2
  exit 29
fi
printf '%s\n' "$*" >> "$NOTIFY_LOG"
EOF
chmod +x "$TEST_ROOT/fake-bin/sgt-notify"

cat > "$TEST_ROOT/fake-bin/mv" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$2")" >> "$MV_LOG"
exec /usr/bin/mv "$@"
EOF
chmod +x "$TEST_ROOT/fake-bin/mv"

run_router() {
  : > "$TEST_ROOT/td.log"
  : > "$TEST_ROOT/td-ids"
  : > "$TEST_ROOT/notify.log"
  : > "$TEST_ROOT/mv.log"
  if [[ "${PRESERVE_FLEET:-0}" != "1" ]]; then
    rm -f "$WORKTREE"/.sergeant-{status,message,gate-generation}
  fi
  set +e
  output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
    REPO_PATH="$REPO" TD_LOG="$TEST_ROOT/td.log" TD_IDS="$TEST_ROOT/td-ids" \
    NOTIFY_LOG="$TEST_ROOT/notify.log" MV_LOG="$TEST_ROOT/mv.log" ROUTER_WORKTREE="$WORKTREE" SERGEANT_CONFIG="$TEST_ROOT/config" \
    TD_LIST_RESULT="${TD_LIST_RESULT:-[]}" TD_FAIL_CREATE="${TD_FAIL_CREATE:-0}" \
    "$ROOT_DIR/bin/sgt-review-findings" test app \
      --input "$1" --axis standards --source code-review \
      --branch fix/review --head-sha abc1234 --parent-task td-parent \
      --task-id fleet-1 --worktree "$WORKTREE" 2>&1)"
  status=$?
  set -e
}

cat > "$TEST_ROOT/findings.json" <<'EOF'
{"findings":[
  {"id":"std-1","severity":"error","disposition":"actionable","summary":"Unsafe cleanup","evidence":"bin/run:42 can remove another pane","paths":["bin/run"],"acceptance_criteria":"Match exact pane identity","recommendation":"Use exact identity matching"},
  {"id":"std-2","severity":"warning","disposition":"actionable","summary":"Long function","evidence":"bin/run:80-190 mixes routing and output","paths":["bin/run"],"acceptance_criteria":"Separate routing from rendering","recommendation":"Extract the renderer"},
  {"id":"std-3","severity":"info","disposition":"cosmetic","summary":"Heading style","evidence":"README heading is subjective","paths":["README.md"],"acceptance_criteria":"None","recommendation":"No change"}
]}
EOF

run_router "$TEST_ROOT/findings.json"
[[ "$status" -eq 2 ]] || { printf 'blocking findings did not gate: %s\n' "$output" >&2; exit 1; }
[[ "$(grep -c '^create ' "$TEST_ROOT/td.log")" -eq 2 ]]
grep -Fq -- '--priority P1' "$TEST_ROOT/td.log"
grep -Fq -- '--priority P2' "$TEST_ROOT/td.log"
grep -Fq 'Review axis: standards' "$TEST_ROOT/td.log"
grep -Fq 'Review source: code-review' "$TEST_ROOT/td.log"
grep -Fq 'Evidence: bin/run:42 can remove another pane' "$TEST_ROOT/td.log"
grep -Fq 'Affected paths: bin/run' "$TEST_ROOT/td.log"
grep -Fq 'Acceptance criteria: Match exact pane identity' "$TEST_ROOT/td.log"
grep -Fq 'Branch: fix/review' "$TEST_ROOT/td.log"
grep -Fq 'Head SHA: abc1234' "$TEST_ROOT/td.log"
grep -Fq 'Parent mission: td-parent' "$TEST_ROOT/td.log"
grep -Fq 'independent-review-finding:app:standards:code-review:std-1' "$TEST_ROOT/td.log"
[[ "$(cat "$WORKTREE/.sergeant-status")" == 'blocked' ]]
[[ "$(cat "$WORKTREE/.sergeant-gate-generation")" == '1' ]]
grep -Fq 'td-created-1' "$WORKTREE/.sergeant-message"
grep -Fq 'Use exact identity matching' "$WORKTREE/.sergeant-message"
grep -Fq 'blocked [app]' "$TEST_ROOT/notify.log"
[[ "$output" == *'std-3: ignored cosmetic finding'* ]]
generation_line="$(grep -nF '.sergeant-gate-generation' "$TEST_ROOT/mv.log" | cut -d: -f1)"
message_line="$(grep -nF '.sergeant-message' "$TEST_ROOT/mv.log" | cut -d: -f1)"
status_line="$(grep -nF '.sergeant-status' "$TEST_ROOT/mv.log" | cut -d: -f1)"
[[ "$generation_line" -lt "$message_line" && "$message_line" -lt "$status_line" ]]

cat > "$TEST_ROOT/secrets.json" <<'EOF'
{"findings":[{"id":"std-secret","severity":"warning","disposition":"actionable","summary":"Credential exposure","evidence":"token=super-secret Bearer raw-token Basic dXNlcjpwYXNz ghp_123456789012345678901234567890123456 AKIAIOSFODNN7EXAMPLE https://user:pass@example.test -----BEGIN PRIVATE KEY-----","paths":["bin/run"],"acceptance_criteria":"Redact credential=hidden-value","recommendation":"Remove password=hunter2"}]}
EOF
run_router "$TEST_ROOT/secrets.json"
grep -Fq 'token=[REDACTED]' "$TEST_ROOT/td.log"
grep -Fq 'Bearer [REDACTED]' "$TEST_ROOT/td.log"
grep -Fq 'credential=[REDACTED]' "$TEST_ROOT/td.log"
grep -Fq 'password=[REDACTED]' "$TEST_ROOT/td.log"
if grep -Eq 'super-secret|raw-token|hidden-value|hunter2|dXNlcjpwYXNz|ghp_|AKIA|user:pass|BEGIN PRIVATE KEY' "$TEST_ROOT/td.log"; then
  printf 'review secrets entered td metadata\n' >&2
  exit 1
fi

TD_LIST_RESULT=null run_router "$TEST_ROOT/secrets.json"
[[ "$status" -eq 0 && "$output" == *'td-created-1'* ]]
grep -q '^create ' "$TEST_ROOT/td.log"

printf '{"findings":[{"id":"std-body","severity":"warning","disposition":"actionable","summary":"Valid summary","evidence":"safe evidence","paths":[],"acceptance_criteria":"safe criterion","recommendation":"safe recommendation","review_body":"private prompt contents"}]}\n' > "$TEST_ROOT/body.json"
run_router "$TEST_ROOT/body.json"
[[ "$status" -eq 2 && "$output" != *'private prompt contents'* ]]
if grep -Fq 'private prompt contents' "$TEST_ROOT/td.log" "$WORKTREE/.sergeant-message" "$TEST_ROOT/notify.log"; then
  printf 'review body entered durable metadata\n' >&2
  exit 1
fi

TD_LIST_RESULT='[{"id":"td-existing","status":"in_progress","description":"Deduplication key: independent-review-finding:app:standards:code-review:std-1"}]' \
  run_router "$TEST_ROOT/findings.json"
grep -Fq 'update td-existing' "$TEST_ROOT/td.log"
if grep -Fq 'reopen td-existing' "$TEST_ROOT/td.log"; then
  printf 'rerun changed active finding state\n' >&2
  exit 1
fi

printf '{"findings":[' > "$TEST_ROOT/malformed.json"
run_router "$TEST_ROOT/malformed.json"
[[ "$status" -eq 2 && "$output" == *'invalid review output'* ]]
[[ ! -s "$TEST_ROOT/td.log" ]]
[[ "$(cat "$WORKTREE/.sergeant-status")" == 'blocked' ]]
grep -Fq 'Review finding routing failed' "$WORKTREE/.sergeant-message"
grep -Fq 'blocked [app]' "$TEST_ROOT/notify.log"

TD_FAIL_CREATE=1 run_router "$TEST_ROOT/findings.json"
[[ "$status" -eq 2 && "$output" == *'failed to create td task'* ]]
[[ "$(cat "$WORKTREE/.sergeant-status")" == 'blocked' ]]
grep -Fq 'Review finding routing failed' "$WORKTREE/.sergeant-message"

printf '{"findings":[]}\n' > "$TEST_ROOT/clean.json"
printf 'blocked\n' > "$WORKTREE/.sergeant-status"
printf 'Independent review requires remediation. TD tasks: td-old.\n' > "$WORKTREE/.sergeant-message"
printf '4\n' > "$WORKTREE/.sergeant-gate-generation"
PRESERVE_FLEET=1 run_router "$TEST_ROOT/clean.json"
[[ "$status" -eq 0 && "$output" == *'no actionable findings; continue remediation workflow'* ]]
[[ "$(cat "$WORKTREE/.sergeant-status")" == 'in_progress' && ! -e "$WORKTREE/.sergeant-message" ]]
[[ "$(cat "$WORKTREE/.sergeant-gate-generation")" == '4' ]]
[[ ! -s "$TEST_ROOT/td.log" && ! -s "$TEST_ROOT/notify.log" ]]

run_router "$TEST_ROOT/clean.json"
set +e
output="$(PATH="$TEST_ROOT/fake-bin:$PATH" REPO_PATH="$REPO" TD_LOG="$TEST_ROOT/td.log" MV_LOG="$TEST_ROOT/mv.log" \
  TD_IDS="$TEST_ROOT/td-ids" NOTIFY_LOG="$TEST_ROOT/notify.log" ROUTER_WORKTREE="$WORKTREE" \
  SERGEANT_CONFIG="$TEST_ROOT/config" "$ROOT_DIR/bin/sgt-review-findings" test app \
  --input "$TEST_ROOT/clean.json" --axis invalid --source code-review --branch fix/review \
  --head-sha abc1234 --parent-task td-parent --task-id fleet-1 --worktree "$WORKTREE" 2>&1)"
status=$?
set -e
[[ "$status" -eq 2 && "$(cat "$WORKTREE/.sergeant-status")" == 'blocked' ]]
grep -Fq 'blocked [app]' "$TEST_ROOT/notify.log"

rm -f "$WORKTREE/.sergeant-status" "$WORKTREE/.sergeant-message"
: > "$TEST_ROOT/notify.log"
set +e
output="$(PATH="$TEST_ROOT/fake-bin:$PATH" REPO_PATH="$REPO" TD_LOG="$TEST_ROOT/td.log" MV_LOG="$TEST_ROOT/mv.log" \
  TD_IDS="$TEST_ROOT/td-ids" NOTIFY_LOG="$TEST_ROOT/notify.log" ROUTER_WORKTREE="$WORKTREE" \
  SERGEANT_CONFIG="$TEST_ROOT/config" "$ROOT_DIR/bin/sgt-review-findings" test app \
  --input "$TEST_ROOT/clean.json" --source code-review --branch fix/review \
  --head-sha abc1234 --parent-task td-parent --task-id fleet-1 --worktree "$WORKTREE" 2>&1)"
status=$?
set -e
[[ "$status" -eq 2 && "$(cat "$WORKTREE/.sergeant-status")" == 'blocked' ]]
grep -Fq 'blocked [app]' "$TEST_ROOT/notify.log"

printf 'sgt-review-findings: ok\n'
