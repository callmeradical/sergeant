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
# Capture the exact --description value so a test can feed a routed body back in
# as the stored description and drive a real round trip.
if [[ -n "${TD_DESC:-}" ]]; then
  _prev=""
  for _arg in "$@"; do
    [[ "$_prev" == "--description" ]] && { printf '%s' "$_arg" > "$TD_DESC"; break; }
    _prev="$_arg"
  done
fi
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
    rm -rf "$WORKTREE/.sergeant-review-gates" "$WORKTREE/.sergeant-review-artifacts"
  fi
  set +e
  output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
    REPO_PATH="$REPO" TD_LOG="$TEST_ROOT/td.log" TD_IDS="$TEST_ROOT/td-ids" \
    NOTIFY_LOG="$TEST_ROOT/notify.log" MV_LOG="$TEST_ROOT/mv.log" ROUTER_WORKTREE="$WORKTREE" SERGEANT_CONFIG="$TEST_ROOT/config" \
    TD_DESC="$TEST_ROOT/td-desc" \
    TD_LIST_RESULT="${TD_LIST_RESULT:-[]}" TD_FAIL_CREATE="${TD_FAIL_CREATE:-0}" \
    "$INSTALLED_BIN/sgt-review-findings" test app \
      --input "$1" --axis "${ROUTER_AXIS:-standards}" --source code-review \
      --branch "${ROUTER_BRANCH:-fix/review}" --head-sha abc1234 \
      --parent-task "${ROUTER_PARENT_TASK:-td-parent}" \
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

printf '{"findings":[
  {"id":"std-1","severity":"error","disposition":"actionable","summary":"Unsafe cleanup","evidence":"bin/run:42 can remove another pane","paths":["bin/run"],"acceptance_criteria":"Match exact pane identity","recommendation":"Use exact identity matching"}
]}\n' > "$TEST_ROOT/one.json"

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
grep -Fq 'independent-review-finding:app:standards:code-review:std-1:td-parent:fix/review' "$TEST_ROOT/td.log"
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
# Content digest of std-1 as the router computes it; reused by the dedup fixtures
# below so a fixture can represent "the same finding" without hardcoding a hash.
std1_digest="$(grep -o 'Finding content digest: [0-9a-f]*' "$TEST_ROOT/td.log" | head -1 | awk '{print $4}')"
[[ -n "$std1_digest" ]] || { printf 'no finding content digest recorded for std-1\n' >&2; exit 1; }

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

TD_LIST_RESULT='[{"id":"td-existing","status":"in_progress","description":"Deduplication key: independent-review-finding:app:standards:code-review:std-1:td-parent:fix/review"}]' \
  run_router "$TEST_ROOT/findings.json"
grep -Fq 'update td-existing' "$TEST_ROOT/td.log"
grep -Fq 'Originating fleet task: fleet-1' "$TEST_ROOT/td.log"
if grep -Fq 'reopen td-existing' "$TEST_ROOT/td.log"; then
  printf 'rerun changed active finding state\n' >&2
  exit 1
fi

# dedup update with a different fleet task ID must write the new ID into the body
TD_LIST_RESULT='[{"id":"td-existing","status":"in_progress","description":"Deduplication key: independent-review-finding:app:standards:code-review:std-1:td-parent:fix/review"}]' \
  ROUTER_TASK_ID='fleet-new' run_router "$TEST_ROOT/findings.json"
grep -Fq 'update td-existing' "$TEST_ROOT/td.log"
grep -Fq 'Originating fleet task: fleet-new' "$TEST_ROOT/td.log"
if grep -Fq 'Originating fleet task: fleet-1' "$TEST_ROOT/td.log"; then
  printf 'stale fleet task ID retained in updated body\n' >&2
  exit 1
fi

# closed existing task recording the same finding must be reopened before update
TD_LIST_RESULT="[{\"id\":\"td-closed\",\"status\":\"closed\",\"description\":\"Deduplication key: independent-review-finding:app:standards:code-review:std-1:td-parent:fix/review\nFinding content digest: $std1_digest\"}]" \
  run_router "$TEST_ROOT/findings.json"
grep -Fq 'reopen td-closed' "$TEST_ROOT/td.log"
grep -Fq 'update td-closed' "$TEST_ROOT/td.log"
grep -Fq 'Originating fleet task: fleet-1' "$TEST_ROOT/td.log"
reopen_line="$(grep -nF 'reopen td-closed' "$TEST_ROOT/td.log" | head -1 | cut -d: -f1)"
update_line="$(grep -nF 'update td-closed' "$TEST_ROOT/td.log" | tail -1 | cut -d: -f1)"
[[ "$reopen_line" -lt "$update_line" ]]

# deferred existing task must NOT have deferral cleared on rerun — preserve defer_until
TD_LIST_RESULT='[{"id":"td-deferred","status":"in_progress","defer_until":"2099-01-01","description":"Deduplication key: independent-review-finding:app:standards:code-review:std-1:td-parent:fix/review"}]' \
  run_router "$TEST_ROOT/findings.json"
if grep -Fq 'defer td-deferred --clear' "$TEST_ROOT/td.log"; then
  printf 'deferred task had deferral cleared on rerun — must be preserved\n' >&2
  exit 1
fi
grep -Fq 'update td-deferred' "$TEST_ROOT/td.log"

# dedup update must preserve manually added labels — not replace them with only standard ones
TD_LIST_RESULT='[{"id":"td-labelled","status":"open","defer_until":"","labels":["independent-review","finding","standards","urgent","security"],"description":"Deduplication key: independent-review-finding:app:standards:code-review:std-1:td-parent:fix/review"}]' \
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
# Setup: worker is blocked by a spec routing failure, but the current standards
# rerun has no findings and no standards gate to clean up.
gate_dir="$TEST_ROOT/worktree/.sergeant-review-gates"
mkdir -p "$gate_dir"
# Simulate: spec gate is present, standards gate absent -> standards clean run
# must not unblock the worker.
printf 'gen1\nspec routing failure\n' > "$gate_dir/spec-code-review"
printf 'blocked\n' > "$TEST_ROOT/worktree/.sergeant-status"
printf 'Review finding routing failed. axis: spec.\n' > "$TEST_ROOT/worktree/.sergeant-message"
printf 'gen1\n' > "$TEST_ROOT/worktree/.sergeant-gate-generation"
PRESERVE_FLEET=1 ROUTER_AXIS=standards run_router "$TEST_ROOT/clean.json"
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

# ── td-52d7c2: dedup marker must be scoped to the parent task and branch ──────
# Reproduces the reported sequence: route a generic finding id for parent A,
# close that card, then route a DIFFERENT finding with the same generic id for
# parent B. Parent A's card must be untouched and a new card must be created.
printf '{"findings":[{"id":"spec-1","severity":"warning","disposition":"actionable","summary":"Bootstrap prerequisites are unchecked","evidence":"bin/run:10 skips the prerequisite probe","paths":["bin/run"],"acceptance_criteria":"Probe prerequisites","recommendation":"Add the probe"}]}\n' \
  > "$TEST_ROOT/spec1-parent-a.json"
printf '{"findings":[{"id":"spec-1","severity":"warning","disposition":"actionable","summary":"Rename bundled into finding commit","evidence":"bin/other:99 bundles a rename","paths":["bin/other"],"acceptance_criteria":"Split the rename","recommendation":"Split the commit"}]}\n' \
  > "$TEST_ROOT/spec1-parent-b.json"

ROUTER_PARENT_TASK=td-parent-a ROUTER_BRANCH=feat/a run_router "$TEST_ROOT/spec1-parent-a.json"
[[ "$status" -eq 0 ]] || { printf 'parent-A route failed: %s\n' "$output" >&2; exit 1; }
marker_a="$(grep -o 'independent-review-finding:[^ ]*' "$TEST_ROOT/td.log" | head -1)"
[[ -n "$marker_a" ]] || { printf 'no dedup marker recorded for parent A\n' >&2; exit 1; }

TD_LIST_RESULT="[{\"id\":\"td-parent-a-card\",\"status\":\"closed\",\"description\":\"Deduplication key: $marker_a\"}]" \
  ROUTER_PARENT_TASK=td-parent-b ROUTER_BRANCH=feat/b run_router "$TEST_ROOT/spec1-parent-b.json"
[[ "$status" -eq 0 ]] || { printf 'parent-B route failed: %s\n' "$output" >&2; exit 1; }
if grep -Eq '^(reopen|update) td-parent-a-card' "$TEST_ROOT/td.log"; then
  printf 'cross-parent finding collision reopened or overwrote an unrelated card\n' >&2
  exit 1
fi
grep -q '^create ' "$TEST_ROOT/td.log" || {
  printf 'cross-parent finding did not create a new card\n' >&2
  exit 1
}
marker_b="$(grep -o 'independent-review-finding:[^ ]*' "$TEST_ROOT/td.log" | head -1)"
[[ "$marker_a" != "$marker_b" ]] || {
  printf 'dedup marker is not scoped to the parent task and branch: %s\n' "$marker_a" >&2
  exit 1
}
[[ "$marker_a" == *td-parent-a* && "$marker_a" == *feat/a* ]] || {
  printf 'dedup marker omits the parent task or branch: %s\n' "$marker_a" >&2
  exit 1
}
[[ "$marker_b" == *td-parent-b* && "$marker_b" == *feat/b* ]] || {
  printf 'dedup marker omits the parent task or branch: %s\n' "$marker_b" >&2
  exit 1
}

# Same parent task and branch must still dedup onto the same card.
TD_LIST_RESULT="[{\"id\":\"td-same-scope\",\"status\":\"open\",\"description\":\"Deduplication key: $marker_a\"}]" \
  ROUTER_PARENT_TASK=td-parent-a ROUTER_BRANCH=feat/a run_router "$TEST_ROOT/spec1-parent-a.json"
grep -Fq 'update td-same-scope' "$TEST_ROOT/td.log" || {
  printf 'same-scope rerun did not dedup onto the existing card\n' >&2
  exit 1
}

# ── td-52d7c2: a dedup update must preserve the previous description and
# reconcile the title, so review evidence is never destroyed and the title and
# body cannot describe different findings. ───────────────────────────────────
stored_marker='independent-review-finding:app:standards:code-review:std-1:td-parent:fix/review'
existing_card() {
  STORED_BODY="$1" STORED_STATUS="${2:-open}" python3 -c '
import json, os, sys
print(json.dumps([{
  "id": "td-revised",
  "status": os.environ["STORED_STATUS"],
  "defer_until": "",
  "labels": ["independent-review", "finding", "standards"],
  "description": os.environ["STORED_BODY"],
}]))'
}

read -r -d '' stored_body <<STORED || true
Independent review finding.

Review axis: standards
Review source: code-review
Severity: warning
Summary: Original recorded finding
Evidence: bin/original:7 original evidence marker
Affected paths: bin/original
Acceptance criteria: original criterion
Recommended remediation: original remediation
Branch: fix/review
Head SHA: abc1234
Parent mission: td-parent
Originating fleet task: fleet-1

Deduplication key: $stored_marker
Finding content digest: 0000000000000000
STORED

TD_LIST_RESULT="$(existing_card "$stored_body")" run_router "$TEST_ROOT/findings.json"
grep -Fq 'update td-revised' "$TEST_ROOT/td.log"
grep -Fq 'bin/original:7 original evidence marker' "$TEST_ROOT/td.log" || {
  printf 'dedup update discarded the previous description\n' >&2
  exit 1
}
grep -Fq 'bin/run:42 can remove another pane' "$TEST_ROOT/td.log" || {
  printf 'dedup update did not record the incoming finding\n' >&2
  exit 1
}
grep -Fq -- '--title review: Unsafe cleanup' "$TEST_ROOT/td.log" || {
  printf 'dedup update did not reconcile the title with the new finding\n' >&2
  exit 1
}
grep -Fq 'Summary: Unsafe cleanup' "$TEST_ROOT/td.log" || {
  printf 'finding summary is not recorded in the body\n' >&2
  exit 1
}

# An unchanged rerun must refresh the current revision in place, not stack a
# duplicate revision on every routing pass.
# A pristine card is one the router itself wrote, so capture a real one rather
# than hand-building a body the router cannot prove it authored.
TD_LIST_RESULT=null ROUTER_TASK_ID=fleet-old run_router "$TEST_ROOT/one.json"
unchanged_body="$(cat "$TEST_ROOT/td-desc")"
TD_LIST_RESULT="$(existing_card "$unchanged_body")" run_router "$TEST_ROOT/one.json"
grep -Fq 'update td-revised' "$TEST_ROOT/td.log"
[[ "$(grep -c 'Superseded revision (preserved)' "$TEST_ROOT/td.log")" -eq 0 ]] || {
  printf 'unchanged rerun stacked a duplicate revision\n' >&2
  exit 1
}
grep -Fq 'Originating fleet task: fleet-1' "$TEST_ROOT/td.log" || {
  printf 'unchanged rerun did not refresh the current revision metadata\n' >&2
  exit 1
}

# A closed card whose stored finding differs from the incoming finding must not be
# SILENTLY reopened: it is reopened with the stored body kept verbatim as a
# preserved revision and an explicit reconciliation warning is printed. It must
# not abort the batch, because the normal remediate/close/rerun loop shifts a
# finding's evidence and so changes its digest (td-f36fd3).
TD_LIST_RESULT="$(existing_card "$stored_body" closed)" run_router "$TEST_ROOT/findings.json"
grep -Fq 'reopen td-revised' "$TEST_ROOT/td.log" || {
  printf 'closed mismatched card was not reopened\n' >&2
  exit 1
}
grep -Fq 'update td-revised' "$TEST_ROOT/td.log" || {
  printf 'closed mismatched card was not updated\n' >&2
  exit 1
}
[[ "$output" == *'records a different finding'* ]] || {
  printf 'closed mismatched card was reopened without a reconciliation warning: %s\n' "$output" >&2
  exit 1
}
# The obligation must also be durable in td, not only in the worker's stderr
# (td-3ab1c1, td-a1452c, td-f45e3c).
grep -Fq 'needs-reconciliation' "$TEST_ROOT/td.log" || {
  printf 'reopened closed card carries no durable needs-reconciliation label\n' >&2
  exit 1
}
grep -Fq 'bin/original:7 original evidence marker' "$TEST_ROOT/td.log" || {
  printf 'closed mismatched card lost its stored description\n' >&2
  exit 1
}
grep -Fq 'Superseded revision (preserved)' "$TEST_ROOT/td.log" || {
  printf 'closed mismatched card did not preserve the stored body as a revision\n' >&2
  exit 1
}
# The rest of the batch must still route: std-2 follows std-1 in findings.json.
grep -Fq 'Long function' "$TEST_ROOT/td.log" || {
  printf 'a reconciled closed card aborted the remaining findings in the batch\n' >&2
  exit 1
}

# A closed card recording the SAME finding still reopens and updates, with no
# reconciliation warning because nothing needed reconciling.
TD_LIST_RESULT="$(existing_card "$unchanged_body" closed)" run_router "$TEST_ROOT/findings.json"
grep -Fq 'reopen td-revised' "$TEST_ROOT/td.log"
grep -Fq 'update td-revised' "$TEST_ROOT/td.log"
[[ "$output" != *'records a different finding'* ]] || {
  printf 'unchanged closed card produced a spurious reconciliation warning\n' >&2
  exit 1
}
if grep -Fq 'needs-reconciliation' "$TEST_ROOT/td.log"; then
  printf 'unchanged closed card was labelled needs-reconciliation\n' >&2
  exit 1
fi

# td-4e009d / td-8c1e7b: a card predating content digests cannot be compared, so
# the router must say so rather than asserting it records a different finding.
read -r -d '' digestless_body <<DIGESTLESS || true
Independent readiness review finding.

Review axis: standards
Review source: code-review

Deduplication key: $stored_marker
DIGESTLESS
TD_LIST_RESULT="$(existing_card "$digestless_body" closed)" run_router "$TEST_ROOT/findings.json"
grep -Fq 'reopen td-revised' "$TEST_ROOT/td.log"
[[ "$output" == *'predates content digests'* ]] || {
  printf 'a digestless closed card was not reported as uncomparable: %s\n' "$output" >&2
  exit 1
}
[[ "$output" != *'records a different finding'* ]] || {
  printf 'a digestless closed card was falsely reported as a different finding: %s\n' "$output" >&2
  exit 1
}
grep -Fq 'Independent readiness review finding.' "$TEST_ROOT/td.log" || {
  printf 'a digestless closed card lost its stored description\n' >&2
  exit 1
}

# An unchanged rerun must not discard text the router did not write. A card whose
# CURRENT revision block carries a human annotation is preserved as a superseded
# revision rather than replaced in place (td-898b65).
read -r -d '' annotated_body <<ANNOTATED || true
Independent review finding.

Review axis: standards
Review source: code-review
Severity: error
Summary: Unsafe cleanup
Evidence: bin/run:42 can remove another pane
Affected paths: bin/run
Acceptance criteria: Match exact pane identity
Recommended remediation: Use exact identity matching
Branch: fix/review
Head SHA: abc1234
Parent mission: td-parent
Originating fleet task: fleet-1

Deduplication key: $stored_marker
Finding content digest: $std1_digest

Update from the owning worker: partially remediated in commit deadbee; the pane
identity check landed but the ledger invariant is still open.
ANNOTATED
TD_LIST_RESULT="$(existing_card "$annotated_body")" run_router "$TEST_ROOT/one.json"
grep -Fq 'update td-revised' "$TEST_ROOT/td.log"
grep -Fq 'partially remediated in commit deadbee' "$TEST_ROOT/td.log" || {
  printf 'unchanged rerun discarded a human annotation from the current revision\n' >&2
  exit 1
}
grep -Fq 'Superseded revision (preserved)' "$TEST_ROOT/td.log" || {
  printf 'annotated card was refreshed in place instead of preserving the annotation\n' >&2
  exit 1
}

[[ "$output" == *'previous revision preserved'* ]] || {
  printf 'preserving a revision was not reported on stdout: %s\n' "$output" >&2
  exit 1
}

# Once the annotation is preserved below the separator, a further unchanged rerun
# refreshes in place rather than stacking a revision every pass. Driven as a real
# round trip: the description the router just wrote becomes the stored
# description for the next route, so the settling claim is proved by the router's
# own output rather than a hand-written fixture (td-bdce0f).
TD_LIST_RESULT="$(existing_card "$(cat "$TEST_ROOT/td-desc")")" run_router "$TEST_ROOT/one.json"
[[ "$(grep -c 'Superseded revision (preserved)' "$TEST_ROOT/td.log")" -eq 1 ]] || {
  printf 'a settled card stacked another revision on an unchanged rerun\n' >&2
  exit 1
}
grep -Fq 'partially remediated in commit deadbee' "$TEST_ROOT/td.log" || {
  printf 'a settled card lost its preserved revision\n' >&2
  exit 1
}
[[ "$output" != *'previous revision preserved'* ]] || {
  printf 'a settled unchanged rerun still reported preserving a revision: %s\n' "$output" >&2
  exit 1
}

# td-257734 / td-c4acbc / td-bdce0f: a human edit made INLINE on a line the router
# owns must survive. The fixture MUST be the router's own output, so the stored
# block carries a valid provenance digest and the assertion is about the digest
# VALUE rather than the mere presence of a digest line. Reducing untouched() to a
# label-presence check must fail these cases.
TD_LIST_RESULT=null run_router "$TEST_ROOT/one.json"
pristine_body="$(cat "$TEST_ROOT/td-desc")"
[[ -n "$pristine_body" ]] || { printf 'no pristine router body captured\n' >&2; exit 1; }
grep -q '^Revision block digest: [0-9a-f]\{32\}$' <<< "$pristine_body" || {
  printf 'router body carries no provenance digest\n' >&2
  exit 1
}

edit_body_line() {
  # Replace exactly the line with the given prefix, leaving every other byte of
  # the router-written block, including its provenance digest, untouched.
  SRC="$1" PREFIX="$2" REPLACEMENT="$3" python3 -c '
import os, sys
prefix = os.environ["PREFIX"]
replacement = os.environ["REPLACEMENT"]
lines = os.environ["SRC"].split("\n")
hit = False
for i, line in enumerate(lines):
    if line.startswith(prefix):
        lines[i] = replacement
        hit = True
        break
if not hit:
    sys.exit("fixture prefix not present: " + prefix)
sys.stdout.write("\n".join(lines))'
}

while IFS='|' read -r _prefix _replacement; do
  [[ -n "$_prefix" ]] || continue
  inline_body="$(edit_body_line "$pristine_body" "$_prefix" "$_replacement")" || exit 1
  # Prove the fixture actually changed the line it names and nothing else.
  [[ "$inline_body" != "$pristine_body" ]] || {
    printf 'inline fixture did not modify the body: %s\n' "$_prefix" >&2
    exit 1
  }
  grep -Fq -- "$_replacement" <<< "$inline_body" || {
    printf 'inline fixture did not contain its replacement: %s\n' "$_replacement" >&2
    exit 1
  }
  grep -q '^Revision block digest: [0-9a-f]\{32\}$' <<< "$inline_body" || {
    printf 'inline fixture lost the provenance digest: %s\n' "$_prefix" >&2
    exit 1
  }
  TD_LIST_RESULT="$(existing_card "$inline_body")" run_router "$TEST_ROOT/one.json"
  grep -Fq -- "$_replacement" "$TEST_ROOT/td.log" || {
    printf 'an inline human edit on a router-owned line was discarded: %s\n' "$_replacement" >&2
    exit 1
  }
  grep -Fq 'Superseded revision (preserved)' "$TEST_ROOT/td.log" || {
    printf 'an inline human edit did not force revision preservation: %s\n' "$_prefix" >&2
    exit 1
  }
done <<'INLINE_CASES'
Severity: |Severity: error (downgraded to warning by lars, see thread)
Acceptance criteria: |Acceptance criteria: Match exact pane identity -- and the ledger invariant
Independent review finding.|Independent review finding. DO NOT CLOSE, see thread
Evidence: |Evidence: bin/run:42 can remove another pane -- also reproduced by lars
INLINE_CASES

# Tampering ONLY the provenance digest value, leaving every body line pristine,
# must also force preservation: the block can no longer be proved to be router
# output.
tampered_body="$(edit_body_line "$pristine_body" 'Revision block digest: ' \
  'Revision block digest: 00000000000000000000000000000000')"
TD_LIST_RESULT="$(existing_card "$tampered_body")" run_router "$TEST_ROOT/one.json"
grep -Fq 'Superseded revision (preserved)' "$TEST_ROOT/td.log" || {
  printf 'a tampered provenance digest did not force revision preservation\n' >&2
  exit 1
}
[[ "$output" == *'previous revision preserved'* ]] || {
  printf 'a tampered provenance digest was not reported: %s\n' "$output" >&2
  exit 1
}

# td-9de8aa title half: the router overwrites the card title on every update, so a
# stored title carrying content absent from the body must be preserved. This is
# the shape of the real cards td-36da4d and td-0fc5bf, whose summary exists only
# in their title.
TD_LIST_RESULT="$(TITLED_BODY="$pristine_body" python3 -c '
import json, os
print(json.dumps([{"id":"td-titled","status":"open","defer_until":"",
                   "labels":["independent-review","finding","standards"],
                   "title":"review: the only copy of this summary lives in the title",
                   "description":os.environ["TITLED_BODY"]}]))')" \
  run_router "$TEST_ROOT/one.json"
grep -Fq 'update td-titled' "$TEST_ROOT/td.log"
grep -Fq 'Previous title: review: the only copy of this summary lives in the title' "$TEST_ROOT/td.log" || {
  printf 'a dedup update discarded the previous card title\n' >&2
  exit 1
}
grep -Fq 'Superseded revision (preserved)' "$TEST_ROOT/td.log" || {
  printf 'a changed title did not force revision preservation\n' >&2
  exit 1
}

# A stored title equal to the one the router is about to write is not a change and
# must not stack a revision.
TD_LIST_RESULT="$(TITLED_BODY="$pristine_body" python3 -c '
import json, os
print(json.dumps([{"id":"td-titled","status":"open","defer_until":"",
                   "labels":["independent-review","finding","standards"],
                   "title":"review: Unsafe cleanup",
                   "description":os.environ["TITLED_BODY"]}]))')" \
  run_router "$TEST_ROOT/one.json"
[[ "$(grep -c 'Superseded revision (preserved)' "$TEST_ROOT/td.log")" -eq 0 ]] || {
  printf 'an unchanged title stacked a preserved revision\n' >&2
  exit 1
}

# A pristine router-written card whose only difference is metadata the router
# rewrites every pass (head SHA, fleet task) must still refresh in place, or every
# rerun would stack a revision.
TD_LIST_RESULT=null run_router "$TEST_ROOT/one.json"
pristine_desc="$(cat "$TEST_ROOT/td-desc")"
TD_LIST_RESULT="$(existing_card "$pristine_desc")" ROUTER_TASK_ID=fleet-later \
  run_router "$TEST_ROOT/one.json"
[[ "$(grep -c 'Superseded revision (preserved)' "$TEST_ROOT/td.log")" -eq 0 ]] || {
  printf 'a metadata-only change stacked a preserved revision\n' >&2
  exit 1
}
grep -Fq 'Originating fleet task: fleet-later' "$TEST_ROOT/td.log" || {
  printf 'a metadata-only refresh did not update the fleet task\n' >&2
  exit 1
}
[[ "$output" != *'previous revision preserved'* ]] || {
  printf 'a metadata-only refresh reported preserving a revision\n' >&2
  exit 1
}

# ── td-61a0c8: the router must accept exactly the shared axis vocabulary ──────
# bin/sgt-dispatch mandates an independent readiness review and tells workers to
# route each axis with this command, so `readiness` must route end to end.
# shellcheck source=bin/_sgt-review-axes.sh
source "$ROOT_DIR/bin/_sgt-review-axes.sh"

ROUTER_AXIS=readiness run_router "$TEST_ROOT/findings.json"
[[ "$status" -eq 2 ]] || { printf 'readiness route did not gate on its error finding: %s\n' "$output" >&2; exit 1; }
[[ "$output" != *'invalid review axis'* ]] || {
  printf 'router rejected the readiness axis the dispatch contract demands\n' >&2
  exit 1
}
grep -Fq 'Review axis: readiness' "$TEST_ROOT/td.log"
grep -Fq 'independent-review-finding:app:readiness:code-review:std-1:td-parent:fix/review' "$TEST_ROOT/td.log"
grep -Fq -- '--labels independent-review,finding,readiness' "$TEST_ROOT/td.log"
grep -Fq 'Review axis: readiness' "$WORKTREE/.sergeant-message"
grep -Fq 'blocked [app]' "$TEST_ROOT/notify.log"
[[ -f "$WORKTREE/.sergeant-review-gates/readiness-code-review" ]] || {
  printf 'readiness axis did not publish its own review gate\n' >&2
  exit 1
}

# Every axis in the shared definition routes; nothing outside it does.
for _axis in $(_sgt_review_axes); do
  ROUTER_AXIS="$_axis" run_router "$TEST_ROOT/clean.json"
  [[ "$status" -eq 0 ]] || {
    printf 'router rejected shared review axis %s: %s\n' "$_axis" "$output" >&2
    exit 1
  }
  _sgt_review_axis_guidance "$_axis" >/dev/null || {
    printf 'shared review axis %s has no reviewer guidance\n' "$_axis" >&2
    exit 1
  }
done
for _axis in invalid performance security; do
  ROUTER_AXIS="$_axis" run_router "$TEST_ROOT/clean.json"
  [[ "$status" -eq 2 ]] || {
    printf 'router accepted unshared review axis %s\n' "$_axis" >&2
    exit 1
  }
  [[ "$(cat "$WORKTREE/.sergeant-status")" == 'blocked' ]]
done

# ── td-61a0c8: a routing failure must retain a sanitized, retryable artifact ───
run_retry() {
  : > "$TEST_ROOT/td.log"
  : > "$TEST_ROOT/td-ids"
  : > "$TEST_ROOT/notify.log"
  : > "$TEST_ROOT/mv.log"
  set +e
  output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
    REPO_PATH="$REPO" TD_LOG="$TEST_ROOT/td.log" TD_IDS="$TEST_ROOT/td-ids" \
    NOTIFY_LOG="$TEST_ROOT/notify.log" MV_LOG="$TEST_ROOT/mv.log" \
    ROUTER_WORKTREE="$WORKTREE" SERGEANT_CONFIG="$TEST_ROOT/config" \
    TD_LIST_RESULT="${TD_LIST_RESULT:-[]}" TD_FAIL_CREATE="${TD_FAIL_CREATE:-0}" \
    "$INSTALLED_BIN/sgt-review-findings" test app \
      --retry "$1" --worktree "$WORKTREE" 2>&1)"
  status=$?
  set -e
}

printf '{"findings":[
  {"id":"warn-1","severity":"warning","disposition":"actionable","summary":"First debt","evidence":"bin/one:1 first evidence","paths":["bin/one"],"acceptance_criteria":"Fix one","recommendation":"Do one"},
  {"id":"warn-2","severity":"warning","disposition":"actionable","summary":"Second debt","evidence":"bin/two:2 second evidence","paths":["bin/two"],"acceptance_criteria":"Fix two","recommendation":"Do two"}
]}\n' > "$TEST_ROOT/warn.json"

artifact="$WORKTREE/.sergeant-review-artifacts/standards-code-review"
TD_FAIL_CREATE=1 run_router "$TEST_ROOT/warn.json"
[[ "$status" -eq 2 && "$output" == *'failed to create td task'* ]] || {
  printf 'td create failure did not fail the route: %s\n' "$output" >&2
  exit 1
}
[[ -f "$artifact/findings" && -f "$artifact/meta" ]] || {
  printf 'routing failure destroyed the only copy of the parsed findings\n' >&2
  exit 1
}
grep -Fq -- "--retry $artifact" "$WORKTREE/.sergeant-message" || {
  printf 'blocked message does not name a supported retry command: %s\n' \
    "$(cat "$WORKTREE/.sergeant-message")" >&2
  exit 1
}
if grep -Fq 'No review body was retained' "$WORKTREE/.sergeant-message"; then
  printf 'blocked message still claims nothing was retained\n' >&2
  exit 1
fi
grep -Fq 'axis=standards' "$artifact/meta"
grep -Fq 'source=code-review' "$artifact/meta"
grep -Fq 'branch=fix/review' "$artifact/meta"
grep -Fq 'parent_task=td-parent' "$artifact/meta"
grep -Fq 'task_id=fleet-1' "$artifact/meta"

# The retry routes the retained findings without the original reviewer output.
retained_findings="$artifact/findings"
cp "$retained_findings" "$TEST_ROOT/retained-copy"
run_retry "$artifact"
[[ "$status" -eq 0 ]] || { printf 'retry from the retained artifact failed: %s\n' "$output" >&2; exit 1; }
[[ "$(grep -c '^create ' "$TEST_ROOT/td.log")" -eq 2 ]] || {
  printf 'retry did not route every retained finding\n' >&2
  exit 1
}
grep -Fq 'Review axis: standards' "$TEST_ROOT/td.log"
grep -Fq 'bin/one:1 first evidence' "$TEST_ROOT/td.log"
grep -Fq 'bin/two:2 second evidence' "$TEST_ROOT/td.log"
grep -Fq 'independent-review-finding:app:standards:code-review:warn-1:td-parent:fix/review' "$TEST_ROOT/td.log"
[[ ! -e "$artifact" ]] || {
  printf 'successful retry left a stale retry artifact behind\n' >&2
  exit 1
}

# A successful route retains no artifact at all.
run_router "$TEST_ROOT/warn.json"
[[ "$status" -eq 0 ]] || { printf 'clean warning route failed: %s\n' "$output" >&2; exit 1; }
[[ ! -e "$artifact" ]] || {
  printf 'successful route retained a retry artifact\n' >&2
  exit 1
}

# A parse failure has nothing parsed to retain, so no retry must be advertised.
run_router "$TEST_ROOT/malformed.json"
[[ "$status" -eq 2 ]]
[[ ! -e "$artifact" ]] || {
  printf 'parse failure published an artifact with no parsed findings\n' >&2
  exit 1
}
if grep -Fq -- '--retry' "$WORKTREE/.sergeant-message"; then
  printf 'parse failure advertised a retry artifact that does not exist\n' >&2
  exit 1
fi

# The retained artifact must carry only sanitized findings — no secrets and no
# raw reviewer JSON.
TD_FAIL_CREATE=1 run_router "$TEST_ROOT/secrets.json"
[[ -f "$artifact/findings" ]]
if grep -Eaq 'super-secret|raw-token|hidden-value|hunter2|dXNlcjpwYXNz|ghp_|AKIA|user:pass|BEGIN PRIVATE KEY' \
   "$artifact/findings" "$artifact/meta"; then
  printf 'retained retry artifact contains unredacted secrets\n' >&2
  exit 1
fi
if grep -Faq '"disposition"' "$artifact/findings"; then
  printf 'retained retry artifact contains raw reviewer output\n' >&2
  exit 1
fi
grep -aFq '[REDACTED]' "$artifact/findings"

# --retry must refuse a path outside the worktree artifact root.
mkdir -p "$TEST_ROOT/elsewhere/standards-code-review"
cp "$TEST_ROOT/retained-copy" "$TEST_ROOT/elsewhere/standards-code-review/findings"
printf 'project=test\nrepo=app\naxis=standards\nsource=code-review\nbranch=fix/review\nhead_sha=abc1234\nparent_task=td-parent\ntask_id=fleet-1\n' \
  > "$TEST_ROOT/elsewhere/standards-code-review/meta"
run_retry "$TEST_ROOT/elsewhere/standards-code-review"
[[ "$status" -eq 2 ]] || { printf 'retry accepted an artifact outside the worktree\n' >&2; exit 1; }
if grep -Eq '^(create|update) ' "$TEST_ROOT/td.log"; then
  printf 'retry outside the worktree reached td\n' >&2
  exit 1
fi
run_retry "$WORKTREE/.sergeant-review-artifacts/../../escape"
[[ "$status" -eq 2 ]] || { printf 'retry accepted a traversal path\n' >&2; exit 1; }

# --retry and --input are mutually exclusive.
mkdir -p "$artifact"
cp "$TEST_ROOT/retained-copy" "$artifact/findings"
printf 'project=test\nrepo=app\naxis=standards\nsource=code-review\nbranch=fix/review\nhead_sha=abc1234\nparent_task=td-parent\ntask_id=fleet-1\n' > "$artifact/meta"
set +e
output="$(PATH="$TEST_ROOT/fake-bin:$PATH" REPO_PATH="$REPO" TD_LOG="$TEST_ROOT/td.log" \
  TD_IDS="$TEST_ROOT/td-ids" NOTIFY_LOG="$TEST_ROOT/notify.log" MV_LOG="$TEST_ROOT/mv.log" \
  ROUTER_WORKTREE="$WORKTREE" SERGEANT_CONFIG="$TEST_ROOT/config" \
  "$INSTALLED_BIN/sgt-review-findings" test app --retry "$artifact" \
    --input "$TEST_ROOT/warn.json" --worktree "$WORKTREE" 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 ]] || { printf '--retry accepted a conflicting --input\n' >&2; exit 1; }

# A retry whose meta names a different project or repo must refuse.
printf 'project=other\nrepo=app\naxis=standards\nsource=code-review\nbranch=fix/review\nhead_sha=abc1234\nparent_task=td-parent\ntask_id=fleet-1\n' > "$artifact/meta"
run_retry "$artifact"
[[ "$status" -eq 2 ]] || { printf 'retry accepted mismatched project metadata\n' >&2; exit 1; }
if grep -Eq '^(create|update) ' "$TEST_ROOT/td.log"; then
  printf 'retry with mismatched metadata reached td\n' >&2
  exit 1
fi

# ── td-61a0c8 (owner decision, Option A): canonical severities plus a shared
# alias table. Canonical set is error|warning|info; every accepted reviewer
# spelling normalizes to one of them and maps to a fixed td priority. Only the
# `error` family publishes a blocking gate. ───────────────────────────────────
severity_finding() {
  printf '{"findings":[{"id":"sev-1","severity":"%s","disposition":"actionable","summary":"Severity mapping","evidence":"bin/sev:1 evidence","paths":["bin/sev"],"acceptance_criteria":"Map it","recommendation":"Fix it"}]}\n' \
    "$1" > "$TEST_ROOT/severity.json"
}

# canonical value -> priority, and alias -> the same canonical priority.
for _case in \
    'error P1 blocking' \
    'blocker P1 blocking' \
    'critical P1 blocking' \
    'high P1 blocking' \
    'warning P2 debt' \
    'major P2 debt' \
    'medium P2 debt' \
    'info P3 debt' \
    'minor P3 debt' \
    'low P3 debt' \
    'informational P3 debt'; do
  # shellcheck disable=SC2086  # deliberate word splitting of the case tuple
  set -- $_case
  _severity="$1" _expect_priority="$2" _expect_gate="$3"
  severity_finding "$_severity"
  run_router "$TEST_ROOT/severity.json"
  grep -Fq -- "--priority $_expect_priority" "$TEST_ROOT/td.log" || {
    printf 'severity %s did not map to %s\n' "$_severity" "$_expect_priority" >&2
    exit 1
  }
  # The body records the canonical severity, so an alias and its canonical
  # spelling describe one finding rather than two.
  case "$_expect_priority" in
    P1) _canonical=error ;;
    P2) _canonical=warning ;;
    P3) _canonical=info ;;
  esac
  grep -Fq "Severity: $_canonical" "$TEST_ROOT/td.log" || {
    printf 'severity %s was not normalized to %s in the body\n' "$_severity" "$_canonical" >&2
    exit 1
  }
  if [[ "$_expect_gate" == blocking ]]; then
    [[ "$status" -eq 2 ]] || {
      printf 'severity %s did not publish a blocking gate\n' "$_severity" >&2
      exit 1
    }
    [[ "$(cat "$WORKTREE/.sergeant-status")" == 'blocked' ]] || {
      printf 'severity %s did not block the worker\n' "$_severity" >&2
      exit 1
    }
    grep -Fq 'blocked [app]' "$TEST_ROOT/notify.log" || {
      printf 'severity %s did not notify a blocking gate\n' "$_severity" >&2
      exit 1
    }
  else
    [[ "$status" -eq 0 ]] || {
      printf 'severity %s blocked the worker but must route as debt: %s\n' "$_severity" "$output" >&2
      exit 1
    }
    # run_router starts from cleared fleet state, so a non-blocking route leaves
    # no status at all rather than writing one.
    [[ "$(cat "$WORKTREE/.sergeant-status" 2>/dev/null || true)" != 'blocked' ]] || {
      printf 'severity %s blocked the worker\n' "$_severity" >&2
      exit 1
    }
    [[ ! -s "$TEST_ROOT/notify.log" ]] || {
      printf 'severity %s published a blocking notification\n' "$_severity" >&2
      exit 1
    }
  fi
done

# An alias records the reviewer's reported spelling for provenance without
# changing the canonical severity.
severity_finding high
run_router "$TEST_ROOT/severity.json"
grep -Fq 'Reported severity: high' "$TEST_ROOT/td.log" || {
  printf 'aliased severity did not record the reported spelling\n' >&2
  exit 1
}
# A canonical spelling needs no provenance line.
severity_finding error
run_router "$TEST_ROOT/severity.json"
if grep -Fq 'Reported severity:' "$TEST_ROOT/td.log"; then
  printf 'canonical severity added a redundant reported-severity line\n' >&2
  exit 1
fi

# An alias and its canonical spelling are the same finding, so re-routing one
# after the other must not stack a preserved revision.
severity_finding high
run_router "$TEST_ROOT/severity.json"
sev_digest="$(grep -o 'Finding content digest: [0-9a-f]*' "$TEST_ROOT/td.log" | head -1 | awk '{print $4}')"
severity_finding error
run_router "$TEST_ROOT/severity.json"
[[ "$(grep -o 'Finding content digest: [0-9a-f]*' "$TEST_ROOT/td.log" | head -1 | awk '{print $4}')" == "$sev_digest" ]] || {
  printf 'alias and canonical spelling produced different content digests\n' >&2
  exit 1
}

# A severity outside the canonical set and alias table is rejected, and the
# message names the accepted values.
severity_finding urgent
run_router "$TEST_ROOT/severity.json"
[[ "$status" -eq 2 ]] || { printf 'unaccepted severity was routed: %s\n' "$output" >&2; exit 1; }
[[ "$output" == *'sev-1'* ]] || {
  printf 'severity rejection did not name the offending finding: %s\n' "$output" >&2
  exit 1
}
for _accepted in error blocker critical high warning major medium info minor low informational; do
  [[ "$output" == *"$_accepted"* ]] || {
    printf 'severity rejection did not name accepted value %s: %s\n' "$_accepted" "$output" >&2
    exit 1
  }
done
if grep -Eq '^(create|update) ' "$TEST_ROOT/td.log"; then
  printf 'unaccepted severity reached td\n' >&2
  exit 1
fi

# The shared definition is the single source of truth: every accepted spelling it
# lists must route, and its priority must match the shared mapping.
for _accepted in $(_sgt_review_severity_accepted); do
  severity_finding "$_accepted"
  run_router "$TEST_ROOT/severity.json"
  _shared_priority="$(_sgt_review_severity_priority "$_accepted")" || {
    printf 'shared definition accepts %s but maps it to no priority\n' "$_accepted" >&2
    exit 1
  }
  grep -Fq -- "--priority $_shared_priority" "$TEST_ROOT/td.log" || {
    printf 'router disagreed with the shared priority mapping for %s\n' "$_accepted" >&2
    exit 1
  }
done

# The usage text documents the canonical set and the alias table.
set +e
usage_output="$("$INSTALLED_BIN/sgt-review-findings" 2>&1)"
set -e
[[ "$usage_output" == *"error|warning|info"* ]] || {
  printf 'usage text does not document the canonical severity set: %s\n' "$usage_output" >&2
  exit 1
}
[[ "$usage_output" == *"$(_sgt_review_severity_alias_table)"* ]] || {
  printf 'usage text does not document the shared alias table: %s\n' "$usage_output" >&2
  exit 1
}


# ── td-898b65: the router-owned line allowlist must cover every line the router
# writes into a card body, or the "did a human edit this block?" check would
# misread a new router line as an annotation and stack a preserved revision on
# every unchanged rerun. The router asserts this about its own composed body on
# each dedup update, so every dedup test above already exercises it; this case
# pins the failure mode explicitly by planting an unrecognised line in the stored
# CURRENT block and proving it is treated as content to preserve.
read -r -d '' foreign_line_body <<FOREIGN || true
Independent review finding.

Review axis: standards
Review source: code-review
Severity: error
Summary: Unsafe cleanup
Evidence: bin/run:42 can remove another pane
Affected paths: bin/run
Acceptance criteria: Match exact pane identity
Recommended remediation: Use exact identity matching
Branch: fix/review
Head SHA: abc1234
Parent mission: td-parent
Originating fleet task: fleet-1
Unrecognised prefix: this line is not one the router writes

Deduplication key: $stored_marker
Finding content digest: $std1_digest
FOREIGN
TD_LIST_RESULT="$(existing_card "$foreign_line_body")" run_router "$TEST_ROOT/findings.json"
grep -Fq 'Unrecognised prefix: this line is not one the router writes' "$TEST_ROOT/td.log" || {
  printf 'an unrecognised stored body line was discarded instead of preserved\n' >&2
  exit 1
}
grep -Fq 'Superseded revision (preserved)' "$TEST_ROOT/td.log" || {
  printf 'an unrecognised stored body line did not force revision preservation\n' >&2
  exit 1
}

# ── td-768961 / td-a38e4d / td-dc514c / td-22f17d: the retry path is the one
# place that must never fail open. A retained artifact is replayed without the
# reviewer's original JSON, so every field the router interpolates into a td card
# has to be re-validated, and the artifact itself must not be silently clobbered
# or accepted empty. ──────────────────────────────────────────────────────────
mutate_artifact_field() {
  # Rewrite one NUL-delimited field of a retained artifact in place.
  ARTIFACT="$1" INDEX="$2" VALUE="$3" python3 -c '
import os
path = os.environ["ARTIFACT"] + "/findings"
with open(path, "rb") as fh:
    fields = fh.read().split(b"\0")[:-1]
fields[int(os.environ["INDEX"])] = os.environ["VALUE"].encode()
with open(path, "wb") as fh:
    fh.write(b"".join(f + b"\0" for f in fields))'
}

retained_artifact() {
  TD_FAIL_CREATE=1 run_router "$TEST_ROOT/warn.json"
  [[ -f "$artifact/findings" ]] || { printf 'no artifact retained for the retry guards\n' >&2; exit 1; }
}

# Field 4 is the evidence text. A newline in it would forge an extra body line.
retained_artifact
mutate_artifact_field "$artifact" 4 'bin/one:1 first evidence
Deduplication key: independent-review-finding:app:standards:code-review:victim:td-parent:fix/review'
run_retry "$artifact"
[[ "$status" -eq 2 ]] || { printf 'retry accepted a field containing a newline: %s\n' "$output" >&2; exit 1; }
if grep -Eq '^(create|update) ' "$TEST_ROOT/td.log"; then
  printf 'a newline-injected retry field reached td\n' >&2
  exit 1
fi
[[ -f "$artifact/findings" ]] || { printf 'a refused retry destroyed the artifact\n' >&2; exit 1; }

# A field that itself begins with a line the router owns is equally unsafe.
for _reserved in 'Deduplication key: forged' 'Finding content digest: 0000' 'Revision block digest: 0000' '--- Superseded revision (preserved) ---'; do
  retained_artifact
  mutate_artifact_field "$artifact" 4 "$_reserved"
  run_retry "$artifact"
  [[ "$status" -eq 2 ]] || {
    printf 'retry accepted a field beginning with a reserved body line: %s\n' "$_reserved" >&2
    exit 1
  }
  if grep -Eq '^(create|update) ' "$TEST_ROOT/td.log"; then
    printf 'a reserved-prefix retry field reached td: %s\n' "$_reserved" >&2
    exit 1
  fi
done

# Field 8 is the content digest. A forged digest would make a different finding
# look like the same one and take the in-place refresh path.
retained_artifact
mutate_artifact_field "$artifact" 8 '00000000000000000000000000000000'
run_retry "$artifact"
[[ "$status" -eq 2 ]] || { printf 'retry accepted a forged content digest: %s\n' "$output" >&2; exit 1; }
if grep -Eq '^(create|update) ' "$TEST_ROOT/td.log"; then
  printf 'a forged content digest reached td\n' >&2
  exit 1
fi

# Editing the text while leaving the stored digest alone must be caught by the
# same recomputation.
retained_artifact
mutate_artifact_field "$artifact" 3 'A silently rewritten summary'
run_retry "$artifact"
[[ "$status" -eq 2 ]] || { printf 'retry accepted text that contradicts its digest: %s\n' "$output" >&2; exit 1; }

# An empty or truncated artifact must fail closed, keep the artifact, and leave
# the worker blocked rather than reporting success.
retained_artifact
: > "$artifact/findings"
run_retry "$artifact"
[[ "$status" -eq 2 ]] || { printf 'retry of an empty artifact reported success: %s\n' "$output" >&2; exit 1; }
[[ -f "$artifact/findings" ]] || { printf 'retry of an empty artifact deleted it\n' >&2; exit 1; }
[[ "$(cat "$WORKTREE/.sergeant-status")" == 'blocked' ]] || {
  printf 'retry of an empty artifact cleared the blocked state\n' >&2
  exit 1
}
retained_artifact
python3 -c '
import sys
path = sys.argv[1]
with open(path, "rb") as fh:
    data = fh.read()
with open(path, "wb") as fh:
    fh.write(data[: len(data) // 3])' "$artifact/findings"
run_retry "$artifact"
[[ "$status" -eq 2 ]] || { printf 'retry of a truncated artifact reported success: %s\n' "$output" >&2; exit 1; }

# A fresh route must not silently overwrite an artifact nobody has retried yet.
retained_artifact
cp "$artifact/findings" "$TEST_ROOT/pending-findings"
PRESERVE_FLEET=1 run_router "$TEST_ROOT/findings.json"
[[ "$status" -eq 2 ]] || { printf 'a fresh route overwrote a pending artifact: %s\n' "$output" >&2; exit 1; }
[[ "$output" == *'--retry'* ]] || {
  printf 'refusing to clobber a pending artifact did not name the retry command: %s\n' "$output" >&2
  exit 1
}
cmp -s "$artifact/findings" "$TEST_ROOT/pending-findings" || {
  printf 'a pending retry artifact was modified by a later route\n' >&2
  exit 1
}

# Publication is atomic: a caller never observes findings without meta, and no
# staging directory is left behind.
TD_FAIL_CREATE=1 run_router "$TEST_ROOT/warn.json"
[[ -f "$artifact/findings" && -f "$artifact/meta" ]] || {
  printf 'artifact publication is not atomic\n' >&2
  exit 1
}
leftovers=("$WORKTREE/.sergeant-review-artifacts"/*)
for _entry in "${leftovers[@]}"; do
  [[ "$_entry" == "$artifact" ]] || {
    printf 'artifact publication left a staging entry behind: %s\n' "$_entry" >&2
    exit 1
  }
done

# ── td-deff3d / td-3ab1c1 / td-a1452c / td-f45e3c: the reconciliation obligation
# is durable for ANY preserved revision, not only when a closed card is reopened.
# An open card that gains a superseded revision needs the same human attention.
TD_LIST_RESULT=null run_router "$TEST_ROOT/one.json"
open_pristine="$(cat "$TEST_ROOT/td-desc")"
open_changed="$(edit_body_line "$open_pristine" 'Evidence: ' 'Evidence: edited by hand')"
TD_LIST_RESULT="$(existing_card "$open_changed")" run_router "$TEST_ROOT/one.json"
grep -Fq 'Superseded revision (preserved)' "$TEST_ROOT/td.log"
grep -Fq 'needs-reconciliation' "$TEST_ROOT/td.log" || {
  printf 'an OPEN card that gained a preserved revision carries no durable marker\n' >&2
  exit 1
}
[[ "$output" == *'reconcile'* ]] || {
  printf 'an OPEN card preservation was not reported as needing reconciliation: %s\n' "$output" >&2
  exit 1
}
# A pristine refresh must not acquire the marker.
TD_LIST_RESULT="$(existing_card "$open_pristine")" run_router "$TEST_ROOT/one.json"
if grep -Fq 'needs-reconciliation' "$TEST_ROOT/td.log"; then
  printf 'a pristine refresh was labelled needs-reconciliation\n' >&2
  exit 1
fi

# td-edae2b: the label must not ride the same td update that can fail after a
# successful reopen, or the obligation is lost in exactly that window.
TD_LIST_RESULT="$(existing_card "$open_changed" closed)" run_router "$TEST_ROOT/one.json"
label_line="$(grep -n 'needs-reconciliation' "$TEST_ROOT/td.log" | head -1 | cut -d: -f1)"
update_line="$(grep -n -- '^update .*--description' "$TEST_ROOT/td.log" | head -1 | cut -d: -f1)"
[[ -n "$label_line" && -n "$update_line" && "$label_line" -lt "$update_line" ]] || {
  printf 'the reconciliation label was not applied before the description update\n' >&2
  exit 1
}

# Any reopen of a closed card is reported, including the same-digest case that
# resurrects remediated debt into the open queue.
TD_LIST_RESULT="$(existing_card "$open_pristine" closed)" run_router "$TEST_ROOT/one.json"
grep -Fq 'reopen td-revised' "$TEST_ROOT/td.log"
[[ "$output" == *'reopened'* ]] || {
  printf 'a same-digest reopen was not reported at all: %s\n' "$output" >&2
  exit 1
}

# ── td-e56f73: a card written before provenance digests existed carries a content
# digest but no block digest. It must be reported as first-time stamping rather
# than as a revision that changed, and it must settle on the next route.
legacy_block="$(printf '%s\n' "$open_pristine" | grep -v '^Revision block digest: ')"
TD_LIST_RESULT="$(existing_card "$legacy_block")" run_router "$TEST_ROOT/one.json"
[[ "$output" == *'provenance stamped'* ]] || {
  printf 'a pre-provenance card was not reported as newly stamped: %s\n' "$output" >&2
  exit 1
}
grep -Fq 'Revision block digest: ' "$TEST_ROOT/td.log" || {
  printf 'a pre-provenance card was not stamped\n' >&2
  exit 1
}
TD_LIST_RESULT="$(existing_card "$(cat "$TEST_ROOT/td-desc")")" run_router "$TEST_ROOT/one.json"
[[ "$output" != *'provenance stamped'* ]] || {
  printf 'a stamped card was reported as newly stamped again\n' >&2
  exit 1
}

# ── td-b55433: an empty text field would emit a body line ending in a space, whose
# byte-exact digest any store-side normalisation would then defeat. Reject it.
printf '{"findings":[{"id":"empty-1","severity":"warning","disposition":"actionable","summary":"","evidence":"e","paths":["p"],"acceptance_criteria":"a","recommendation":"r"}]}\n' \
  > "$TEST_ROOT/empty-field.json"
run_router "$TEST_ROOT/empty-field.json"
[[ "$status" -eq 2 ]] || { printf 'an empty finding field was accepted: %s\n' "$output" >&2; exit 1; }
[[ "$output" == *'empty-1'* ]] || {
  printf 'an empty field rejection did not name the finding: %s\n' "$output" >&2
  exit 1
}

printf 'sgt-review-findings: ok\n'
