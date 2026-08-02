#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
fake_bin="$TEST_ROOT/bin"
mkdir -p "$fake_bin"

cat > "$fake_bin/date" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'|'*) printf '2026-08-01T00:00:00Z|2000\n' ;;
  *) exec "$REAL_DATE" "$@" ;;
esac
EOF
chmod +x "$fake_bin/date"
export REAL_DATE="$(command -v date)"

cat > "$fake_bin/stat" <<'EOF'
#!/usr/bin/env bash
last="${!#}"
if [[ -n "${SNAPSHOT_STATUS_MTIME:-}" && "$last" == "${SNAPSHOT_STATUS_PATH:-}" ]]; then
  if [[ "$1 ${2:-}" == '-c %Y' || "$1 ${2:-}" == '-f %m' ]]; then
    printf '%s\n' "$SNAPSHOT_STATUS_MTIME"
    exit 0
  fi
fi
exec "$REAL_STAT" "$@"
EOF
chmod +x "$fake_bin/stat"
export REAL_STAT="$(command -v stat)"

cat > "$fake_bin/find" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${SNAPSHOT_FIND_SEQUENCE:-}" && "$1" == "${SNAPSHOT_FIND_DIR:-}" ]]; then
  while IFS= read -r path; do
    printf '%s\0' "$path"
  done < "$SNAPSHOT_FIND_SEQUENCE"
  exit 0
fi
exec "$REAL_FIND" "$@"
EOF
chmod +x "$fake_bin/find"
export REAL_FIND="$(command -v find)"

cat > "$fake_bin/tmux" <<'EOF'
#!/usr/bin/env bash
[[ "${TMUX_FAIL:-0}" == "0" ]] || exit 1
format="${!#}"
if [[ "$format" == '#{pane_activity}' ]]; then
  [[ "${TMUX_ACTIVITY_FAIL:-0}" == "0" ]] || exit 1
  printf '%s\n' "${PANE_ACTIVITY:-0}"
  exit 0
fi
if [[ -n "${TMUX_MUTATE_STATUS:-}" && ! -e "${TMUX_MUTATE_MARKER:-}" ]]; then
  printf 'blocked\n' > "$TMUX_MUTATE_STATUS"
  : > "$TMUX_MUTATE_MARKER"
fi
if [[ -n "${TMUX_IDENTITY_AFTER:-}" ]]; then
  if [[ -e "${TMUX_IDENTITY_MARKER:-}" ]]; then
    printf '%s\n' "$TMUX_IDENTITY_AFTER"
  else
    : > "$TMUX_IDENTITY_MARKER"
    printf '%s\n' "$PANE_IDENTITY"
  fi
else
  printf '%s\n' "$PANE_IDENTITY"
fi
EOF
chmod +x "$fake_bin/tmux"

make_worker() {
  local fleet="$1" task="$2" repo_name="$3" status="$4" progress="$5"
  FIXTURE_REPO="$fleet/$task/$repo_name"
  FIXTURE_WORKTREE="$TEST_ROOT/worktree-$task-$repo_name"
  mkdir -p "$FIXTURE_REPO" "$FIXTURE_WORKTREE"
  printf '%s\n' "$status" > "$FIXTURE_REPO/status"
  printf '%s\n' "$FIXTURE_WORKTREE" > "$FIXTURE_REPO/worktree"
  printf '%s\n' "$status" > "$FIXTURE_WORKTREE/.sergeant-status"
  printf 'opencode\n' > "$FIXTURE_REPO/agent"
  printf '%%42\n' > "$FIXTURE_REPO/pane"
  printf '%s\n' "$progress" > "$FIXTURE_REPO/progress_ts"
  printf -v expected_command '%q %q %q %q' \
    "$ROOT/bin/sgt-interactive-worker" "$FIXTURE_REPO" "$FIXTURE_WORKTREE" opencode
  FIXTURE_IDENTITY="0|%42|4242|1000|$expected_command"
  printf '%s\n' "$FIXTURE_IDENTITY" > "$FIXTURE_REPO/pane_identity"
  chmod 600 "$FIXTURE_REPO/pane_identity"
}

assert_snapshot() {
  local expected_busy="$1" expected_basis="$2" snapshot="$3"
  EXPECTED_BUSY="$expected_busy" EXPECTED_BASIS="$expected_basis" SNAPSHOT="$snapshot" \
    python3 - <<'PY'
import datetime
import json
import os

snapshot = json.loads(os.environ["SNAPSHOT"])
assert snapshot["schema"] == "sergeant.watch-status/v1"
datetime.datetime.fromisoformat(snapshot["observed_at"].replace("Z", "+00:00"))
expected_busy = os.environ["EXPECTED_BUSY"]
assert snapshot["busy"] is (True if expected_busy == "true" else None)
assert snapshot["basis"] == os.environ["EXPECTED_BASIS"]
assert set(snapshot) == {"schema", "observed_at", "scope", "busy", "basis"}
PY
}

empty_fleet="$TEST_ROOT/empty-fleet"
mkdir -p "$empty_fleet"
snapshot="$(PATH="$fake_bin:$PATH" SERGEANT_FLEET="$empty_fleet" \
  "$ROOT/bin/sgt-watch" --snapshot)"
assert_snapshot null no_verified_active_witness "$snapshot"
SNAPSHOT="$snapshot" python3 - <<'PY'
import json
import os
assert json.loads(os.environ["SNAPSHOT"])["scope"] == {
    "kind": "fleet", "task_id": None, "repo": None
}
PY
[[ "$snapshot" != *'"busy":false'* ]]

fleet="$TEST_ROOT/fleet"
make_worker "$fleet" task-active app in_progress 1900
active_repo="$FIXTURE_REPO"
active_worktree="$FIXTURE_WORKTREE"
active_identity="$FIXTURE_IDENTITY"
snapshot="$(PANE_IDENTITY="$active_identity" PANE_ACTIVITY=1950 PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$fleet" SERGEANT_STALL_GRACE_SECONDS=300 \
  "$ROOT/bin/sgt-watch" --snapshot)"
assert_snapshot true verified_active_worker "$snapshot"

progress_only_snapshot="$(PANE_IDENTITY="$active_identity" PANE_ACTIVITY=0 \
  PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" SERGEANT_STALL_GRACE_SECONDS=300 \
  "$ROOT/bin/sgt-watch" --snapshot task-active)"
assert_snapshot true verified_active_worker "$progress_only_snapshot"

rm "$active_repo/progress_ts"
activity_only_snapshot="$(PANE_IDENTITY="$active_identity" PANE_ACTIVITY=1950 \
  PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" SERGEANT_STALL_GRACE_SECONDS=300 \
  "$ROOT/bin/sgt-watch" --snapshot task-active)"
assert_snapshot true verified_active_worker "$activity_only_snapshot"

missing_progress_snapshot="$(SNAPSHOT_STATUS_PATH="$active_worktree/.sergeant-status" \
  SNAPSHOT_STATUS_MTIME=1900 PANE_IDENTITY="$active_identity" PANE_ACTIVITY=0 \
  PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" SERGEANT_STALL_GRACE_SECONDS=300 \
  "$ROOT/bin/sgt-watch" --snapshot task-active)"
assert_snapshot null no_verified_active_witness "$missing_progress_snapshot"

failed_activity_snapshot="$(SNAPSHOT_STATUS_PATH="$active_worktree/.sergeant-status" \
  SNAPSHOT_STATUS_MTIME=1900 TMUX_ACTIVITY_FAIL=1 PANE_IDENTITY="$active_identity" \
  PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" SERGEANT_STALL_GRACE_SECONDS=300 \
  "$ROOT/bin/sgt-watch" --snapshot task-active)"
assert_snapshot null no_verified_active_witness "$failed_activity_snapshot"

printf '1900\n' > "$active_repo/progress_ts"
newer_pane_identity="${active_identity/|1000|/|1950|}"
printf '%s\n' "$newer_pane_identity" > "$active_repo/pane_identity"
snapshot="$(PANE_IDENTITY="$newer_pane_identity" PANE_ACTIVITY=0 PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$fleet" SERGEANT_STALL_GRACE_SECONDS=300 \
  "$ROOT/bin/sgt-watch" --snapshot task-active)"
assert_snapshot null no_verified_active_witness "$snapshot"

rm "$active_repo/progress_ts"
snapshot="$(PANE_IDENTITY="$newer_pane_identity" PANE_ACTIVITY=1900 PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$fleet" SERGEANT_STALL_GRACE_SECONDS=300 \
  "$ROOT/bin/sgt-watch" --snapshot task-active)"
assert_snapshot null no_verified_active_witness "$snapshot"
printf '%s\n' "$active_identity" > "$active_repo/pane_identity"
printf '1900\n' > "$active_repo/progress_ts"

task_snapshot="$(PANE_IDENTITY="$active_identity" PANE_ACTIVITY=1950 PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$fleet" "$ROOT/bin/sgt-watch" --snapshot task-active)"
repo_snapshot="$(PANE_IDENTITY="$active_identity" PANE_ACTIVITY=1950 PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$fleet" "$ROOT/bin/sgt-watch" --snapshot task-active --repo app)"
assert_snapshot true verified_active_worker "$task_snapshot"
assert_snapshot true verified_active_worker "$repo_snapshot"
SNAPSHOT="$repo_snapshot" python3 - <<'PY'
import json
import os
assert json.loads(os.environ["SNAPSHOT"])["scope"] == {
    "kind": "task", "task_id": "task-active", "repo": "app"
}
PY

missing_scope="$(PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  "$ROOT/bin/sgt-watch" --snapshot task-missing --repo app)"
assert_snapshot null no_verified_active_witness "$missing_scope"

printf '1000\n' > "$active_repo/progress_ts"
snapshot="$(PANE_IDENTITY="$active_identity" PANE_ACTIVITY=0 PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$fleet" SERGEANT_STALL_GRACE_SECONDS=300 \
  "$ROOT/bin/sgt-watch" --snapshot task-active)"
assert_snapshot null no_verified_active_witness "$snapshot"

printf '2200\n' > "$active_repo/progress_ts"
snapshot="$(PANE_IDENTITY="$active_identity" PANE_ACTIVITY=0 PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$fleet" SERGEANT_STALL_GRACE_SECONDS=300 \
  "$ROOT/bin/sgt-watch" --snapshot task-active)"
assert_snapshot null no_verified_active_witness "$snapshot"

printf '1900\n' > "$active_repo/progress_ts"
snapshot="$(PANE_IDENTITY="$active_identity" PANE_ACTIVITY=2200 PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$fleet" SERGEANT_STALL_GRACE_SECONDS=300 \
  "$ROOT/bin/sgt-watch" --snapshot task-active)"
assert_snapshot null no_verified_active_witness "$snapshot"

identity_mutation_marker="$TEST_ROOT/identity-mutated"
snapshot="$(TMUX_IDENTITY_AFTER='0|%42|9999|1950|wrong-worker' \
  TMUX_IDENTITY_MARKER="$identity_mutation_marker" PANE_IDENTITY="$active_identity" \
  PANE_ACTIVITY=1950 PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  SERGEANT_STALL_GRACE_SECONDS=300 "$ROOT/bin/sgt-watch" --snapshot task-active)"
assert_snapshot null no_verified_active_witness "$snapshot"

printf '1900\n' > "$active_repo/progress_ts"
printf 'needs_input\n' > "$active_worktree/.sergeant-status"
snapshot="$(PANE_IDENTITY="$active_identity" PANE_ACTIVITY=1950 PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$fleet" "$ROOT/bin/sgt-watch" --snapshot task-active)"
assert_snapshot null no_verified_active_witness "$snapshot"

printf 'in_progress\n' > "$active_worktree/.sergeant-status"
snapshot="$(PANE_IDENTITY='0|%42|9999|999999|wrong-worker' PANE_ACTIVITY=1950 \
  PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  "$ROOT/bin/sgt-watch" --snapshot task-active)"
assert_snapshot null no_verified_active_witness "$snapshot"

printf '%s\0\n' "$active_identity" > "$active_repo/pane_identity"
snapshot="$(PANE_IDENTITY="$active_identity" PANE_ACTIVITY=1950 PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$fleet" "$ROOT/bin/sgt-watch" --snapshot task-active)"
assert_snapshot null no_verified_active_witness "$snapshot"
printf '%s\n' "$active_identity" > "$active_repo/pane_identity"
chmod 600 "$active_repo/pane_identity"

mutation_marker="$TEST_ROOT/status-mutated"
snapshot="$(TMUX_MUTATE_STATUS="$active_worktree/.sergeant-status" \
  TMUX_MUTATE_MARKER="$mutation_marker" PANE_IDENTITY="$active_identity" \
  PANE_ACTIVITY=1950 PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  "$ROOT/bin/sgt-watch" --snapshot task-active)"
assert_snapshot null no_verified_active_witness "$snapshot"
printf 'in_progress\n' > "$active_worktree/.sergeant-status"

before_status="$(cksum "$active_repo/status" "$active_repo/worktree" \
  "$active_repo/pane" "$active_repo/pane_identity" "$active_repo/progress_ts" \
  "$active_worktree/.sergeant-status")"
snapshot="$(PANE_IDENTITY="$active_identity" PANE_ACTIVITY=1950 PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$fleet" "$ROOT/bin/sgt-watch" --snapshot task-active)"
after_status="$(cksum "$active_repo/status" "$active_repo/worktree" \
  "$active_repo/pane" "$active_repo/pane_identity" "$active_repo/progress_ts" \
  "$active_worktree/.sergeant-status")"
[[ "$before_status" == "$after_status" ]]
[[ ! -e "$active_repo/pane_identity_migration" ]]

printf 'PRIVATE-BRIEF-BODY\n' > "$fleet/task-active/brief.md"
printf 'PRIVATE-MESSAGE-BODY\n' > "$active_repo/message"
printf 'PRIVATE-RESULT-BODY\n' > "$active_repo/result"
printf 'PRIVATE-DIAGNOSTIC-BODY\n' > "$active_repo/diagnostic"
snapshot="$(PANE_IDENTITY="$active_identity" PANE_ACTIVITY=1950 PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$fleet" "$ROOT/bin/sgt-watch" --snapshot)"
[[ "$snapshot" != *'PRIVATE-'* ]]
[[ "$snapshot" != *"$TEST_ROOT"* ]]

dispatch_fleet="$TEST_ROOT/dispatch-fleet"
make_worker "$dispatch_fleet" task-dispatch app dispatched 1900
dispatch_identity="$FIXTURE_IDENTITY"
rm "$FIXTURE_WORKTREE/.sergeant-status"
snapshot="$(PANE_IDENTITY="$dispatch_identity" PANE_ACTIVITY=1950 PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$dispatch_fleet" "$ROOT/bin/sgt-watch" --snapshot)"
assert_snapshot true verified_active_worker "$snapshot"

task_budget_fleet="$TEST_ROOT/task-budget-fleet"
task_budget_dir="$task_budget_fleet/task-budget"
task_budget_sequence="$TEST_ROOT/task-budget-sequence"
for index in $(seq -w 1 65); do
  mkdir -p "$task_budget_dir/repo-$index"
  printf '%s\n' "$task_budget_dir/repo-$index" >> "$task_budget_sequence"
  printf 'blocked\n' > "$task_budget_dir/repo-$index/status"
done
make_worker "$task_budget_fleet" task-budget repo-64 in_progress 1900
budget_identity="$FIXTURE_IDENTITY"
snapshot="$(SNAPSHOT_FIND_DIR="$task_budget_dir" SNAPSHOT_FIND_SEQUENCE="$task_budget_sequence" \
  PANE_IDENTITY="$budget_identity" PANE_ACTIVITY=1950 PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$task_budget_fleet" "$ROOT/bin/sgt-watch" --snapshot task-budget)"
assert_snapshot true verified_active_worker "$snapshot"
printf 'blocked\n' > "$task_budget_dir/repo-64/status"
printf 'blocked\n' > "$FIXTURE_WORKTREE/.sergeant-status"
make_worker "$task_budget_fleet" task-budget repo-65 in_progress 1900
budget_identity="$FIXTURE_IDENTITY"
snapshot="$(SNAPSHOT_FIND_DIR="$task_budget_dir" SNAPSHOT_FIND_SEQUENCE="$task_budget_sequence" \
  PANE_IDENTITY="$budget_identity" PANE_ACTIVITY=1950 PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$task_budget_fleet" "$ROOT/bin/sgt-watch" --snapshot task-budget)"
assert_snapshot null no_verified_active_witness "$snapshot"

fleet_budget="$TEST_ROOT/fleet-budget"
fleet_budget_sequence="$TEST_ROOT/fleet-budget-sequence"
for index in $(seq -w 1 64); do
  repo="$fleet_budget/task-$index/app"
  mkdir -p "$repo"
  printf 'blocked\n' > "$repo/status"
  printf '%s\n' "$fleet_budget/task-$index" >> "$fleet_budget_sequence"
done
make_worker "$fleet_budget" task-65 app in_progress 1900
fleet_budget_identity="$FIXTURE_IDENTITY"
printf '%s\n' "$fleet_budget/task-65" >> "$fleet_budget_sequence"
snapshot="$(SNAPSHOT_FIND_DIR="$fleet_budget" SNAPSHOT_FIND_SEQUENCE="$fleet_budget_sequence" \
  PANE_IDENTITY="$fleet_budget_identity" PANE_ACTIVITY=1950 PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$fleet_budget" "$ROOT/bin/sgt-watch" --snapshot)"
assert_snapshot null no_verified_active_witness "$snapshot"

large_fleet="$TEST_ROOT/large-fleet"
for index in $(seq 1 100); do
  repo="$large_fleet/task-$index/app"
  mkdir -p "$repo"
  printf 'blocked\n' > "$repo/status"
done
large_snapshot="$(PATH="$fake_bin:$PATH" SERGEANT_FLEET="$large_fleet" \
  "$ROOT/bin/sgt-watch" --snapshot)"
assert_snapshot null no_verified_active_witness "$large_snapshot"
(( ${#large_snapshot} < 512 ))
for discarded_field in counts records next truncated complete; do
  [[ "$large_snapshot" != *"\"$discarded_field\""* ]]
done

assert_snapshot_fails() {
  local output status
  set +e
  output="$(SERGEANT_FLEET="$fleet" "$ROOT/bin/sgt-watch" "$@" 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 && "$output" == *'ERROR:'* && "$output" != *"$TEST_ROOT"* ]]
}
assert_snapshot_fails --snapshot ../escape
assert_snapshot_fails --snapshot --repo app
assert_snapshot_fails --snapshot task-active --repo ../escape
assert_snapshot_fails --snapshot task-active extra

printf 'sgt-watch positive-witness snapshot: ok\n'
