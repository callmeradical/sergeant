#!/usr/bin/env bash

set -euo pipefail
export TMUX=fixture TMUX_PANE=%11

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/config/callbacks" "$TEST_ROOT/fleet" "$TEST_ROOT/fake-bin" "$TEST_ROOT/repo"
ln -s "$ROOT_DIR/bin/sgt-review-findings" "$TEST_ROOT/fake-bin/sgt-review-findings"
chmod 700 "$TEST_ROOT/config/callbacks" "$TEST_ROOT/fleet"
cat > "$TEST_ROOT/config/callbacks/hermes-discord" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod 700 "$TEST_ROOT/config/callbacks/hermes-discord"

cat > "$TEST_ROOT/config/test.yaml" <<EOF
name: test
repos:
  - name: app
    path: $TEST_ROOT/repo
EOF
cat > "$TEST_ROOT/fake-bin/tmux" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "display-message" ]] || printf '%s\n' "$*" >> "$TMUX_LOG"
case "$1" in
  has-session) exit 0 ;;
  display-message)
    if [[ "${AUTO_DELIVER:-1}" == 1 ]]; then
    for repo_state in "$SERGEANT_FLEET"/*/*; do
      [[ -d "$repo_state" ]] || continue
      [[ -f "$repo_state/notification_id" && -f "$repo_state/worktree" ]] || continue
      nonce="$(cat "$repo_state/notification_target" 2>/dev/null || true)"
      notification_id="$(cat "$repo_state/notification_id" 2>/dev/null || true)"
      [[ "$nonce" =~ ^[a-f0-9]{32}$ && -n "$notification_id" ]] || continue
      target_dir="$repo_state/notifications/$notification_id/targets/$nonce"
      token="$notification_id|$nonce"
      printf '%s\n' "$token" > "$target_dir/accepted"
      printf '%s\n' "$token" > "$target_dir/delivered"
    done
    fi
    if [[ "$*" == *'-t %11'* ]]; then
      printf '0|%%11|1111|111111|coordinator-command\n'
    else
      printf '0|%%42|4242|123456|fixture-worker-command\n'
    fi
    ;;
  new-window)
    [[ "${FAIL_WINDOW:-0}" == 0 ]] || exit 7
    if [[ "${AUTO_DELIVER:-1}" == 1 ]]; then
      for repo_state in "$SERGEANT_FLEET"/*/*; do
        [[ -d "$repo_state" ]] || continue
        [[ -f "$repo_state/notification_id" && -f "$repo_state/worktree" ]] || continue
        notification_id="$(cat "$repo_state/notification_id")"
        worktree="$(cat "$repo_state/worktree")"
        printf '%s|0|%%42|4242|123456|fixture-worker-command\n' "$notification_id" \
          > "$worktree/.sergeant-notification-ack"
        printf '%s|0|%%42|4242|123456|fixture-worker-command\n' "$notification_id" \
          > "$worktree/.sergeant-notification-accept"
        printf '0|%%42|4242|123456|fixture-worker-command\n' \
          > "$repo_state/notification_delivered_pane_identity"
        printf '%s\n' "$notification_id" > "$repo_state/notification_delivered"
      done
    fi
    printf '%%42\n'
    ;;
  send-keys)
    [[ "${FAIL_SEND:-0}" == 0 ]] || exit 8
    ;;
  kill-pane) ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/tmux"
cat > "$TEST_ROOT/fake-bin/td" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

printf '%s\n' "$*" >> "${TD_LOG:-/dev/null}"
if [[ "${1:-}" == "--version" ]]; then
  printf 'td version v0.1.0\n'
  exit 0
fi
if [[ "${1:-}" == "create" && "${2:-}" == "--help" ]]; then
  printf '%s\n' '--description --json --work-dir'
  exit 0
fi

args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-dir|-w)
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
for agent in opencode goose claude; do
  cat > "$TEST_ROOT/fake-bin/$agent" <<'EOF'
#!/usr/bin/env bash
if [[ "$(basename "$0")" == "goose" && "${FAIL_GOOSE_CAPABILITY:-0}" == "1" ]]; then
  exit 9
fi
exit 0
EOF
  chmod +x "$TEST_ROOT/fake-bin/$agent"
done
git -C "$TEST_ROOT/repo" init -q
git -C "$TEST_ROOT/repo" config user.name Test
git -C "$TEST_ROOT/repo" config user.email test@example.invalid
touch "$TEST_ROOT/repo/README.md"
git -C "$TEST_ROOT/repo" add README.md
git -C "$TEST_ROOT/repo" commit -qm fixture
git -C "$TEST_ROOT/repo" remote add origin git@github.com:org/test.git

REAL_DD="$(command -v dd)"
cat > "$TEST_ROOT/fake-bin/dd" <<EOF
#!/usr/bin/env bash
if [[ "\${FIXED_TASK_RANDOM:-}" == 1 && " \$* " == *' bs=32 '* ]]; then
  exec "$REAL_DD" if=/dev/zero bs=32 count=1
fi
exec "$REAL_DD" "\$@"
EOF
chmod +x "$TEST_ROOT/fake-bin/dd"

# A pre-existing torn marker at the exact prospective task ID is rejected
# before dispatch creates its task brief, worktree, or any additional fleet
# state. The fixed random source makes this public CLI boundary deterministic.
torn_dispatch_state="$TEST_ROOT/fleet/torn-dispatch-000000/app"
mkdir -p "$torn_dispatch_state"
printf 'prior-current-marker\n' > "$torn_dispatch_state/worker_process_marker"
chmod 600 "$torn_dispatch_state/worker_process_marker"
cp "$torn_dispatch_state/worker_process_marker" "$TEST_ROOT/torn-dispatch.before"
cp -a "$TEST_ROOT/fleet" "$TEST_ROOT/torn-dispatch-fleet.before"
set +e
torn_dispatch_output="$(FIXED_TASK_RANDOM=1 PATH="$TEST_ROOT/fake-bin:$PATH" \
  TD_LOG="$TEST_ROOT/torn-dispatch-td.log" \
  TMUX_LOG="$TEST_ROOT/torn-dispatch-tmux.log" SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Torn dispatch' --repos app \
    --managed-coordinator-pane 2>&1)"
torn_dispatch_status=$?
set -e
[[ "$torn_dispatch_status" -ne 0 && \
  "$torn_dispatch_output" == *'worker process marker evidence is torn'* ]]
cmp "$TEST_ROOT/torn-dispatch.before" "$torn_dispatch_state/worker_process_marker"
[[ ! -e "$TEST_ROOT/fleet/torn-dispatch-000000/brief.md" && \
  ! -e "$torn_dispatch_state/worktree" && \
  ! -e "$TEST_ROOT/torn-dispatch-tmux.log" ]]
! grep -q '^create ' "$TEST_ROOT/torn-dispatch-td.log" 2>/dev/null
diff -r "$TEST_ROOT/torn-dispatch-fleet.before" "$TEST_ROOT/fleet"
[[ "$(find "$torn_dispatch_state" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" == 1 ]]
rm -rf "$TEST_ROOT/fleet/torn-dispatch-000000"

validation_torn_state="$TEST_ROOT/fleet/torn-dispatch-000000/app/validation-process"
mkdir -p "$validation_torn_state"
printf 'prior-validation-marker\n' > "$validation_torn_state/worker_process_marker"
chmod 600 "$validation_torn_state/worker_process_marker"
cp -a "$TEST_ROOT/fleet" "$TEST_ROOT/validation-torn-fleet.before"
set +e
validation_torn_output="$(FIXED_TASK_RANDOM=1 PATH="$TEST_ROOT/fake-bin:$PATH" \
  TD_LOG="$TEST_ROOT/validation-torn-dispatch-td.log" \
  TMUX_LOG="$TEST_ROOT/validation-torn-dispatch-tmux.log" \
  SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
  SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Torn dispatch' --repos app \
    --managed-coordinator-pane 2>&1)"
validation_torn_status=$?
set -e
[[ "$validation_torn_status" -ne 0 && \
  "$validation_torn_output" == *'validation process marker evidence is torn'* ]]
[[ "$(cat "$validation_torn_state/worker_process_marker")" == prior-validation-marker ]]
! grep -q '^create ' "$TEST_ROOT/validation-torn-dispatch-td.log" 2>/dev/null
[[ ! -e "$TEST_ROOT/validation-torn-dispatch-tmux.log" ]]
diff -r "$TEST_ROOT/validation-torn-fleet.before" "$TEST_ROOT/fleet"
rm -rf "$TEST_ROOT/fleet/torn-dispatch-000000"

interrupted_state="$TEST_ROOT/fleet/interrupted-task/app"
mkdir -p "$interrupted_state"
printf 'dispatched\n' > "$interrupted_state/status"
printf '1\n' > "$interrupted_state/dispatch_started"

PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/success.log" \
SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Supervise worker' --repos app \
  --origin-profile hermes-discord --correlation-id req-worker-001 >/dev/null
[[ "$(cat "$interrupted_state/status")" == \
  'failed: dispatch incomplete: no worktree or owned live pane' ]]
rm -rf "$(dirname "$interrupted_state")"
repo_state="$(printf '%s\n' "$TEST_ROOT"/fleet/supervise-worker-*/app)"
task_id="$(basename "$(dirname "$repo_state")")"
python3 - "$TEST_ROOT/fleet/$task_id/.callbacks/origin.json" <<'PY'
import json
from pathlib import Path
import sys

assert json.loads(Path(sys.argv[1]).read_text(encoding="utf-8")) == {
    "version": "sergeant.callback-origin/v1",
    "profile": "hermes-discord",
    "correlation_id": "req-worker-001",
}
PY
[[ "$(cat "$repo_state/pane")" == "%42" ]]
[[ "$(cat "$repo_state/pane_identity")" == '0|%42|4242|123456|fixture-worker-command' ]]
[[ "$(cat "$repo_state/agent")" == "${SERGEANT_AGENT:-opencode}" ]]
[[ "$(cat "$repo_state/stage")" == "implementation" ]]
[[ "$(cat "$repo_state/dispatch_started")" =~ ^[0-9]+$ ]]
[[ "$(cat "$repo_state/window_name")" == "implementation-app-$task_id" ]]
[[ "$(cat "$repo_state/worker_process_marker")" == *'|198|'* ]]
[[ "$(stat -c %a "$repo_state/worker_process_marker")" == 600 ]]
[[ ! -e "$repo_state/initial_message" ]]
[[ -s "$repo_state/tmux_session" && -s "$repo_state/window_name" ]]
[[ -s "$repo_state/worktree_git_pointer" && -s "$repo_state/worktree_git_dir" ]]
[[ -s "$repo_state/notification_id" ]]
[[ "$(cat "$repo_state/notification_delivered")" == "$(cat "$repo_state/notification_id")" ]]
grep -Fq "$ROOT_DIR/bin/sgt-interactive-worker" "$TEST_ROOT/success.log"
if grep -Fq "$ROOT_DIR/bin/sgt-worker " "$TEST_ROOT/success.log" || \
  grep -Fq 'run --auto' "$TEST_ROOT/success.log" || \
  grep -Fq -- '--prompt' "$TEST_ROOT/success.log"; then
  printf 'dispatch used a prohibited non-interactive worker mode\n' >&2
  exit 1
fi
new_window_line="$(grep '^new-window ' "$TEST_ROOT/success.log")"
[[ "$new_window_line" != *'Read the .sergeant-brief.md file and execute the mission.'* ]]
brief="$(cat "$repo_state/worktree")/.sergeant-brief.md"
notification="$(cat "$repo_state/worktree")/.sergeant-notification"
grep -Fq 'kind=initial' "$notification"
grep -Fq 'instruction=Read the .sergeant-brief.md file and execute the mission.' "$notification"
grep -Fq 'persistent interactive agent session' "$brief"
grep -Fq 'Non-interactive agent modes are prohibited' "$brief"
grep -Fq 'orphaned' "$brief"
grep -Fq 'sgt-respond' "$brief"
grep -Fq 'requires both .sergeant-status=done and a non-empty .sergeant-result' "$brief"

cat > "$TEST_ROOT/fake-bin/treehouse" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == return ]]; then
  printf '%s\n' "$*" > "${TREEHOUSE_RETURN_LOG:?}"
  exit 0
fi
if [[ "$1" != get || "$2" != --lease || "$3" != --lease-holder || \
  -z "$4" || "$5" != --json ]]; then
  printf 'unexpected treehouse allocation argv: %s\n' "$*" >&2
  exit 64
fi
printf '%s\n' "$*" > "$TREEHOUSE_GET_LOG"
case "${TREEHOUSE_OUTPUT_MODE:-valid}" in
  definite_failure) exit 7 ;;
  malformed) printf '{not-json\n'; exit 0 ;;
  duplicate)
    printf '{"path":"%s","lease_id":"one","lease_id":"two","lease_holder":"%s"}\n' \
      "$TREEHOUSE_TEST_PATH" "$4"
    exit 0
    ;;
  nul)
    printf '{"path":"%s","lease_id":"lease\\u0000bad","lease_holder":"%s"}\n' \
      "$TREEHOUSE_TEST_PATH" "$4"
    exit 0
    ;;
  control)
    printf '{"path":"%s","lease_id":"lease\\u001fbad","lease_holder":"%s"}\n' \
      "$TREEHOUSE_TEST_PATH" "$4"
    exit 0
    ;;
  oversized)
    python3 -c 'import sys; sys.stdout.write("x" * 70000)'
    exit 0
    ;;
  simultaneous_overflow)
    python3 -c 'import sys; sys.stdout.write("o" * 70000); sys.stderr.write("e" * 70000)'
    exit 0
    ;;
  valid_nonzero)
    "$REAL_GIT" -C "$PWD" worktree add -q --detach "$TREEHOUSE_TEST_PATH"
    printf '{"path":"%s","lease_id":"lease-dispatch-1","lease_holder":"%s"}\n' \
      "$TREEHOUSE_TEST_PATH" "$4"
    exit 23
    ;;
  valid_signal)
    "$REAL_GIT" -C "$PWD" worktree add -q --detach "$TREEHOUSE_TEST_PATH"
    printf '{"path":"%s","lease_id":"lease-dispatch-1","lease_holder":"%s"}\n' \
      "$TREEHOUSE_TEST_PATH" "$4"
    kill -TERM "$$"
    ;;
  stderr_overflow)
    "$REAL_GIT" -C "$PWD" worktree add -q --detach "$TREEHOUSE_TEST_PATH"
    python3 -c 'import sys; sys.stderr.write("e" * 70000)'
    printf '{"path":"%s","lease_id":"lease-dispatch-1","lease_holder":"%s"}\n' \
      "$TREEHOUSE_TEST_PATH" "$4"
    exit 0
    ;;
  inherit_stdout|inherit_stderr|inherit_both)
    "$REAL_GIT" -C "$PWD" worktree add -q --detach "$TREEHOUSE_TEST_PATH"
    printf '{"path":"%s","lease_id":"lease-dispatch-1","lease_holder":"%s"}\n' \
      "$TREEHOUSE_TEST_PATH" "$4"
    case "$TREEHOUSE_OUTPUT_MODE" in
      inherit_stdout) nohup setsid sleep 30 2>/dev/null & ;;
      inherit_stderr) nohup setsid sleep 30 >/dev/null & ;;
      inherit_both) nohup setsid sleep 30 & ;;
    esac
    printf '%s\n' "$!" > "$TREEHOUSE_GRANDCHILD_LOG"
    exit 0
    ;;
  symlink)
    "$REAL_GIT" -C "$PWD" worktree add -q --detach "$TREEHOUSE_TEST_PATH-target"
    ln -s "$TREEHOUSE_TEST_PATH-target" "$TREEHOUSE_TEST_PATH"
    printf '{"path":"%s","lease_id":"lease-dispatch-1","lease_holder":"%s"}\n' \
      "$TREEHOUSE_TEST_PATH" "$4"
    exit 0
    ;;
esac
if [[ ! -d "$TREEHOUSE_TEST_PATH" ]]; then
  if [[ "${TREEHOUSE_BAD_CHECKOUT:-0}" == 1 ]]; then
    mkdir -p "$TREEHOUSE_TEST_PATH"
  else
    "$REAL_GIT" -C "$PWD" worktree add -q --detach "$TREEHOUSE_TEST_PATH"
  fi
fi
printf '{"path":"%s","lease_id":"lease-dispatch-1","lease_holder":"%s","leased_at":"2026-08-11T00:00:00Z"}\n' \
  "$TREEHOUSE_TEST_PATH" "$4"
EOF
chmod +x "$TEST_ROOT/fake-bin/treehouse"
touch "$TEST_ROOT/repo/treehouse.toml"
REAL_GIT="$(command -v git)" PATH="$TEST_ROOT/fake-bin:$PATH" \
  TREEHOUSE_TEST_PATH="$TEST_ROOT/treehouse-checkout" \
  TREEHOUSE_GET_LOG="$TEST_ROOT/treehouse-get.log" \
  TREEHOUSE_RETURN_LOG="$TEST_ROOT/treehouse-return.log" \
  TMUX_LOG="$TEST_ROOT/treehouse-dispatch.log" \
  SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
  SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Treehouse identity worker' --repos app >/dev/null
treehouse_state="$(dirname "$(find "$TEST_ROOT/fleet" -name wt_lease_id -print -quit)")"
treehouse_task_id="$(basename "$(dirname "$treehouse_state")")"
[[ "$(cat "$treehouse_state/wt_type")" == treehouse ]]
[[ "$(cat "$treehouse_state/wt_holder")" == "sgt-$treehouse_task_id-app" ]]
[[ "$(cat "$treehouse_state/wt_lease_id")" == lease-dispatch-1 ]]
[[ "$(cat "$treehouse_state/worktree")" == "$TEST_ROOT/treehouse-checkout" ]]
[[ -s "$treehouse_state/treehouse-acquisition.raw" ]]
python3 - "$treehouse_state/treehouse-acquisition.json" "$TEST_ROOT/treehouse-checkout" \
  "sgt-$treehouse_task_id-app" "$TEST_ROOT/repo" <<'PY'
import json, sys
record = json.load(open(sys.argv[1], encoding="utf-8"))
assert record["version"] == 1 and record["repo"] == sys.argv[4]
assert record["path"] == record["path_canonical"] == sys.argv[2]
assert record["path_is_canonical"] is True and record["identity_verified"] is True
assert record["lease_id"] == "lease-dispatch-1"
assert record["lease_holder"] == sys.argv[3]
assert all(isinstance(record[key], int) for key in
           ("checkout_dev", "checkout_ino", "git_dir_dev", "git_dir_ino"))
assert isinstance(record["git_dir"], str) and record["git_dir"]
PY
[[ "$(cat "$TEST_ROOT/treehouse-get.log")" == \
  "get --lease --lease-holder sgt-$treehouse_task_id-app --json" ]]
rm "$TEST_ROOT/repo/treehouse.toml"

touch "$TEST_ROOT/repo/treehouse.toml"
REAL_GIT="$(command -v git)" PATH="$TEST_ROOT/fake-bin:$PATH" \
  TREEHOUSE_TEST_PATH="$TEST_ROOT/treehouse-definite-failure" \
  TREEHOUSE_GET_LOG="$TEST_ROOT/treehouse-definite-failure.log" \
  TREEHOUSE_RETURN_LOG="$TEST_ROOT/treehouse-definite-failure-return.log" \
  TREEHOUSE_OUTPUT_MODE=definite_failure \
  TMUX_LOG="$TEST_ROOT/treehouse-definite-failure-tmux.log" \
  SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
  SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test "Treehouse definite failure fallback" \
    --repos app >/dev/null
definite_state="$(dirname "$(find "$TEST_ROOT/fleet" \
  -path '*/app/treehouse-acquisition-receipt.json' -type f \
  -exec grep -l '"returncode":7' {} + | head -1)")"
[[ "$(cat "$definite_state/wt_type")" == git ]]
[[ -d "$(cat "$definite_state/worktree")" ]]
[[ ! -e "$definite_state/treehouse-acquisition.json" ]]
[[ -s "$TEST_ROOT/treehouse-definite-failure-tmux.log" ]]
rm "$TEST_ROOT/repo/treehouse.toml"
printf 'sgt-dispatch falls back after durable definite Treehouse failure: ok\n'

for bad_mode in malformed duplicate nul control oversized simultaneous_overflow; do
  touch "$TEST_ROOT/repo/treehouse.toml"
  set +e
  REAL_GIT="$(command -v git)" PATH="$TEST_ROOT/fake-bin:$PATH" \
    TREEHOUSE_TEST_PATH="$TEST_ROOT/treehouse-$bad_mode" \
    TREEHOUSE_GET_LOG="$TEST_ROOT/treehouse-$bad_mode.log" \
    TREEHOUSE_RETURN_LOG="$TEST_ROOT/treehouse-$bad_mode-return.log" \
    TREEHOUSE_OUTPUT_MODE="$bad_mode" TMUX_LOG="$TEST_ROOT/treehouse-$bad_mode-tmux.log" \
    SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
    SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-dispatch" test "Treehouse $bad_mode allocation" --repos app \
      >/dev/null 2>&1
  bad_status=$?
  set -e
  [[ "$bad_status" -ne 0 ]]
  bad_raw="$(find "$TEST_ROOT/fleet" -path '*/app/treehouse-acquisition.raw' \
    -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2-)"
  [[ -s "$bad_raw" ]]
  [[ "$(wc -c < "$bad_raw")" -le 65537 ]]
  [[ ! -e "$(dirname "$bad_raw")/treehouse-acquisition.json" ]]
  rm "$TEST_ROOT/repo/treehouse.toml"
done

for ambiguous_outcome in valid_nonzero valid_signal stderr_overflow \
  inherit_stdout inherit_stderr inherit_both; do
  touch "$TEST_ROOT/repo/treehouse.toml"
  set +e
  REAL_GIT="$(command -v git)" PATH="$TEST_ROOT/fake-bin:$PATH" \
    TREEHOUSE_TEST_PATH="$TEST_ROOT/treehouse-$ambiguous_outcome" \
    TREEHOUSE_GET_LOG="$TEST_ROOT/treehouse-$ambiguous_outcome.log" \
    TREEHOUSE_RETURN_LOG="$TEST_ROOT/treehouse-$ambiguous_outcome-return.log" \
    TREEHOUSE_GRANDCHILD_LOG="$TEST_ROOT/treehouse-$ambiguous_outcome-child.log" \
    TREEHOUSE_OUTPUT_MODE="$ambiguous_outcome" \
    TMUX_LOG="$TEST_ROOT/treehouse-$ambiguous_outcome-tmux.log" \
    SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
    SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-dispatch" test "Treehouse $ambiguous_outcome allocation" \
      --repos app >/dev/null 2>&1
  ambiguous_status=$?
  set -e
  [[ "$ambiguous_status" -ne 0 ]]
  ambiguous_record="$(find "$TEST_ROOT/fleet" \
    -path '*/app/treehouse-acquisition.json' -type f -exec grep -lF -- \
    "$TEST_ROOT/treehouse-$ambiguous_outcome" {} + | head -1)"
  [[ -s "$ambiguous_record" ]]
  ambiguous_holder="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["lease_holder"])' \
    "$ambiguous_record")"
  [[ "$(cat "$TEST_ROOT/treehouse-$ambiguous_outcome-return.log")" == \
    "return --force --if-lease-id lease-dispatch-1 --if-lease-holder $ambiguous_holder $TEST_ROOT/treehouse-$ambiguous_outcome" ]]
  if [[ "$ambiguous_outcome" == inherit_* ]]; then
    grandchild_pid="$(cat "$TEST_ROOT/treehouse-$ambiguous_outcome-child.log")"
    if ! kill -0 "$grandchild_pid" 2>/dev/null; then
      printf 'Treehouse helper unexpectedly signaled a reaped leader group: %s\n' \
        "$grandchild_pid" >&2
      exit 1
    fi
    python3 - "$(dirname "$ambiguous_record")/treehouse-acquisition-receipt.json" <<'PY'
import json, sys
attempt = json.load(open(sys.argv[1], encoding="utf-8"))["attempts"][-1]
assert attempt["pipe_timeout"] is True
PY
    kill "$grandchild_pid"
  fi
  rm "$TEST_ROOT/repo/treehouse.toml"
done

for acquisition_point in treehouse-raw-created treehouse-raw-published \
  treehouse-record-created treehouse-record-published; do
  touch "$TEST_ROOT/repo/treehouse.toml"
  set +e
  REAL_GIT="$(command -v git)" PATH="$TEST_ROOT/fake-bin:$PATH" \
    TREEHOUSE_TEST_PATH="$TEST_ROOT/$acquisition_point-checkout" \
    TREEHOUSE_GET_LOG="$TEST_ROOT/$acquisition_point.log" \
    TREEHOUSE_RETURN_LOG="$TEST_ROOT/$acquisition_point-return.log" \
    SGT_DISPATCH_FAIL_POINT="$acquisition_point" \
    TMUX_LOG="$TEST_ROOT/$acquisition_point-tmux.log" \
    SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
    SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-dispatch" test "Acquisition $acquisition_point" --repos app \
      >/dev/null 2>&1
  point_status=$?
  set -e
  [[ "$point_status" -ne 0 ]]
  case "$acquisition_point" in
    treehouse-raw-created)
      find "$TEST_ROOT/fleet" -path '*/app/treehouse-acquisition.raw.tmp.*' \
        -type f -size +0c -exec grep -lF -- \
        "$TEST_ROOT/$acquisition_point-checkout" {} + | grep -q .
      ;;
    treehouse-raw-published)
      find "$TEST_ROOT/fleet" -path '*/app/treehouse-acquisition.raw' \
        -type f -size +0c -exec grep -lF -- \
        "$TEST_ROOT/$acquisition_point-checkout" {} + | grep -q .
      ;;
    treehouse-record-published)
      find "$TEST_ROOT/fleet" -path '*/app/treehouse-acquisition.json' \
        -type f -size +0c -exec grep -lF -- \
        "$TEST_ROOT/$acquisition_point-checkout" {} + | grep -q .
      ;;
    treehouse-record-created)
      find "$TEST_ROOT/fleet" -path '*/app/treehouse-acquisition.json.tmp.*' \
        -type f -size +0c -exec grep -lF -- \
        "$TEST_ROOT/$acquisition_point-checkout" {} + | grep -q .
      ;;
  esac
  rm "$TEST_ROOT/repo/treehouse.toml"
done

touch "$TEST_ROOT/repo/treehouse.toml"
set +e
REAL_GIT="$(command -v git)" PATH="$TEST_ROOT/fake-bin:$PATH" \
  TREEHOUSE_TEST_PATH="$TEST_ROOT/treehouse-bad-checkout" TREEHOUSE_BAD_CHECKOUT=1 \
  TREEHOUSE_GET_LOG="$TEST_ROOT/treehouse-bad-checkout.log" \
  TREEHOUSE_RETURN_LOG="$TEST_ROOT/treehouse-bad-checkout-return.log" \
  TMUX_LOG="$TEST_ROOT/treehouse-bad-checkout-tmux.log" \
  SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
  SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Treehouse bad checkout' --repos app >/dev/null 2>&1
bad_checkout_status=$?
set -e
[[ "$bad_checkout_status" -ne 0 ]]
bad_checkout_record="$(find "$TEST_ROOT/fleet" \
  -path '*treehouse-bad-checkout-*/app/treehouse-acquisition.json' -print -quit)"
[[ -s "$bad_checkout_record" ]]
[[ -s "$(dirname "$bad_checkout_record")/treehouse-acquisition-return-receipt.json" ]]
bad_checkout_holder="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["lease_holder"])' \
  "$bad_checkout_record")"
[[ "$(cat "$TEST_ROOT/treehouse-bad-checkout-return.log")" == \
  "return --force --if-lease-id lease-dispatch-1 --if-lease-holder $bad_checkout_holder $TEST_ROOT/treehouse-bad-checkout" ]]
rm "$TEST_ROOT/repo/treehouse.toml"

touch "$TEST_ROOT/repo/treehouse.toml"
set +e
REAL_GIT="$(command -v git)" PATH="$TEST_ROOT/fake-bin:$PATH" \
  TREEHOUSE_TEST_PATH="$TEST_ROOT/treehouse-symlink" TREEHOUSE_OUTPUT_MODE=symlink \
  TREEHOUSE_GET_LOG="$TEST_ROOT/treehouse-symlink.log" \
  TREEHOUSE_RETURN_LOG="$TEST_ROOT/treehouse-symlink-return.log" \
  TMUX_LOG="$TEST_ROOT/treehouse-symlink-tmux.log" \
  SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
  SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Treehouse symlink allocation' --repos app \
    >/dev/null 2>&1
symlink_status=$?
set -e
[[ "$symlink_status" -ne 0 ]]
symlink_record="$(find "$TEST_ROOT/fleet" \
  -path '*treehouse-symlink-*/app/treehouse-acquisition.json' -print -quit)"
python3 - "$symlink_record" <<'PY'
import json, sys
record = json.load(open(sys.argv[1], encoding="utf-8"))
assert record["path_is_canonical"] is False
PY
symlink_holder="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["lease_holder"])' \
  "$symlink_record")"
[[ "$(cat "$TEST_ROOT/treehouse-symlink-return.log")" == \
  "return --force --if-lease-id lease-dispatch-1 --if-lease-holder $symlink_holder $TEST_ROOT/treehouse-symlink" ]]
rm "$TEST_ROOT/repo/treehouse.toml"

git -C "$TEST_ROOT/repo" worktree add -q --detach \
  "$TEST_ROOT/treehouse-gitdir-decoy"
gitdir_decoy_head="$(git -C "$TEST_ROOT/treehouse-gitdir-decoy" rev-parse HEAD)"
mkdir -p "$TEST_ROOT/gitdir-swap-hooks"
cat > "$TEST_ROOT/gitdir-swap-hooks/post-checkout" <<'EOF'
#!/usr/bin/env bash
matched=false
while IFS= read -r candidate; do
  if grep -Fq "\"path\":\"$TREEHOUSE_TEST_PATH\"" "$candidate" 2>/dev/null && \
    grep -Fq '"identity_verified":true' "$candidate" 2>/dev/null; then
    matched=true
    break
  fi
done < <(find "$SERGEANT_FLEET" -name treehouse-acquisition.json -type f)
[[ "$matched" == true ]] || exit 0
cp "$TREEHOUSE_GITDIR_DECOY/.git" "$TREEHOUSE_TEST_PATH/.git"
EOF
chmod +x "$TEST_ROOT/gitdir-swap-hooks/post-checkout"
touch "$TEST_ROOT/repo/treehouse.toml"
set +e
REAL_GIT="$(command -v git)" PATH="$TEST_ROOT/fake-bin:$PATH" \
  TREEHOUSE_TEST_PATH="$TEST_ROOT/treehouse-gitdir-checkout" \
  TREEHOUSE_GITDIR_DECOY="$TEST_ROOT/treehouse-gitdir-decoy" \
  TREEHOUSE_GET_LOG="$TEST_ROOT/treehouse-gitdir.log" \
  TREEHOUSE_RETURN_LOG="$TEST_ROOT/treehouse-gitdir-return.log" \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath \
  GIT_CONFIG_VALUE_0="$TEST_ROOT/gitdir-swap-hooks" \
  TMUX_LOG="$TEST_ROOT/treehouse-gitdir-tmux.log" \
  SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
  SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Treehouse gitdir swap' --repos app \
    >/dev/null 2>&1
gitdir_swap_status=$?
set -e
[[ "$gitdir_swap_status" -ne 0 ]]
[[ "$(git -C "$TEST_ROOT/treehouse-gitdir-decoy" rev-parse HEAD)" == \
  "$gitdir_decoy_head" ]]
gitdir_record="$(find "$TEST_ROOT/fleet" \
  -path '*treehouse-gitdir-swap-*/app/treehouse-acquisition.json' -print -quit)"
gitdir_holder="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["lease_holder"])' \
  "$gitdir_record")"
[[ "$(cat "$TEST_ROOT/treehouse-gitdir-return.log")" == \
  "return --force --if-lease-id lease-dispatch-1 --if-lease-holder $gitdir_holder $TEST_ROOT/treehouse-gitdir-checkout" ]]
# Keep this completed adversarial fixture available for inspection without
# letting the next independent dispatch reconcile its intentionally pane-less
# terminal record.
mv "$(dirname "$gitdir_record")" "$TEST_ROOT/treehouse-gitdir-state"
rm "$TEST_ROOT/repo/treehouse.toml"

git -C "$TEST_ROOT/repo" worktree add -q --detach \
  "$TEST_ROOT/treehouse-preopen-decoy"
preopen_decoy_head="$(git -C "$TEST_ROOT/treehouse-preopen-decoy" rev-parse HEAD)"
cat > "$TEST_ROOT/treehouse-preopen-hook" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mv "$1" "$1-original"
mv "$TREEHOUSE_SWAP_DECOY" "$1"
: > "$TREEHOUSE_SWAP_COMPLETE"
EOF
chmod +x "$TEST_ROOT/treehouse-preopen-hook"
touch "$TEST_ROOT/repo/treehouse.toml"
set +e
REAL_GIT="$(command -v git)" PATH="$TEST_ROOT/fake-bin:$PATH" \
  TREEHOUSE_TEST_PATH="$TEST_ROOT/treehouse-preopen-checkout" \
  TREEHOUSE_SWAP_DECOY="$TEST_ROOT/treehouse-preopen-decoy" \
  TREEHOUSE_SWAP_COMPLETE="$TEST_ROOT/treehouse-preopen-complete" \
  TREEHOUSE_GET_LOG="$TEST_ROOT/treehouse-preopen.log" \
  TREEHOUSE_RETURN_LOG="$TEST_ROOT/treehouse-preopen-return.log" \
  SGT_TEST_HOOKS=1 \
  SGT_TREEHOUSE_PREOPEN_HOOK="$TEST_ROOT/treehouse-preopen-hook" \
  SGT_TREEHOUSE_TEST_HOOK_ROOT="$TEST_ROOT" \
  TMUX_LOG="$TEST_ROOT/treehouse-preopen-tmux.log" \
  SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
  SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Treehouse preopen swap' --repos app \
    >/dev/null 2>&1
preopen_status=$?
set -e
[[ "$preopen_status" -ne 0 ]]
for _ in $(seq 1 100); do
  [[ -e "$TEST_ROOT/treehouse-preopen-complete" ]] && break
  sleep 0.01
done
[[ -e "$TEST_ROOT/treehouse-preopen-complete" ]]
[[ "$(git -C "$TEST_ROOT/treehouse-preopen-checkout" rev-parse HEAD)" == \
  "$preopen_decoy_head" ]]
[[ -z "$(git -C "$TEST_ROOT/treehouse-preopen-checkout" branch --list \
  'feat/treehouse-preopen-swap')" ]]
[[ "$(git -C "$TEST_ROOT/treehouse-preopen-checkout-original" rev-parse HEAD)" == \
  "$preopen_decoy_head" ]]
preopen_record="$(find "$TEST_ROOT/fleet" \
  -path '*treehouse-preopen-swap-*/app/treehouse-acquisition.json' -print -quit)"
preopen_holder="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["lease_holder"])' \
  "$preopen_record")"
[[ "$(cat "$TEST_ROOT/treehouse-preopen-return.log")" == \
  "return --force --if-lease-id lease-dispatch-1 --if-lease-holder $preopen_holder $TEST_ROOT/treehouse-preopen-checkout" ]]
mv "$(dirname "$preopen_record")" "$TEST_ROOT/treehouse-preopen-state"
rm "$TEST_ROOT/repo/treehouse.toml"

mkdir -p "$TEST_ROOT/swap-unrelated"
git -C "$TEST_ROOT/swap-unrelated" init -q
git -C "$TEST_ROOT/swap-unrelated" config user.name Test
git -C "$TEST_ROOT/swap-unrelated" config user.email test@example.invalid
printf 'unrelated\n' > "$TEST_ROOT/swap-unrelated/UNRELATED"
git -C "$TEST_ROOT/swap-unrelated" add UNRELATED
git -C "$TEST_ROOT/swap-unrelated" commit -qm unrelated
unrelated_head="$(git -C "$TEST_ROOT/swap-unrelated" rev-parse HEAD)"
mkdir -p "$TEST_ROOT/swap-hooks"
cat > "$TEST_ROOT/swap-hooks/post-checkout" <<'EOF'
#!/usr/bin/env bash
matched=false
while IFS= read -r candidate; do
  if grep -Fq "\"path\":\"$TREEHOUSE_TEST_PATH\"" "$candidate" 2>/dev/null && \
    grep -Fq '"identity_verified":true' "$candidate" 2>/dev/null; then
    matched=true
    break
  fi
done < <(find "$SERGEANT_FLEET" -name treehouse-acquisition.json -type f)
[[ "$matched" == true ]] || exit 0
mv "$TREEHOUSE_TEST_PATH" "$TREEHOUSE_TEST_PATH-original"
ln -s "$TREEHOUSE_SWAP_REPO" "$TREEHOUSE_TEST_PATH"
EOF
chmod +x "$TEST_ROOT/swap-hooks/post-checkout"
touch "$TEST_ROOT/repo/treehouse.toml"
set +e
REAL_GIT="$(command -v git)" PATH="$TEST_ROOT/fake-bin:$PATH" \
  TREEHOUSE_TEST_PATH="$TEST_ROOT/treehouse-swap-checkout" \
  TREEHOUSE_SWAP_REPO="$TEST_ROOT/swap-unrelated" \
  TREEHOUSE_GET_LOG="$TEST_ROOT/treehouse-swap.log" \
  TREEHOUSE_RETURN_LOG="$TEST_ROOT/treehouse-swap-return.log" \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath \
  GIT_CONFIG_VALUE_0="$TEST_ROOT/swap-hooks" \
  TMUX_LOG="$TEST_ROOT/treehouse-swap-tmux.log" \
  SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
  SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Treehouse checkout swap' --repos app \
    >/dev/null 2>&1
swap_status=$?
set -e
[[ "$swap_status" -ne 0 && -L "$TEST_ROOT/treehouse-swap-checkout" ]]
[[ "$(git -C "$TEST_ROOT/swap-unrelated" rev-parse HEAD)" == "$unrelated_head" ]]
[[ -z "$(git -C "$TEST_ROOT/swap-unrelated" branch --list \
  'feat/treehouse-checkout-swap')" ]]
swap_record="$(find "$TEST_ROOT/fleet" \
  -path '*treehouse-checkout-swap-*/app/treehouse-acquisition.json' -print -quit)"
swap_holder="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["lease_holder"])' \
  "$swap_record")"
[[ "$(cat "$TEST_ROOT/treehouse-swap-return.log")" == \
  "return --force --if-lease-id lease-dispatch-1 --if-lease-holder $swap_holder $TEST_ROOT/treehouse-swap-checkout" ]]
mv "$(dirname "$swap_record")" "$TEST_ROOT/treehouse-checkout-swap-state"
rm "$TEST_ROOT/repo/treehouse.toml"

for agent in goose claude; do
  PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/$agent.log" \
  SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-dispatch" test "Supervise $agent worker" --repos app \
      --agent "$agent" >/dev/null
  agent_state="$(printf '%s\n' "$TEST_ROOT"/fleet/supervise-$agent-worker-*/app)"
  [[ "$(cat "$agent_state/agent")" == "$agent" ]]
  grep -Fq "$ROOT_DIR/bin/sgt-interactive-worker" "$TEST_ROOT/$agent.log"
  if grep -Fq 'goose run' "$TEST_ROOT/$agent.log" || \
    grep -Fq -- '--print' "$TEST_ROOT/$agent.log"; then
    printf 'dispatch used a prohibited %s one-shot mode\n' "$agent" >&2
    exit 1
  fi
done

PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/stage.log" \
SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Review stage worker' --repos app \
    --agent goose --stage spec >/dev/null
stage_state="$(printf '%s\n' "$TEST_ROOT"/fleet/review-stage-worker-*/app)"
stage_task_id="$(basename "$(dirname "$stage_state")")"
[[ "$(cat "$stage_state/stage")" == "spec" ]]
[[ "$(cat "$stage_state/window_name")" == "spec-app-$stage_task_id" ]]
grep -Fq -- "-n spec-app-$stage_task_id" "$TEST_ROOT/stage.log"

before_count="$(find "$TEST_ROOT/fleet" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
set +e
output="$(PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/invalid-stage.log" \
  SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Invalid stage worker' --repos app \
    --stage 'spec/review' 2>&1)"
status=$?
set -e
after_count="$(find "$TEST_ROOT/fleet" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
[[ "$status" -ne 0 && "$output" == *"stage must be a lowercase slug"* ]]
[[ "$before_count" == "$after_count" ]]
[[ ! -e "$TEST_ROOT/invalid-stage.log" ]]

env -u SERGEANT_AGENT -u OPENCODE -u OPENCODE_PID \
  PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/claude-detected.log" \
  CLAUDE_CODE_SESSION_ID=claude-session SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Detect Claude worker' --repos app >/dev/null
detected_state="$(printf '%s\n' "$TEST_ROOT"/fleet/detect-claude-worker-*/app)"
[[ "$(cat "$detected_state/agent")" == "claude" ]]

before_count="$(find "$TEST_ROOT/fleet" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
set +e
output="$(PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/goose-capability.log" \
  FAIL_GOOSE_CAPABILITY=1 SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Missing Goose capability' --repos app \
    --agent goose 2>&1)"
status=$?
set -e
after_count="$(find "$TEST_ROOT/fleet" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
[[ "$status" -ne 0 && "$output" == *"does not support interactive sessions"* ]]
[[ "$before_count" == "$after_count" ]]
[[ ! -e "$TEST_ROOT/goose-capability.log" ]]

set +e
PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/failure.log" FAIL_WINDOW=1 \
SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Fail worker launch' --repos app >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]]
failed_state="$(printf '%s\n' "$TEST_ROOT"/fleet/fail-worker-launch-*/app)"
[[ "$(cat "$failed_state/status")" == "orphaned" ]]
grep -Fq 'tmux failed to launch worker supervisor' "$failed_state/diagnostic"

set +e
PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/readiness-timeout.log" AUTO_DELIVER=0 \
SGT_NOTIFICATION_ACK_TIMEOUT=0 SERGEANT_CONFIG="$TEST_ROOT/config" \
SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Timeout waiting for readiness' --repos app >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]]
timeout_state="$(printf '%s\n' "$TEST_ROOT"/fleet/timeout-waiting-for-*/app)"
[[ "$(cat "$timeout_state/status")" == "orphaned" ]]
grep -Fq 'interactive worker did not acknowledge its durable notification' "$timeout_state/diagnostic"
grep -Fq 'kill-pane -t %42' "$TEST_ROOT/readiness-timeout.log"
if grep -Fq 'send-keys' "$TEST_ROOT/readiness-timeout.log"; then
  printf 'dispatch sent input before worker readiness\n' >&2
  exit 1
fi

replacement_nonce="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
target_race_hook="printf '%s\\n' '$replacement_nonce' > \"\$repo_dir/notification_target\""
set +e
output="$(PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/target-race.log" \
  SGT_TEST_HOOKS=1 _SGT_POST_MV_HOOK="$target_race_hook" \
  SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
  SGT_WIKI_DISABLED=1 "$ROOT_DIR/bin/sgt-dispatch" test 'Dispatch target race' \
  --repos app 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 ]]
[[ "$output" == *'notification target race detected for app; worker orphaned'* ]]
target_race_state="$(printf '%s\n' "$TEST_ROOT"/fleet/dispatch-target-race-*/app)"
[[ "$(cat "$target_race_state/status")" == "orphaned" ]]
grep -Fq 'notification target creation race: concurrent dispatch detected' \
  "$target_race_state/diagnostic"
[[ "$(cat "$target_race_state/notification_target")" == "$replacement_nonce" ]]
[[ ! -e "$target_race_state/notification_target_pane_identity" ]]
target_race_target_count="$(find "$target_race_state/notifications" -mindepth 3 -maxdepth 3 \
  -type d 2>/dev/null | wc -l | tr -d ' ')"
[[ "$target_race_target_count" == "0" ]]
grep -Fq 'kill-pane -t %42' "$TEST_ROOT/target-race.log"

# Capability validation must abort before ANY durable side effect exists: no
# fleet directory, no intent file, no td task, and no worktree (td-db6323 /
# GH #175).  Asserting only the fleet count previously left the other three
# unproven.
before_count="$(find "$TEST_ROOT/fleet" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
before_worktrees="$(find "$(dirname "$TEST_ROOT/repo")" -maxdepth 1 -type d -name 'app-sgt-*' | \
  wc -l | tr -d ' ')"
before_intents="$(find "$TEST_ROOT" -name '.sergeant-intent.md' | wc -l | tr -d ' ')"
set +e
output="$(PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/unsupported.log" \
  TD_LOG="$TEST_ROOT/unsupported-td.log" \
  SERGEANT_AGENT=fake-agent SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Unsupported agent' --repos app 2>&1)"
status=$?
set -e
after_count="$(find "$TEST_ROOT/fleet" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
after_worktrees="$(find "$(dirname "$TEST_ROOT/repo")" -maxdepth 1 -type d -name 'app-sgt-*' | \
  wc -l | tr -d ' ')"
after_intents="$(find "$TEST_ROOT" -name '.sergeant-intent.md' | wc -l | tr -d ' ')"
[[ "$status" -ne 0 && "$output" == *"unsupported interactive agent"* ]]
[[ "$before_count" == "$after_count" ]]
[[ "$before_worktrees" == "$after_worktrees" ]]
[[ "$before_intents" == "$after_intents" ]]
[[ ! -e "$TEST_ROOT/unsupported.log" ]]
if [[ -e "$TEST_ROOT/unsupported-td.log" ]] && \
   grep -Eq '(^| )(create|start|log|handoff|review)( |$)' "$TEST_ROOT/unsupported-td.log"; then
  printf 'capability validation created td work before failing:\n%s\n' \
    "$(cat "$TEST_ROOT/unsupported-td.log")" >&2
  exit 1
fi

removed_flag="--""remote"
before_count="$(find "$TEST_ROOT/fleet" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
rm -f "$TEST_ROOT/removed-option-tmux.log"
set +e
output="$(PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/removed-option-tmux.log" \
  SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Removed option' --repos app "$removed_flag" 2>&1)"
status=$?
set -e
after_count="$(find "$TEST_ROOT/fleet" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
[[ "$status" -ne 0 ]]
[[ "$output" == *"Unknown option"* ]]
[[ "$before_count" == "$after_count" ]]
[[ ! -e "$TEST_ROOT/removed-option-tmux.log" ]]

# Initial dispatch and session resume share the exact repository launch
# transaction. Resume begins after dispatch published its marker but before the
# pane launch; it must consume dispatch's completion journal, not launch again.
race_state="$TEST_ROOT/fleet/race-public-000000/app"
FIXED_TASK_RANDOM=1 SGT_TEST_HOOKS=1 SGT_TEST_DISPATCH_LAUNCH_BARRIER=1 \
  PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/dispatch-resume-race.log" \
  TD_LOG="$TEST_ROOT/dispatch-resume-race-td.log" SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Race public' --repos app \
  >"$TEST_ROOT/dispatch-resume-dispatch.out" 2>&1 & dispatch_race_pid=$!
for _ in $(seq 1 500); do
  [[ -e "$race_state/dispatch-launch-ready" ]] && break
  sleep 0.01
done
[[ -e "$race_state/dispatch-launch-ready" ]]
PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/dispatch-resume-race.log" \
  SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
  SGT_WIKI_DISABLED=1 "$ROOT_DIR/bin/sgt-session-resume" \
  race-public-000000 app --force >"$TEST_ROOT/dispatch-resume-resume.out" 2>&1 & \
  resume_race_pid=$!
sleep 0.1
: > "$race_state/dispatch-launch-release"
wait "$dispatch_race_pid"
wait "$resume_race_pid"
[[ "$(grep -c '^new-window ' "$TEST_ROOT/dispatch-resume-race.log")" -eq 1 ]]
[[ "$(wc -l < "$race_state/worker_process_markers")" -eq 1 ]]
[[ "$(cat "$race_state/worker-launch.completed")" =~ ^[0-9a-f]+\|[0-9a-f]{64}$ ]]
grep -Fq 'verified peer worker-launch transaction completed' \
  "$TEST_ROOT/dispatch-resume-resume.out"

printf 'sgt-dispatch supervisor launch: ok\n'
