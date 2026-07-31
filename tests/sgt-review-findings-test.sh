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
# Prerequisite-check calls: respond without logging to TD_LOG
case "$1" in
  --version) printf 'td version 1.0.0\n'; exit 0 ;;
  create) [[ "${2:-}" != "--help" ]] || { printf 'Usage: td create ... --description <text> --json --work-dir <path>\n'; exit 0; } ;;
esac
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

cat > "$TEST_ROOT/fake-bin/mv" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$2")" >> "$MV_LOG"
exec /usr/bin/mv "$@"
EOF
chmod +x "$TEST_ROOT/fake-bin/mv"

INSTALLED_BIN="$TEST_ROOT/installed-bin"
mkdir -p "$INSTALLED_BIN"
ln -s "$ROOT_DIR/bin/sgt-review-findings" "$INSTALLED_BIN/sgt-review-findings"
for _helper in "$ROOT_DIR/bin"/_sgt-*.sh; do
  ln -s "$_helper" "$INSTALLED_BIN/$(basename "$_helper")"
done
cat > "$INSTALLED_BIN/sgt-notify" <<'EOF'
#!/usr/bin/env bash
# Verify that .sergeant-message is visible before notification fires (status is
# committed after notify, so .sergeant-status.tmp may exist, but .sergeant-message
# must already be present if any message was collected).
printf '%s\n' "$*" >> "$NOTIFY_LOG"
EOF
chmod +x "$INSTALLED_BIN/sgt-notify"

cat > "$TEST_ROOT/fake-bin/cat" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/cat "$@"
EOF
chmod +x "$TEST_ROOT/fake-bin/cat"

cat > "$TEST_ROOT/fake-bin/tail" <<'EOF'
#!/usr/bin/env bash
if [[ "${BLOCK_GATE_READ:-0}" == "1" && "${*: -1}" == */standards-code-review ]]; then
  touch "$GATE_READ_STARTED"
  while [[ ! -e "$GATE_READ_RELEASE" ]]; do
    sleep 0.01
  done
fi
exec /usr/bin/tail "$@"
EOF
chmod +x "$TEST_ROOT/fake-bin/tail"

mkdir -p "$TEST_ROOT/fake-bin-no-notify"
for _f in "$TEST_ROOT/fake-bin"/*; do
  ln -s "$_f" "$TEST_ROOT/fake-bin-no-notify/$(basename "$_f")"
done

cat > "$TEST_ROOT/fake-bin/python3" <<'EOF'
#!/usr/bin/env bash
if [[ "${BLOCK_REVIEW_PARSE:-0}" == "1" ]]; then
  touch "$REVIEW_PARSE_STARTED"
  while [[ ! -e "$REVIEW_PARSE_RELEASE" ]]; do
    sleep 0.01
  done
fi
exec /usr/bin/python3 "$@"
EOF
chmod +x "$TEST_ROOT/fake-bin/python3"

run_router() {
  : > "$TEST_ROOT/td.log"
  : > "$TEST_ROOT/td-ids"
  : > "$TEST_ROOT/notify.log"
  : > "$TEST_ROOT/mv.log"
  if [[ "${PRESERVE_FLEET:-0}" != "1" ]]; then
    rm -f "$WORKTREE"/.sergeant-{status,message,gate-generation,review-gates.lock}
    rm -rf "$WORKTREE/.sergeant-review-gates"
  fi
  set +e
  output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
    REPO_PATH="$REPO" TD_LOG="$TEST_ROOT/td.log" TD_IDS="$TEST_ROOT/td-ids" \
    NOTIFY_LOG="$TEST_ROOT/notify.log" MV_LOG="$TEST_ROOT/mv.log" ROUTER_WORKTREE="$WORKTREE" SERGEANT_CONFIG="$TEST_ROOT/config" \
    TD_LIST_RESULT="${TD_LIST_RESULT:-[]}" TD_FAIL_CREATE="${TD_FAIL_CREATE:-0}" \
    "$INSTALLED_BIN/sgt-review-findings" test app \
      --input "$1" --axis "${ROUTER_AXIS:-standards}" --source code-review \
      --branch fix/review --head-sha abc1234 --parent-task td-parent \
      --task-id "${ROUTER_TASK_ID:-fleet-1}" --worktree "$WORKTREE" 2>&1)"
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
grep -Fq 'Originating fleet task: fleet-1' "$TEST_ROOT/td.log"
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

# 40-char hex SHA (git SHA) must not be redacted by the high-entropy filter
printf '{"findings":[{"id":"std-sha","severity":"warning","disposition":"actionable","summary":"SHA in evidence","evidence":"commit a6af6854056c77a7a1ed73e61b74cd7fead52e30 removed file","paths":[],"acceptance_criteria":"SHA preserved","recommendation":"none"}]}\n' > "$TEST_ROOT/sha.json"
run_router "$TEST_ROOT/sha.json"
grep -Fq 'a6af6854056c77a7a1ed73e61b74cd7fead52e30' "$TEST_ROOT/td.log"

TD_LIST_RESULT=null run_router "$TEST_ROOT/secrets.json"
[[ "$status" -eq 0 && "$output" == *'td-created-1'* ]]
grep -q '^create ' "$TEST_ROOT/td.log"

# Long file paths must not be redacted by the high-entropy heuristic
printf '{"findings":[{"id":"std-paths","severity":"warning","disposition":"actionable","summary":"Long path","evidence":"lib/internal/coordinator/fleet_manager.go:42 unsafe","paths":["lib/internal/coordinator/fleet_manager.go"],"acceptance_criteria":"None","recommendation":"Fix it"}]}\n' > "$TEST_ROOT/long-path.json"
run_router "$TEST_ROOT/long-path.json"
grep -Fq 'lib/internal/coordinator/fleet_manager.go' "$TEST_ROOT/td.log"
if grep -Fq '[REDACTED]' "$TEST_ROOT/td.log"; then
  printf 'long file path was incorrectly redacted\n' >&2
  exit 1
fi

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
grep -Fq 'Originating fleet task: fleet-1' "$TEST_ROOT/td.log"
if grep -Fq 'reopen td-existing' "$TEST_ROOT/td.log"; then
  printf 'rerun changed active finding state\n' >&2
  exit 1
fi

# dedup update with a different fleet task ID must write the new ID into the body
TD_LIST_RESULT='[{"id":"td-existing","status":"in_progress","description":"Deduplication key: independent-review-finding:app:standards:code-review:std-1"}]' \
  ROUTER_TASK_ID='fleet-new' run_router "$TEST_ROOT/findings.json"
grep -Fq 'update td-existing' "$TEST_ROOT/td.log"
grep -Fq 'Originating fleet task: fleet-new' "$TEST_ROOT/td.log"
if grep -Fq 'Originating fleet task: fleet-1' "$TEST_ROOT/td.log"; then
  printf 'stale fleet task ID retained in updated body\n' >&2
  exit 1
fi

# closed existing task must be reopened before update
TD_LIST_RESULT='[{"id":"td-closed","status":"closed","description":"Deduplication key: independent-review-finding:app:standards:code-review:std-1"}]' \
  run_router "$TEST_ROOT/findings.json"
grep -Fq 'reopen td-closed' "$TEST_ROOT/td.log"
grep -Fq 'update td-closed' "$TEST_ROOT/td.log"
grep -Fq 'Originating fleet task: fleet-1' "$TEST_ROOT/td.log"
reopen_line="$(grep -nF 'reopen td-closed' "$TEST_ROOT/td.log" | cut -d: -f1)"
update_line="$(grep -nF 'update td-closed' "$TEST_ROOT/td.log" | cut -d: -f1)"
[[ "$reopen_line" -lt "$update_line" ]]

# deferred existing task must NOT have deferral cleared on rerun — preserve defer_until
TD_LIST_RESULT='[{"id":"td-deferred","status":"in_progress","defer_until":"2099-01-01","description":"Deduplication key: independent-review-finding:app:standards:code-review:std-1"}]' \
  run_router "$TEST_ROOT/findings.json"
if grep -Fq 'defer td-deferred --clear' "$TEST_ROOT/td.log"; then
  printf 'deferred task had deferral cleared on rerun — must be preserved\n' >&2
  exit 1
fi
grep -Fq 'update td-deferred' "$TEST_ROOT/td.log"

# dedup update must preserve manually added labels — not replace them with only standard ones
TD_LIST_RESULT='[{"id":"td-labelled","status":"open","defer_until":"","labels":["independent-review","finding","standards","urgent","security"],"description":"Deduplication key: independent-review-finding:app:standards:code-review:std-1"}]' \
  run_router "$TEST_ROOT/findings.json"
if ! grep -Fq 'urgent' "$TEST_ROOT/td.log"; then
  printf 'dedup update dropped manually added label "urgent"\n' >&2
  exit 1
fi
if ! grep -Fq 'security' "$TEST_ROOT/td.log"; then
  printf 'dedup update dropped manually added label "security"\n' >&2
  exit 1
fi

# gate-less recovery must not clear a block caused by a different axis
# Setup: blocking state from axis=standards routing failure, gate file only for standards
gate_dir="$TEST_ROOT/worktree/.sergeant-review-gates"
mkdir -p "$gate_dir"
# gate-less case: no gate file exists for the current invocation (standards already cleaned up
# its gate) but the worker is still blocked by a different axis (spec) routing failure
# Simulate: spec gate is present, standards gate absent → standards clean run must not unblock
printf 'gen1\nspec routing failure\n' > "$gate_dir/spec-code-review"
printf 'blocked\n' > "$TEST_ROOT/worktree/.sergeant-status"
printf 'Review finding routing failed. axis: spec.\n' > "$TEST_ROOT/worktree/.sergeant-message"
printf 'gen1\n' > "$TEST_ROOT/worktree/.sergeant-gate-generation"
ROUTER_AXIS=standards run_router "$TEST_ROOT/findings.json" || true
if [[ "$(cat "$TEST_ROOT/worktree/.sergeant-status" 2>/dev/null)" != "blocked" ]]; then
  printf 'gate-less recovery cleared block caused by a different axis\n' >&2
  exit 1
fi
# Clean up gate state for subsequent tests
rm -rf "$gate_dir"
rm -f "$TEST_ROOT/worktree/.sergeant-message"
printf 'in_progress\n' > "$TEST_ROOT/worktree/.sergeant-status"

ROUTER_TASK_ID='fleet/invalid' run_router "$TEST_ROOT/findings.json"
[[ "$status" -eq 2 && "$output" == *'invalid fleet task'* ]]
[[ ! -s "$TEST_ROOT/notify.log" ]]
if grep -Eq '^(create|update) ' "$TEST_ROOT/td.log"; then
  printf 'malformed fleet task entered td metadata\n' >&2
  exit 1
fi
# Fleet state must be published even for invalid TASK_ID (notify is skipped, state is still written)
[[ "$(cat "$WORKTREE/.sergeant-status")" == 'blocked' ]]
grep -Fq 'Review finding routing failed' "$WORKTREE/.sergeant-message"

# _valid_fleet_task_id boundary tests
ROUTER_TASK_ID="$(printf 'a%.0s' {1..32})" run_router "$TEST_ROOT/findings.json"  # 32 chars: too long
[[ "$status" -eq 2 && "$output" == *'invalid fleet task'* ]]
ROUTER_TASK_ID="$(printf 'a%.0s' {1..31})" run_router "$TEST_ROOT/findings.json"  # 31 chars: at limit
[[ "$status" -eq 2 ]]  # exits 2 due to blocking findings (invalid fleet task NOT the reason)
[[ "$output" != *'invalid fleet task'* ]]
ROUTER_TASK_ID='Fleet-1' run_router "$TEST_ROOT/findings.json"  # uppercase: invalid
[[ "$status" -eq 2 && "$output" == *'invalid fleet task'* ]]
ROUTER_TASK_ID='fleet--1' run_router "$TEST_ROOT/findings.json"  # double-dash: invalid
[[ "$status" -eq 2 && "$output" == *'invalid fleet task'* ]]

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

# Missing prerequisite tool (yq absent) must publish blocked state
mkdir -p "$TEST_ROOT/no-yq-bin"
printf '#!/usr/bin/env bash\necho "yq: not found" >&2\nexit 127\n' > "$TEST_ROOT/no-yq-bin/yq"
chmod +x "$TEST_ROOT/no-yq-bin/yq"
rm -f "$WORKTREE"/.sergeant-{status,message,gate-generation}
rm -rf "$WORKTREE/.sergeant-review-gates"
set +e
output="$(PATH="$TEST_ROOT/no-yq-bin:$TEST_ROOT/fake-bin:$PATH" \
  REPO_PATH="$REPO" TD_LOG="$TEST_ROOT/td.log" TD_IDS="$TEST_ROOT/td-ids" \
  NOTIFY_LOG="$TEST_ROOT/notify.log" MV_LOG="$TEST_ROOT/mv.log" \
  ROUTER_WORKTREE="$WORKTREE" SERGEANT_CONFIG="$TEST_ROOT/config" \
  TD_LIST_RESULT="[]" TD_FAIL_CREATE="0" \
  "$ROOT_DIR/bin/sgt-review-findings" test app \
    --input "$TEST_ROOT/findings.json" --axis standards --source code-review \
    --branch fix/review --head-sha abc1234 --parent-task td-parent \
    --task-id fleet-1 --worktree "$WORKTREE" 2>&1)"
status=$?
set -e
[[ "$status" -eq 2 && "$(cat "$WORKTREE/.sergeant-status")" == 'blocked' ]]
grep -Fq 'Review finding routing failed' "$WORKTREE/.sergeant-message"

printf '{"findings":[]}\n' > "$TEST_ROOT/clean.json"
PRESERVE_FLEET=1 run_router "$TEST_ROOT/clean.json"
[[ "$(cat "$WORKTREE/.sergeant-status")" == 'in_progress' && ! -e "$WORKTREE/.sergeant-message" ]]

run_router "$TEST_ROOT/findings.json"
PRESERVE_FLEET=1 ROUTER_AXIS=spec run_router "$TEST_ROOT/findings.json"
grep -Fq 'Review axis: standards' "$WORKTREE/.sergeant-message"
grep -Fq 'Review axis: spec' "$WORKTREE/.sergeant-message"

rm -rf "$WORKTREE/.sergeant-review-gates"
rm -f "$WORKTREE"/.sergeant-{status,message,gate-generation,review-gates.lock}
GATE_READ_STARTED="$TEST_ROOT/gate-read-started" GATE_READ_RELEASE="$TEST_ROOT/gate-read-release" \
  PRESERVE_FLEET=1 BLOCK_GATE_READ=1 run_router "$TEST_ROOT/findings.json" &
first_router_pid=$!
for _ in {1..200}; do
  [[ -e "$TEST_ROOT/gate-read-started" ]] && break
  sleep 0.01
done
[[ -e "$TEST_ROOT/gate-read-started" ]] || { printf 'TIMEOUT: gate-read-started not seen\n' >&2; exit 1; }
GATE_READ_STARTED="$TEST_ROOT/unused" GATE_READ_RELEASE="$TEST_ROOT/unused" \
  PRESERVE_FLEET=1 ROUTER_AXIS=spec run_router "$TEST_ROOT/findings.json" &
second_router_pid=$!
for _ in {1..200}; do
  [[ -s "$TEST_ROOT/notify.log" ]] && break
  sleep 0.01
done
touch "$TEST_ROOT/gate-read-release"
wait "$first_router_pid"
wait "$second_router_pid"
grep -Fq 'Review axis: standards' "$WORKTREE/.sergeant-message"
grep -Fq 'Review axis: spec' "$WORKTREE/.sergeant-message"
PRESERVE_FLEET=1 ROUTER_AXIS=spec run_router "$TEST_ROOT/clean.json"
[[ "$(cat "$WORKTREE/.sergeant-status")" == 'blocked' ]]
grep -Fq 'Review axis: standards' "$WORKTREE/.sergeant-message"
PRESERVE_FLEET=1 run_router "$TEST_ROOT/clean.json"
[[ "$status" -eq 0 && "$output" == *'no actionable findings; continue remediation workflow'* ]]
[[ "$(cat "$WORKTREE/.sergeant-status")" == 'in_progress' && ! -e "$WORKTREE/.sergeant-message" ]]
[[ ! -s "$TEST_ROOT/td.log" && ! -s "$TEST_ROOT/notify.log" ]]

rm -rf "$WORKTREE/.sergeant-review-gates"
rm -f "$WORKTREE"/.sergeant-{status,message,gate-generation,review-gates.lock}
rm -f "$TEST_ROOT/gate-read-started" "$TEST_ROOT/gate-read-release"
GATE_READ_STARTED="$TEST_ROOT/gate-read-started" GATE_READ_RELEASE="$TEST_ROOT/gate-read-release" \
  PRESERVE_FLEET=1 BLOCK_GATE_READ=1 run_router "$TEST_ROOT/findings.json" &
blocking_router_pid=$!
for _ in {1..200}; do
  [[ -e "$TEST_ROOT/gate-read-started" ]] && break
  sleep 0.01
done
[[ -e "$TEST_ROOT/gate-read-started" ]] || { printf 'TIMEOUT: gate-read-started not seen (blocking router)\n' >&2; exit 1; }
PRESERVE_FLEET=1 run_router "$TEST_ROOT/clean.json" &
clean_router_pid=$!
for _ in {1..200}; do
  lock_waiters=("$WORKTREE"/..sergeant-review-gates.lock.*)
  [[ -e "${lock_waiters[0]}" ]] && break
  sleep 0.01
done
[[ -e "${lock_waiters[0]}" ]] || { printf 'TIMEOUT: clean router lock-waiter not seen\n' >&2; exit 1; }
touch "$TEST_ROOT/gate-read-release"
wait "$blocking_router_pid"
wait "$clean_router_pid"
[[ "$(cat "$WORKTREE/.sergeant-status")" == 'in_progress' ]]
[[ ! -e "$WORKTREE/.sergeant-message" ]]

rm -rf "$WORKTREE/.sergeant-review-gates"
rm -f "$WORKTREE"/.sergeant-{status,message,gate-generation,review-gates.lock}
rm -f "$TEST_ROOT/review-parse-started" "$TEST_ROOT/review-parse-release"
run_router "$TEST_ROOT/findings.json"
[[ "$(cat "$WORKTREE/.sergeant-gate-generation")" == '1' ]]
BLOCK_REVIEW_PARSE=1 REVIEW_PARSE_STARTED="$TEST_ROOT/review-parse-started" \
  REVIEW_PARSE_RELEASE="$TEST_ROOT/review-parse-release" PRESERVE_FLEET=1 \
  run_router "$TEST_ROOT/clean.json" &
stale_clean_router_pid=$!
for _ in {1..200}; do
  [[ -e "$TEST_ROOT/review-parse-started" ]] && break
  sleep 0.01
done
[[ -e "$TEST_ROOT/review-parse-started" ]] || { printf 'TIMEOUT: review-parse-started not seen\n' >&2; exit 1; }
PRESERVE_FLEET=1 run_router "$TEST_ROOT/findings.json"
[[ "$(cat "$WORKTREE/.sergeant-gate-generation")" == '2' ]]
touch "$TEST_ROOT/review-parse-release"
wait "$stale_clean_router_pid"
[[ "$(cat "$WORKTREE/.sergeant-status")" == 'blocked' ]]
grep -Fq 'Review axis: standards' "$WORKTREE/.sergeant-message"
[[ "$(sed -n '1p' "$WORKTREE/.sergeant-review-gates/standards-code-review")" == '2' ]]

run_router "$TEST_ROOT/clean.json"
set +e
output="$(PATH="$TEST_ROOT/fake-bin:$PATH" REPO_PATH="$REPO" TD_LOG="$TEST_ROOT/td.log" MV_LOG="$TEST_ROOT/mv.log" \
  TD_IDS="$TEST_ROOT/td-ids" NOTIFY_LOG="$TEST_ROOT/notify.log" ROUTER_WORKTREE="$WORKTREE" \
  SERGEANT_CONFIG="$TEST_ROOT/config" "$INSTALLED_BIN/sgt-review-findings" test app \
  --input "$TEST_ROOT/clean.json" --axis invalid --source code-review --branch fix/review \
  --head-sha abc1234 --parent-task td-parent --task-id fleet-1 --worktree "$WORKTREE" 2>&1)"
status=$?
set -e
[[ "$status" -eq 2 && "$(cat "$WORKTREE/.sergeant-status")" == 'blocked' ]]
grep -Fq 'blocked [app]' "$TEST_ROOT/notify.log"
PRESERVE_FLEET=1 run_router "$TEST_ROOT/clean.json"
[[ "$(cat "$WORKTREE/.sergeant-status")" == 'in_progress' ]]
[[ ! -e "$WORKTREE/.sergeant-message" ]]

rm -f "$WORKTREE/.sergeant-status" "$WORKTREE/.sergeant-message"
: > "$TEST_ROOT/notify.log"
set +e
output="$(PATH="$TEST_ROOT/fake-bin:$PATH" REPO_PATH="$REPO" TD_LOG="$TEST_ROOT/td.log" MV_LOG="$TEST_ROOT/mv.log" \
  TD_IDS="$TEST_ROOT/td-ids" NOTIFY_LOG="$TEST_ROOT/notify.log" ROUTER_WORKTREE="$WORKTREE" \
  SERGEANT_CONFIG="$TEST_ROOT/config" "$INSTALLED_BIN/sgt-review-findings" test app \
  --input "$TEST_ROOT/clean.json" --source code-review --branch fix/review \
  --head-sha abc1234 --parent-task td-parent --task-id fleet-1 --worktree "$WORKTREE" 2>&1)"
status=$?
set -e
[[ "$status" -eq 2 && "$(cat "$WORKTREE/.sergeant-status")" == 'blocked' ]]
grep -Fq 'blocked [app]' "$TEST_ROOT/notify.log"

rm -f "$WORKTREE"/.sergeant-{status,message,gate-generation}
: > "$TEST_ROOT/notify.log"
: > "$TEST_ROOT/td.log"
: > "$TEST_ROOT/td-ids"
: > "$TEST_ROOT/mv.log"
set +e
output="$(PATH="$TEST_ROOT/fake-bin-no-notify:/usr/bin:/bin" \
  REPO_PATH="$REPO" TD_LOG="$TEST_ROOT/td.log" TD_IDS="$TEST_ROOT/td-ids" \
  NOTIFY_LOG="$TEST_ROOT/notify.log" MV_LOG="$TEST_ROOT/mv.log" ROUTER_WORKTREE="$WORKTREE" \
  SERGEANT_CONFIG="$TEST_ROOT/config" TD_LIST_RESULT="[]" TD_FAIL_CREATE="0" \
  "$INSTALLED_BIN/sgt-review-findings" test app \
    --input "$TEST_ROOT/findings.json" --axis standards --source code-review \
    --branch fix/review --head-sha abc1234 --parent-task td-parent \
    --task-id fleet-1 --worktree "$WORKTREE" 2>&1)"
status=$?
set -e
[[ "$output" != *'ERROR: sgt-notify failed'* ]] || {
  printf '%s\n' "sgt-notify must be reachable via \$SCRIPT_DIR when bin/ not on PATH" >&2
  exit 1
}
[[ "$status" -eq 2 ]] || { printf 'blocking findings did not gate (installed-bin): %s\n' "$output" >&2; exit 1; }
grep -Fq 'blocked [app]' "$TEST_ROOT/notify.log" || {
  printf '%s\n' "sgt-notify was not called via \$SCRIPT_DIR-relative path" >&2
  exit 1
}

printf 'sgt-review-findings: ok\n'
