#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
TMUX_SESSION="sgt-cleanup-test-$$"

cleanup_fixture() {
  tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
  rm -rf "$TEST_ROOT"
}
trap cleanup_fixture EXIT

mkdir -p "$TEST_ROOT/fleet" "$TEST_ROOT/fake-bin"

assert_cleanup_rejected() {
  local task_id="$1"
  local label="$2"
  local output status

  set +e
  output="$(HOME="$TEST_ROOT/home" SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-cleanup" "$task_id" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || {
    printf 'cleanup accepted unsafe %s task ID: %q\n' "$label" "$task_id" >&2
    exit 1
  }
  [[ "$output" == *"Invalid task ID"* ]] || {
    printf 'cleanup returned an unexpected error for %s task ID: %s\n' "$label" "$output" >&2
    exit 1
  }
}

mkdir -p "$TEST_ROOT/protected/app" "$TEST_ROOT/home"
touch "$TEST_ROOT/protected/canary" "$TEST_ROOT/home/canary"
ln -s "$TEST_ROOT/home" "$TEST_ROOT/fleet/alias"
ln -s "$TEST_ROOT/missing" "$TEST_ROOT/fleet/dangling-alias"

assert_cleanup_rejected "" "empty"
assert_cleanup_rejected "$TEST_ROOT/protected" "absolute"
assert_cleanup_rejected "nested/task" "separator-containing"
assert_cleanup_rejected "." "dot"
assert_cleanup_rejected ".." "dot-dot"
assert_cleanup_rejected "../protected" "traversing"
assert_cleanup_rejected "alias" "symlink-alias"
assert_cleanup_rejected "dangling-alias" "dangling-symlink-alias"

[[ -f "$TEST_ROOT/protected/canary" ]]
[[ -f "$TEST_ROOT/home/canary" ]]
[[ -L "$TEST_ROOT/fleet/alias" ]]
[[ -L "$TEST_ROOT/fleet/dangling-alias" ]]

mkdir -p "$TEST_ROOT/fleet/preflight-task/app" "$TEST_ROOT/fleet/preflight-task/api"
mkdir -p "$TEST_ROOT/preflight-app" "$TEST_ROOT/preflight-api"
printf '%s\n' "$TEST_ROOT/preflight-app" > "$TEST_ROOT/fleet/preflight-task/app/worktree"
printf '%s\n' "$TEST_ROOT/preflight-api" > "$TEST_ROOT/fleet/preflight-task/api/worktree"
printf 'done\n' > "$TEST_ROOT/fleet/preflight-task/app/status"
printf 'result\n' > "$TEST_ROOT/fleet/preflight-task/app/result"
printf 'in_progress\n' > "$TEST_ROOT/fleet/preflight-task/api/status"

set +e
SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" preflight-task > "$TEST_ROOT/preflight-cleanup.log" 2>&1
preflight_status=$?
set -e
[[ "$preflight_status" -ne 0 ]]
grep -Fq 'api is not terminal: in_progress' "$TEST_ROOT/preflight-cleanup.log"
[[ -d "$TEST_ROOT/preflight-app" ]]
[[ -d "$TEST_ROOT/preflight-api" ]]
[[ -d "$TEST_ROOT/fleet/preflight-task" ]]

for unsafe_status in dispatched in_progress needs_input blocked orphaned unknown failed 'failed:' 'failed: '; do
  task_id="status-${unsafe_status}"
  status_state="$TEST_ROOT/fleet/$task_id/app"
  status_worktree="$TEST_ROOT/$task_id-worktree"
  mkdir -p "$status_state" "$status_worktree"
  printf '%s\n' "$status_worktree" > "$status_state/worktree"
  printf '%s\n' "$unsafe_status" > "$status_state/status"

  if SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-cleanup" "$task_id" >/dev/null 2>&1; then
    printf 'cleanup accepted unsafe status: %s\n' "$unsafe_status" >&2
    exit 1
  fi
  [[ -d "$status_worktree" && -d "$TEST_ROOT/fleet/$task_id" ]]
done

for proof_case in missing mismatched; do
  proof_state="$TEST_ROOT/fleet/proof-$proof_case/app"
  proof_worktree="$TEST_ROOT/proof-$proof_case-worktree"
  mkdir -p "$proof_state" "$proof_worktree"
  printf '%s\n' "$proof_worktree" > "$proof_state/worktree"
  printf 'done\n' > "$proof_state/status"
  printf 'result\n' > "$proof_state/result"
  if [[ "$proof_case" == "mismatched" ]]; then
    printf 'in_progress\n' > "$proof_worktree/.sergeant-status"
  fi

  if SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-cleanup" "proof-$proof_case" > "$TEST_ROOT/proof-$proof_case.log" 2>&1; then
    printf 'cleanup accepted %s worktree terminal proof\n' "$proof_case" >&2
    exit 1
  fi
  if [[ "$proof_case" == "missing" ]]; then
    grep -Fq 'worktree terminal proof is missing' "$TEST_ROOT/proof-$proof_case.log"
  fi
  [[ -d "$proof_worktree" && -d "$TEST_ROOT/fleet/proof-$proof_case" ]]
done

for result_case in missing mismatched; do
  result_state="$TEST_ROOT/fleet/result-$result_case/app"
  result_worktree="$TEST_ROOT/result-$result_case-worktree"
  mkdir -p "$result_state" "$result_worktree"
  printf '%s\n' "$result_worktree" > "$result_state/worktree"
  printf 'done\n' > "$result_state/status"
  printf 'fleet result\n' > "$result_state/result"
  printf 'done\n' > "$result_worktree/.sergeant-status"
  if [[ "$result_case" == "mismatched" ]]; then
    printf 'different worktree result\n' > "$result_worktree/.sergeant-result"
  fi

  if SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-cleanup" "result-$result_case" > "$TEST_ROOT/result-$result_case.log" 2>&1; then
    printf 'cleanup accepted %s worktree result proof\n' "$result_case" >&2
    exit 1
  fi
  case "$result_case" in
    missing) grep -Fq 'done requires a result' "$TEST_ROOT/result-$result_case.log" ;;
    mismatched)
      grep -Fq 'worktree result differs from reconciled fleet result' \
        "$TEST_ROOT/result-$result_case.log"
      ;;
  esac
  [[ -d "$result_worktree" && -d "$TEST_ROOT/fleet/result-$result_case" ]]
done

mkdir -p "$TEST_ROOT/fleet/done-without-result/app" "$TEST_ROOT/done-without-result-worktree"
printf '%s\n' "$TEST_ROOT/done-without-result-worktree" > \
  "$TEST_ROOT/fleet/done-without-result/app/worktree"
printf 'done\n' > "$TEST_ROOT/fleet/done-without-result/app/status"
if SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" done-without-result >/dev/null 2>&1; then
  printf 'cleanup accepted done without a reconciled result\n' >&2
  exit 1
fi
[[ -d "$TEST_ROOT/done-without-result-worktree" ]]
[[ -d "$TEST_ROOT/fleet/done-without-result" ]]

# missing-record: no worktree file — cleanup should skip worktree steps and succeed.
mkdir -p "$TEST_ROOT/fleet/absent-missing-record/app"
printf 'done\n' > "$TEST_ROOT/fleet/absent-missing-record/app/status"
printf 'result\n' > "$TEST_ROOT/fleet/absent-missing-record/app/result"
SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" absent-missing-record \
  > "$TEST_ROOT/absent-missing-record.log" 2>&1 || {
  printf 'cleanup rejected absent-missing-record (no worktree): %s\n' \
    "$(cat "$TEST_ROOT/absent-missing-record.log")" >&2
  exit 1
}
[[ ! -d "$TEST_ROOT/fleet/absent-missing-record" ]] || {
  printf 'fleet state not removed for absent-missing-record\n' >&2; exit 1
}

# pre-existing: worktree recorded but externally removed — cleanup should synthesize
# evidence from fleet state and complete successfully (idempotent replay).
mkdir -p "$TEST_ROOT/fleet/absent-pre-existing/app"
printf 'done\n' > "$TEST_ROOT/fleet/absent-pre-existing/app/status"
printf 'result\n' > "$TEST_ROOT/fleet/absent-pre-existing/app/result"
printf '%s\n' "$TEST_ROOT/absent-worktree-gone" \
  > "$TEST_ROOT/fleet/absent-pre-existing/app/worktree"
SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" absent-pre-existing \
  > "$TEST_ROOT/absent-pre-existing.log" 2>&1 || {
  printf 'cleanup rejected absent-pre-existing (external removal): %s\n' \
    "$(cat "$TEST_ROOT/absent-pre-existing.log")" >&2
  exit 1
}
[[ ! -d "$TEST_ROOT/fleet/absent-pre-existing" ]] || {
  printf 'fleet state not removed for absent-pre-existing\n' >&2; exit 1
}

mkdir -p "$TEST_ROOT/fleet/failed-task/app" "$TEST_ROOT/failed-task"
git -C "$TEST_ROOT/failed-task" init -q
git -C "$TEST_ROOT/failed-task" config user.name Test
git -C "$TEST_ROOT/failed-task" config user.email test@example.invalid
touch "$TEST_ROOT/failed-task/README.md"
git -C "$TEST_ROOT/failed-task" add README.md
git -C "$TEST_ROOT/failed-task" commit -qm fixture
git -C "$TEST_ROOT/failed-task" worktree add -q -b test-failed-cleanup \
  "$TEST_ROOT/failed-task-sgt-failed-task"
printf 'failed: terminal worker failure\n' > "$TEST_ROOT/fleet/failed-task/app/status"
printf '%s\n' "$TEST_ROOT/failed-task-sgt-failed-task" > \
  "$TEST_ROOT/fleet/failed-task/app/worktree"
printf 'failed: terminal worker failure\n' > \
  "$TEST_ROOT/failed-task-sgt-failed-task/.sergeant-status"
SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" failed-task >/dev/null
[[ ! -e "$TEST_ROOT/fleet/failed-task" ]]

mkdir -p "$TEST_ROOT/fleet/removal-failure/aaa" "$TEST_ROOT/fleet/removal-failure/app" \
  "$TEST_ROOT/fake-bin"
mkdir -p "$TEST_ROOT/removal-success/.git" "$TEST_ROOT/removal-success-sgt-removal-failure"
printf '%s\n' "$TEST_ROOT/removal-success-sgt-removal-failure" > \
  "$TEST_ROOT/fleet/removal-failure/aaa/worktree"
printf 'done\n' > "$TEST_ROOT/fleet/removal-failure/aaa/status"
printf 'success result\n' > "$TEST_ROOT/fleet/removal-failure/aaa/result"
printf 'done\n' > "$TEST_ROOT/removal-success-sgt-removal-failure/.sergeant-status"
printf 'success result\n' > "$TEST_ROOT/removal-success-sgt-removal-failure/.sergeant-result"
printf 'earlier diagnostic\n' > \
  "$TEST_ROOT/removal-success-sgt-removal-failure/.sergeant-diagnostic"
mkdir -p "$TEST_ROOT/removal-failure/.git" "$TEST_ROOT/removal-failure-sgt-removal-failure"
printf '%s\n' "$TEST_ROOT/removal-failure-sgt-removal-failure" > \
  "$TEST_ROOT/fleet/removal-failure/app/worktree"
printf 'done\n' > "$TEST_ROOT/fleet/removal-failure/app/status"
printf 'result\n' > "$TEST_ROOT/fleet/removal-failure/app/result"
printf 'done\n' > "$TEST_ROOT/removal-failure-sgt-removal-failure/.sergeant-status"
printf 'result\n' > "$TEST_ROOT/removal-failure-sgt-removal-failure/.sergeant-result"
printf 'removal diagnostic\n' > \
  "$TEST_ROOT/removal-failure-sgt-removal-failure/.sergeant-diagnostic"
cat > "$TEST_ROOT/fake-bin/git" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" rev-parse "*) printf 'true\n' ;;
  *" status "*) ;;
  *" worktree remove "*)
    worktree="${!#}"
    if [[ "$worktree" == *removal-success* ]]; then
      rm -rf "$worktree"
    elif [[ -e "$FAKE_GIT_STATE" ]]; then
      rm -rf "$worktree"
    else
      touch "$FAKE_GIT_STATE"
      exit 1
    fi
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/git"
if PATH="$TEST_ROOT/fake-bin:$PATH" FAKE_GIT_STATE="$TEST_ROOT/git-failed-once" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" removal-failure >/dev/null 2>&1; then
  printf 'cleanup succeeded after worktree removal failed\n' >&2
  exit 1
fi
[[ -d "$TEST_ROOT/removal-failure-sgt-removal-failure" ]]
[[ ! -e "$TEST_ROOT/removal-success-sgt-removal-failure" ]]
[[ -d "$TEST_ROOT/fleet/removal-failure" ]]
[[ "$(cat "$TEST_ROOT/fleet/removal-failure/aaa/cleanup-phase")" == \
  $'reconciled-absent\n'"$TEST_ROOT/removal-success-sgt-removal-failure" ]]
[[ "$(cat "$TEST_ROOT/fleet/removal-failure/aaa/terminal-evidence/.sergeant-diagnostic")" == \
  'earlier diagnostic' ]]
[[ "$(cat "$TEST_ROOT/fleet/removal-failure/app/terminal-evidence/.sergeant-diagnostic")" == \
  'removal diagnostic' ]]
[[ "$(cat "$TEST_ROOT/removal-failure-sgt-removal-failure/.sergeant-status")" == 'done' ]]
[[ "$(cat "$TEST_ROOT/removal-failure-sgt-removal-failure/.sergeant-result")" == 'result' ]]
PATH="$TEST_ROOT/fake-bin:$PATH" FAKE_GIT_STATE="$TEST_ROOT/git-failed-once" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" removal-failure >/dev/null
[[ ! -e "$TEST_ROOT/fleet/removal-failure" ]]
rm "$TEST_ROOT/fake-bin/git"

mkdir -p "$TEST_ROOT/fleet/marker-publication/app" "$TEST_ROOT/marker/.git" \
  "$TEST_ROOT/marker-sgt-marker-publication"
printf '%s\n' "$TEST_ROOT/marker-sgt-marker-publication" > \
  "$TEST_ROOT/fleet/marker-publication/app/worktree"
printf 'done\n' > "$TEST_ROOT/fleet/marker-publication/app/status"
printf 'result\n' > "$TEST_ROOT/fleet/marker-publication/app/result"
printf 'done\n' > "$TEST_ROOT/marker-sgt-marker-publication/.sergeant-status"
printf 'result\n' > "$TEST_ROOT/marker-sgt-marker-publication/.sergeant-result"
cat > "$TEST_ROOT/fake-bin/git" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" rev-parse "*) printf 'true\n' ;;
  *" status "*) ;;
  *" worktree remove "*) rm -rf "${!#}" ;;
  *) exit 1 ;;
esac
EOF
REAL_MV="$(command -v mv)"
export REAL_MV
cat > "$TEST_ROOT/fake-bin/mv" <<'EOF'
#!/usr/bin/env bash
if [[ "$(sed -n '1p' "$1")" == "reconciled-absent" && ! -e "$FAKE_MV_STATE" ]]; then
  touch "$FAKE_MV_STATE"
  exit 1
fi
"$REAL_MV" "$@"
EOF
chmod +x "$TEST_ROOT/fake-bin/git" "$TEST_ROOT/fake-bin/mv"
if PATH="$TEST_ROOT/fake-bin:$PATH" FAKE_MV_STATE="$TEST_ROOT/mv-failed-once" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" marker-publication >/dev/null 2>&1; then
  printf 'cleanup succeeded after reconciled phase publication failed\n' >&2
  exit 1
fi
[[ ! -e "$TEST_ROOT/marker-sgt-marker-publication" ]]
[[ "$(sed -n '1p' "$TEST_ROOT/fleet/marker-publication/app/cleanup-phase")" == \
  'removing' ]]
PATH="$TEST_ROOT/fake-bin:$PATH" FAKE_MV_STATE="$TEST_ROOT/mv-failed-once" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" marker-publication >/dev/null
[[ ! -e "$TEST_ROOT/fleet/marker-publication" ]]
rm "$TEST_ROOT/fake-bin/git" "$TEST_ROOT/fake-bin/mv"

mkdir -p "$TEST_ROOT/fleet/staging-failure/app" "$TEST_ROOT/staging/.git" \
  "$TEST_ROOT/staging-sgt-staging-failure"
printf '%s\n' "$TEST_ROOT/staging-sgt-staging-failure" > \
  "$TEST_ROOT/fleet/staging-failure/app/worktree"
printf 'done\n' > "$TEST_ROOT/fleet/staging-failure/app/status"
printf 'result\n' > "$TEST_ROOT/fleet/staging-failure/app/result"
printf 'done\n' > "$TEST_ROOT/staging-sgt-staging-failure/.sergeant-status"
printf 'result\n' > "$TEST_ROOT/staging-sgt-staging-failure/.sergeant-result"
cat > "$TEST_ROOT/fake-bin/git" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" rev-parse "*) printf 'true\n' ;;
  *" status "*) ;;
  *" worktree remove "*) rm -rf "${!#}" ;;
  *) exit 1 ;;
esac
EOF
REAL_CP="$(command -v cp)"
export REAL_CP
cat > "$TEST_ROOT/fake-bin/cp" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *".sergeant-status"* && ! -e "$FAKE_CP_STATE" ]]; then
  touch "$FAKE_CP_STATE"
  exit 1
fi
"$REAL_CP" "$@"
EOF
chmod +x "$TEST_ROOT/fake-bin/git" "$TEST_ROOT/fake-bin/cp"
if PATH="$TEST_ROOT/fake-bin:$PATH" FAKE_CP_STATE="$TEST_ROOT/cp-failed-once" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" staging-failure >/dev/null 2>&1; then
  printf 'cleanup succeeded after terminal evidence staging failed\n' >&2
  exit 1
fi
[[ -f "$TEST_ROOT/staging-sgt-staging-failure/.sergeant-status" ]]
[[ -f "$TEST_ROOT/staging-sgt-staging-failure/.sergeant-result" ]]
PATH="$TEST_ROOT/fake-bin:$PATH" FAKE_CP_STATE="$TEST_ROOT/cp-failed-once" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" staging-failure >/dev/null
[[ ! -e "$TEST_ROOT/fleet/staging-failure" ]]
rm "$TEST_ROOT/fake-bin/git" "$TEST_ROOT/fake-bin/cp"

mkdir -p "$TEST_ROOT/fleet/task-123/app" "$TEST_ROOT/repo"
git -C "$TEST_ROOT/repo" init -q
git -C "$TEST_ROOT/repo" config user.name Test
git -C "$TEST_ROOT/repo" config user.email test@example.invalid
touch "$TEST_ROOT/repo/README.md"
git -C "$TEST_ROOT/repo" add README.md
git -C "$TEST_ROOT/repo" commit -qm fixture

worktree="$TEST_ROOT/repo-sgt-task-123"
repo_state="$TEST_ROOT/fleet/task-123/app"
git -C "$TEST_ROOT/repo" worktree add -q -b test-cleanup "$worktree"
printf '%s\n' "$worktree" > "$repo_state/worktree"
printf 'git\n' > "$repo_state/wt_type"
printf 'done\n' > "$repo_state/status"
printf 'result\n' > "$repo_state/result"
printf 'done\n' > "$worktree/.sergeant-status"
printf 'result\n' > "$worktree/.sergeant-result"
printf '%s\n' "$TMUX_SESSION" > "$repo_state/tmux_session"

printf 'uncommitted\n' > "$worktree/uncommitted.txt"
if SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" task-123 >/dev/null 2>&1; then
  printf 'cleanup accepted an uncommitted worktree\n' >&2
  exit 1
fi
[[ -d "$worktree" && -d "$TEST_ROOT/fleet/task-123" ]]
rm "$worktree/uncommitted.txt"

cat > "$TEST_ROOT/fake-bin/fake-agent" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$AGENT_PID_FILE"
trap '' TERM HUP
trap 'exit 0' INT
while :; do sleep 1; done
EOF
chmod +x "$TEST_ROOT/fake-bin/fake-agent"

cat > "$TEST_ROOT/fake-bin/sgt-worker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$WORKER_PID_FILE"
"$FAKE_AGENT" &
wait "$!"
EOF
chmod +x "$TEST_ROOT/fake-bin/sgt-worker"

tmux new-session -d -s "$TMUX_SESSION" -n unrelated \
  "while :; do sleep 1; done"
unrelated_pid="$(tmux display-message -p -t "$TMUX_SESSION:unrelated" '#{pane_pid}')"
worker_pane="$(tmux new-window -P -F '#{pane_id}' -t "$TMUX_SESSION:" -n worker \
  "env WORKER_PID_FILE='$TEST_ROOT/worker.pid' AGENT_PID_FILE='$TEST_ROOT/agent.pid' \
  FAKE_AGENT='$TEST_ROOT/fake-bin/fake-agent' \
  '$TEST_ROOT/fake-bin/sgt-worker' '$repo_state' '$worktree'")"
printf '%s\n' "$worker_pane" > "$repo_state/pane"

for pid_file in "$TEST_ROOT/worker.pid" "$TEST_ROOT/agent.pid"; do
  for _ in $(seq 1 100); do
    [[ -s "$pid_file" ]] && break
    sleep 0.01
  done
  [[ -s "$pid_file" ]]
done
worker_pid="$(cat "$TEST_ROOT/worker.pid")"
agent_pid="$(cat "$TEST_ROOT/agent.pid")"

mkdir "$worktree/held-subdirectory"
holder_pane="$(tmux new-window -P -F '#{pane_id}' -t "$TMUX_SESSION:" -n holder \
  -c "$worktree/held-subdirectory" "while :; do sleep 1; done")"
set +e
SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" task-123 > "$TEST_ROOT/blocked-cleanup.log" 2>&1
cleanup_status=$?
set -e
[[ "$cleanup_status" -ne 0 ]]
grep -Fq 'Other processes still have' "$TEST_ROOT/blocked-cleanup.log" || {
  printf 'unexpected cleanup failure:\n%s\n' "$(cat "$TEST_ROOT/blocked-cleanup.log")" >&2
  exit 1
}
tmux display-message -p -t "$holder_pane" '#{pane_id}' >/dev/null
[[ -d "$worktree" && -d "$TEST_ROOT/fleet/task-123" ]]
if kill -0 "$worker_pid" 2>/dev/null; then
  printf 'worker process still running after blocked cleanup: %s\n' "$worker_pid" >&2
  exit 1
fi
if kill -0 "$agent_pid" 2>/dev/null; then
  printf 'agent process still running after blocked cleanup: %s\n' "$agent_pid" >&2
  exit 1
fi

tmux kill-pane -t "$holder_pane"
SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" task-123 >/dev/null

for _ in $(seq 1 100); do
  if ! tmux list-panes -a -F '#{pane_id}' | grep -Fxq "$worker_pane"; then
    break
  fi
  sleep 0.01
done
if tmux list-panes -a -F '#{pane_id}' | grep -Fxq "$worker_pane"; then
  printf 'worker pane still exists after cleanup: %s\n' "$worker_pane" >&2
  exit 1
fi
tmux has-session -t "$TMUX_SESSION"
tmux display-message -p -t "$TMUX_SESSION:unrelated" '#{pane_id}' >/dev/null
kill -0 "$unrelated_pid"
if kill -0 "$worker_pid" 2>/dev/null; then
  printf 'worker process still running after cleanup: %s\n' "$worker_pid" >&2
  exit 1
fi
if kill -0 "$agent_pid" 2>/dev/null; then
  printf 'agent process still running after cleanup: %s\n' "$agent_pid" >&2
  exit 1
fi
[[ ! -e "$worktree" ]]
[[ ! -e "$TEST_ROOT/fleet/task-123" ]]

SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" task-123 >/dev/null

printf 'sgt-cleanup worker termination: ok\n'
