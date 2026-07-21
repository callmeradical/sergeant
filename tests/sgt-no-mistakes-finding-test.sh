#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

REPO="$TEST_ROOT/app"
mkdir -p "$TEST_ROOT/config" "$TEST_ROOT/fake-bin" "$REPO"

cat > "$TEST_ROOT/config/test.yaml" <<EOF
name: test
repos:
  - name: app
    path: $REPO
EOF

git -C "$REPO" init -q

cat > "$TEST_ROOT/fake-bin/td" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "$TD_LOG"

case "$1" in
  list)
    printf '%s\n' "${TD_LIST_RESULT:-[]}"
    ;;
  create)
    printf '{"id":"td-created"}\n'
    ;;
  defer)
    printf '{"id":"%s","status":"open"}\n' "$2"
    ;;
  reopen)
    printf '{"id":"%s","status":"open"}\n' "$2"
    ;;
  update)
    printf '{"id":"%s"}\n' "$2"
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/td"

run_router() {
  : > "$TEST_ROOT/td.log"
  set +e
  output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
    TD_LOG="$TEST_ROOT/td.log" \
    TD_LIST_RESULT="${TD_LIST_RESULT:-[]}" \
    SERGEANT_CONFIG="$TEST_ROOT/config" \
    "$ROOT_DIR/bin/sgt-no-mistakes-finding" test app \
      --run-id run-42 \
      --head-sha abc123 \
      --finding-id review-7 \
      --severity warning \
      --kind review \
      --file lib/example.sh \
      --line 19 \
      --description "Handle the deferred cleanup" \
      --intent "Ship safely without unrelated branch mutations" \
      "$@" 2>&1)"
  status=$?
  set -e
}

assert_log_contains() {
  grep -Fq -- "$1" "$TEST_ROOT/td.log" || {
    printf 'missing td invocation fragment: %s\nlog:\n' "$1" >&2
    cat "$TEST_ROOT/td.log" >&2
    exit 1
  }
}

run_router --disposition td
[[ "$status" -eq 0 && "$output" == *"td-created"* ]] || {
  printf 'warning debt was not routed to td: %s\n' "$output" >&2
  exit 1
}
assert_log_contains "create"
assert_log_contains "--priority P2"
assert_log_contains "--labels no-mistakes,finding"
assert_log_contains "Run ID: run-42"
assert_log_contains "Head SHA: abc123"
assert_log_contains "Finding ID: review-7"
assert_log_contains "Severity: warning"
assert_log_contains "Location: lib/example.sh:19"
assert_log_contains "Description: Handle the deferred cleanup"
assert_log_contains "Originating intent: Ship safely without unrelated branch mutations"
assert_log_contains "no-mistakes-finding:app:review-7"

run_router --severity info --finding-id doc-3 --kind document --disposition td
[[ "$status" -eq 0 ]] || { printf 'informational debt failed: %s\n' "$output" >&2; exit 1; }
assert_log_contains "--priority P3"

TD_LIST_RESULT='[{"id":"td-unrelated","description":"mentions review-7 only"},{"id":"td-existing","description":"Deduplication key: no-mistakes-finding:app:review-7"}]' \
  run_router --run-id run-43 --head-sha def456 \
    --file lib/revised.sh --line 27 \
    --description "Keep the latest cleanup context" \
    --intent "Retain rerun evidence without branch mutations" \
    --disposition td
[[ "$status" -eq 0 && "$output" == *"td-existing"* ]] || {
  printf 'existing debt card was not updated: %s\n' "$output" >&2
  exit 1
}
assert_log_contains "update td-existing"
assert_log_contains "Run ID: run-43"
assert_log_contains "Head SHA: def456"
assert_log_contains "Location: lib/revised.sh:27"
assert_log_contains "Description: Keep the latest cleanup context"
assert_log_contains "Originating intent: Retain rerun evidence without branch mutations"
if grep -Fq "create" "$TEST_ROOT/td.log"; then
  printf 'deduplicated finding created a second card\n' >&2
  exit 1
fi

TD_LIST_RESULT='[{"id":"td-review","status":"in_review","description":"Deduplication key: no-mistakes-finding:app:review-7"}]' \
  run_router --run-id run-44 --head-sha fed654 \
    --description "Resurface review debt on rerun" \
    --intent "Keep one visible debt card per finding" \
    --disposition td
[[ "$status" -eq 0 && "$output" == *"td-review"* ]] || {
  printf 'in-review debt card was not updated: %s\n' "$output" >&2
  exit 1
}
assert_log_contains "update td-review --status open"
assert_log_contains "update td-review --priority P2"
if grep -Fq "create" "$TEST_ROOT/td.log"; then
  printf 'in-review deduplicated finding created a second card\n' >&2
  exit 1
fi

TD_LIST_RESULT='[{"id":"td-closed","status":"closed","description":"Deduplication key: no-mistakes-finding:app:review-7"}]' \
  run_router --run-id run-45 --head-sha cba321 \
    --description "Reopen closed debt on rerun" \
    --intent "Keep one visible debt card per finding" \
    --disposition td
[[ "$status" -eq 0 && "$output" == *"td-closed"* ]] || {
  printf 'closed debt card was not updated: %s\n' "$output" >&2
  exit 1
}
assert_log_contains "reopen td-closed"
assert_log_contains "update td-closed"
if grep -Fq "create" "$TEST_ROOT/td.log"; then
  printf 'closed deduplicated finding created a second card\n' >&2
  exit 1
fi

TD_LIST_RESULT='[{"id":"td-deferred","status":"open","defer_until":"2026-07-22","description":"Deduplication key: no-mistakes-finding:app:review-7"}]' \
  run_router --run-id run-46 --head-sha abc999 \
    --description "Resurface deferred debt on rerun" \
    --intent "Keep deferred reruns actionable" \
    --disposition td
[[ "$status" -eq 0 && "$output" == *"td-deferred"* ]] || {
  printf 'deferred debt card was not updated: %s\n' "$output" >&2
  exit 1
}
assert_log_contains "defer td-deferred --clear"
assert_log_contains "update td-deferred --priority P2"
if grep -Fq "create" "$TEST_ROOT/td.log"; then
  printf 'deferred deduplicated finding created a second card\n' >&2
  exit 1
fi

TD_LIST_RESULT='{"oops":' run_router --disposition td
[[ "$status" -ne 0 && "$output" == *"td list returned invalid JSON"* ]] || {
  printf 'invalid td list JSON did not fail closed: %s\n' "$output" >&2
  exit 1
}
assert_log_contains "list --all --search no-mistakes-finding:app:review-7 --json --work-dir $REPO"
if grep -Fq "create" "$TEST_ROOT/td.log" || grep -Fq "update" "$TEST_ROOT/td.log" || grep -Fq "reopen" "$TEST_ROOT/td.log" || grep -Fq "defer" "$TEST_ROOT/td.log"; then
  printf 'invalid td list JSON should not mutate td state\n' >&2
  exit 1
fi

run_router --severity error --kind security --disposition td
[[ "$status" -ne 0 && "$output" == *"must gate"* ]] || {
  printf 'blocking finding was incorrectly deferred: %s\n' "$output" >&2
  exit 1
}
[[ ! -s "$TEST_ROOT/td.log" ]] || { printf 'blocking finding touched td\n' >&2; exit 1; }

run_router --kind correctness --disposition gate
[[ "$status" -ne 0 && "$output" == *"gate"* ]] || {
  printf 'gate disposition did not stop the caller: %s\n' "$output" >&2
  exit 1
}
[[ ! -s "$TEST_ROOT/td.log" ]] || { printf 'gate disposition touched td\n' >&2; exit 1; }

run_router --kind cosmetic --disposition td
[[ "$status" -eq 0 && "$output" == *"ignore"* ]] || {
  printf 'cosmetic noise was not ignored: %s\n' "$output" >&2
  exit 1
}
[[ ! -s "$TEST_ROOT/td.log" ]] || { printf 'cosmetic finding touched td\n' >&2; exit 1; }

run_router --disposition ask-user
[[ "$status" -ne 0 && "$output" == *"ask-user"* ]] || {
  printf 'ask-user finding did not escalate: %s\n' "$output" >&2
  exit 1
}
[[ ! -s "$TEST_ROOT/td.log" ]] || { printf 'ask-user finding touched td\n' >&2; exit 1; }

printf 'sgt-no-mistakes-finding: ok\n'
