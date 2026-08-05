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

TD_LIST_RESULT="[{\"id\":\"td-existing\",\"status\":\"in_progress\",\"description\":\"Deduplication key: independent-review-finding:app:standards:code-review:std-1:td-parent:fix/review\nFinding content digest: $std1_digest\"}]" \
  run_router "$TEST_ROOT/findings.json"
grep -Fq 'update td-existing' "$TEST_ROOT/td.log"
grep -Fq 'Originating fleet task: fleet-1' "$TEST_ROOT/td.log"
if grep -Fq 'reopen td-existing' "$TEST_ROOT/td.log"; then
  printf 'rerun changed active finding state\n' >&2
  exit 1
fi

# dedup update with a different fleet task ID must write the new ID into the body
TD_LIST_RESULT="[{\"id\":\"td-existing\",\"status\":\"in_progress\",\"description\":\"Deduplication key: independent-review-finding:app:standards:code-review:std-1:td-parent:fix/review\nFinding content digest: $std1_digest\"}]" \
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
TD_LIST_RESULT="[{\"id\":\"td-deferred\",\"status\":\"in_progress\",\"defer_until\":\"2099-01-01\",\"description\":\"Deduplication key: independent-review-finding:app:standards:code-review:std-1:td-parent:fix/review\nFinding content digest: $std1_digest\"}]" \
  run_router "$TEST_ROOT/findings.json"
if grep -Fq 'defer td-deferred --clear' "$TEST_ROOT/td.log"; then
  printf 'deferred task had deferral cleared on rerun — must be preserved\n' >&2
  exit 1
fi
grep -Fq 'update td-deferred' "$TEST_ROOT/td.log"

# dedup update must preserve manually added labels — not replace them with only standard ones
TD_LIST_RESULT="[{\"id\":\"td-labelled\",\"status\":\"open\",\"defer_until\":\"\",\"labels\":[\"independent-review\",\"finding\",\"standards\",\"urgent\",\"security\"],\"description\":\"Deduplication key: independent-review-finding:app:standards:code-review:std-1:td-parent:fix/review\nFinding content digest: $std1_digest\"}]" \
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
spec1_digest="$(grep -o 'Finding content digest: [0-9a-f]*' "$TEST_ROOT/td.log" | head -1 | awk '{print $4}')"
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

# Same parent task and branch, and the same finding content, must still dedup onto
# the same card rather than refusing.
TD_LIST_RESULT="[{\"id\":\"td-same-scope\",\"status\":\"open\",\"description\":\"Deduplication key: $marker_a\nFinding content digest: $spec1_digest\"}]" \
  ROUTER_PARENT_TASK=td-parent-a ROUTER_BRANCH=feat/a run_router "$TEST_ROOT/spec1-parent-a.json"
grep -Fq 'update td-same-scope' "$TEST_ROOT/td.log" || {
  printf 'same-scope rerun did not dedup onto the existing card\n' >&2
  exit 1
}

# ── td-e0d2ee (owner decision): the REFUSAL branch. The router composes, compares
# and declines. It never reads a stored card body back to merge, reconcile or
# rewrite it, so a stored description and a stored title cannot be lost by a write
# that never happens, and a tampered stored body cannot inject anything — it can
# only cause a refusal. ───────────────────────────────────────────────────────
stored_marker='independent-review-finding:app:standards:code-review:std-1:td-parent:fix/review'
existing_card() {
  STORED_BODY="$1" STORED_STATUS="${2:-open}" STORED_TITLE="${3:-review: Unsafe cleanup}" python3 -c '
import json, os
print(json.dumps([{
  "id": "td-revised",
  "status": os.environ["STORED_STATUS"],
  "defer_until": "",
  "labels": ["independent-review", "finding", "standards"],
  "title": os.environ["STORED_TITLE"],
  "description": os.environ["STORED_BODY"],
}]))'
}

# A card the router wrote for THIS finding: its content digest matches, so a rerun
# deduplicates normally rather than refusing on every second write.
TD_LIST_RESULT=null run_router "$TEST_ROOT/one.json"
matching_body="$(cat "$TEST_ROOT/td-desc")"
[[ -n "$matching_body" ]] || { printf 'no routed body captured\n' >&2; exit 1; }

TD_LIST_RESULT="$(existing_card "$matching_body")" ROUTER_TASK_ID=fleet-later \
  run_router "$TEST_ROOT/one.json"
[[ "$status" -eq 2 ]] || { printf 'a matching rerun did not gate its error finding: %s\n' "$output" >&2; exit 1; }
[[ "$output" == *'td td-revised deduplicated'* ]] || {
  printf 'a matching rerun did not deduplicate: %s\n' "$output" >&2
  exit 1
}
[[ "$output" != *'refused'* ]] || {
  printf 'a matching rerun was refused: %s\n' "$output" >&2
  exit 1
}
# The description and the title are never rewritten, so nothing stored can be lost.
if grep -Eq '^update .*--description' "$TEST_ROOT/td.log"; then
  printf 'a dedup update rewrote the stored description\n' >&2
  exit 1
fi
if grep -Eq '^update .*--title' "$TEST_ROOT/td.log"; then
  printf 'a dedup update rewrote the stored title\n' >&2
  exit 1
fi
# Provenance stays current through a comment instead.
grep -Fq 'Originating fleet task: fleet-later' "$TEST_ROOT/td.log" || {
  printf 'a dedup update did not record the current occurrence\n' >&2
  exit 1
}
grep -Fq -- '--priority P1' "$TEST_ROOT/td.log"

# Any divergence refuses that one finding and leaves the card completely untouched.
assert_refused() {
  local label="$1" stored="$2"
  TD_LIST_RESULT="$(existing_card "$stored")" run_router "$TEST_ROOT/one.json"
  [[ "$output" == *'td td-revised refused'* ]] || {
    printf 'a diverged stored body was not refused (%s): %s\n' "$label" "$output" >&2
    exit 1
  }
  if grep -Eq '^(update|reopen|defer) td-revised' "$TEST_ROOT/td.log"; then
    printf 'a refused finding still mutated its card (%s)\n' "$label" >&2
    exit 1
  fi
  [[ "$output" == *'std-1'* && "$output" == *'standards'* ]] || {
    printf 'a refusal did not name the finding and axis (%s): %s\n' "$label" "$output" >&2
    exit 1
  }
  [[ "$output" == *'Reconcile td td-revised by hand'* ]] || {
    printf 'a refusal did not name the supported next action (%s): %s\n' "$label" "$output" >&2
    exit 1
  }
}

read -r -d '' diverged_digest_body <<DIVERGED || true
Independent review finding.

Review axis: standards
Review source: code-review
Evidence: a completely different finding that a human recorded here

Deduplication key: $stored_marker
Finding content digest: 00000000000000000000000000000000
DIVERGED
assert_refused 'different finding' "$diverged_digest_body"

read -r -d '' digestless_body <<DIGESTLESS || true
Independent readiness review finding.

Some hand-written prose that predates content digests entirely, of exactly the
shape td-36da4d and td-0fc5bf carry today.

Deduplication key: $stored_marker
DIGESTLESS
assert_refused 'no digest at all' "$digestless_body"

read -r -d '' edited_digest_body <<EDITED || true
Independent review finding.

Deduplication key: $stored_marker
Finding content digest: $std1_digest  <-- verified stale by lars
EDITED
assert_refused 'hand-edited digest line' "$edited_digest_body"

# A refusal must not abort the run: the rest of the batch still routes.
diverged_body="$diverged_digest_body"
TD_LIST_RESULT="$(existing_card "$diverged_body")" run_router "$TEST_ROOT/findings.json"
[[ "$output" == *'td td-revised refused'* ]] || {
  printf 'the batch case was not refused: %s\n' "$output" >&2
  exit 1
}
grep -Fq 'Long function' "$TEST_ROOT/td.log" || {
  printf 'a refusal aborted the remaining findings in the batch\n' >&2
  exit 1
}

# When EVERY finding is refused the axis recorded no evidence at all, which is a
# routing failure rather than a silent success.
TD_LIST_RESULT="$(existing_card "$diverged_body")" run_router "$TEST_ROOT/one.json"
[[ "$status" -eq 2 ]] || { printf 'an all-refused route reported success: %s\n' "$output" >&2; exit 1; }
[[ "$(cat "$WORKTREE/.sergeant-status")" == 'blocked' ]] || {
  printf 'an all-refused route left the worker unblocked\n' >&2
  exit 1
}
grep -Fq 'every finding was refused' "$WORKTREE/.sergeant-message" || {
  printf 'an all-refused route did not publish why\n' >&2
  exit 1
}

# A hand-edited title on an otherwise matching card is never overwritten, because
# the router does not write titles on the dedup path at all. td-36da4d and
# td-0fc5bf carry their summary only in the title.
TD_LIST_RESULT="$(existing_card "$matching_body" open 'review: the only copy of this summary lives in the title')" \
  run_router "$TEST_ROOT/one.json"
if grep -Eq '^update .*--title' "$TEST_ROOT/td.log"; then
  printf 'a dedup update overwrote a hand-edited title\n' >&2
  exit 1
fi

# A closed card matching the finding is reopened and reported, not abandoned.
TD_LIST_RESULT="$(existing_card "$matching_body" closed)" run_router "$TEST_ROOT/one.json"
grep -Fq 'reopen td-revised' "$TEST_ROOT/td.log"
[[ "$output" == *'reopened'* ]] || {
  printf 'a reopen was not reported: %s\n' "$output" >&2
  exit 1
}
# A closed card that has DIVERGED is refused, so it is not reopened either.
TD_LIST_RESULT="$(existing_card "$diverged_body" closed)" run_router "$TEST_ROOT/one.json"
if grep -Fq 'reopen td-revised' "$TEST_ROOT/td.log"; then
  printf 'a diverged closed card was reopened instead of refused\n' >&2
  exit 1
fi

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
