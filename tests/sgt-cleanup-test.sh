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

mkdir -p "$TEST_ROOT/fleet" "$TEST_ROOT/fake-bin" "$TEST_ROOT/config"
export SERGEANT_CONFIG="$TEST_ROOT/config"
REAL_GIT="$(command -v git)"
export REAL_GIT

init_test_repo() {
  local repo_root="$1"

  mkdir -p "$repo_root"
  git -C "$repo_root" init -q
  git -C "$repo_root" config user.name Test
  git -C "$repo_root" config user.email test@example.invalid
  printf 'fixture\n' > "$repo_root/README.md"
  git -C "$repo_root" add README.md
  git -C "$repo_root" commit -qm fixture
}

record_retry_owner() {
  local task_id="$1" repo_name="$2" repo_root="$3"

  cat > "$TEST_ROOT/config/$task_id.yaml" <<EOF
name: $task_id
repos:
  - name: $repo_name
    path: $repo_root
EOF
  printf 'Project: %s\n' "$task_id" > "$TEST_ROOT/fleet/$task_id/brief.md"
}

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

stale_state="$TEST_ROOT/fleet/stale-dead-pane/app"
mkdir -p "$stale_state" "$TEST_ROOT/stale-bin"
printf 'done\n' > "$stale_state/status"
printf 'result\n' > "$stale_state/result"
printf '%s\n' "$TEST_ROOT/missing-stale-worktree" > "$stale_state/worktree"
printf '%%77\n' > "$stale_state/validation_pane"
printf '0|%%77|7777|123456|validation-command\n' > "$stale_state/validation_pane_identity"
chmod 600 "$stale_state/validation_pane_identity"
printf '7777\n' > "$stale_state/validation_pane_pid"
printf '7777\n' > "$stale_state/validation_process_group"
printf 'Mon Jan  1 00:00:00 2024\n' > "$stale_state/validation_process_start"
cat > "$TEST_ROOT/stale-bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  display-message)
    format=""
    for argument in "$@"; do format="$argument"; done
    if [[ "$format" == '#{pane_id}' ]]; then
      printf '%%77\n'
    else
      printf '1|%%77|8888|654321|unrelated-command\n'
    fi
    ;;
  kill-pane) printf '%s\n' "$*" >> "$STALE_TMUX_LOG" ;;
esac
EOF
chmod +x "$TEST_ROOT/stale-bin/tmux"
set +e
PATH="$TEST_ROOT/stale-bin:$PATH" STALE_TMUX_LOG="$TEST_ROOT/stale-tmux.log" \
SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" stale-dead-pane > "$TEST_ROOT/stale-dead-pane.log" 2>&1
stale_status=$?
set -e
[[ "$stale_status" -ne 0 ]]
grep -Fq 'Recorded validation pane identity does not match' "$TEST_ROOT/stale-dead-pane.log"
[[ ! -e "$TEST_ROOT/stale-tmux.log" ]]
[[ -d "$TEST_ROOT/fleet/stale-dead-pane" ]]
rm -rf "$TEST_ROOT/fleet/stale-dead-pane"

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

for unsafe_status in dispatched in_progress needs_input blocked waiting orphaned unknown failed 'failed:' 'failed: '; do
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

setup_response_cleanup_fixture() {
  local state_name="$1"
  response_state="$TEST_ROOT/fleet/response-$state_name/app"
  response_worktree="$TEST_ROOT/response-$state_name-worktree"
  response_archive="$response_state/response-archive/response-123"
  mkdir -p "$response_archive" "$response_worktree"
  printf '%s\n' "$response_worktree" > "$response_state/worktree"
  printf 'done\n' > "$response_state/status"
  printf 'result\n' > "$response_state/result"
  printf 'done\n' > "$response_worktree/.sergeant-status"
  printf 'result\n' > "$response_worktree/.sergeant-result"
  printf 'response-123\n' > "$response_state/response_id"
  printf '1\n' > "$response_state/response_generation"
  printf 'response body\n' > "$response_archive/body"
  printf '1\n' > "$response_archive/gate_generation"
  printf 'done\n' > "$response_archive/applied_status"
  cat > "$response_archive/proof" <<'EOF'
response_id=response-123
gate_generation=1
status=done
EOF
}

for response_case in pending-transport archive-only fleet-ack both-acks-with-transport partial-transport \
  archive-proof-mismatch; do
  setup_response_cleanup_fixture "$response_case"
  case "$response_case" in
    pending-transport)
      rm -rf "$response_state/response-archive"
      printf 'response body\n' > "$response_state/response"
      printf 'response body\n' > "$response_worktree/.sergeant-response"
      ;;
    archive-only) ;;
    fleet-ack)
      printf 'response-123\n' > "$response_state/response_ack"
      ;;
    both-acks-with-transport)
      printf 'response-123\n' > "$response_state/response_ack"
      printf 'response-123\n' > "$response_worktree/.sergeant-response-ack"
      printf 'response body\n' > "$response_state/response"
      printf 'response body\n' > "$response_worktree/.sergeant-response"
      ;;
    partial-transport)
      printf 'response-123\n' > "$response_state/response_ack"
      printf 'response-123\n' > "$response_worktree/.sergeant-response-ack"
      printf 'response body\n' > "$response_worktree/.sergeant-response"
      ;;
    archive-proof-mismatch)
      printf 'response-123\n' > "$response_state/response_ack"
      printf 'response-123\n' > "$response_worktree/.sergeant-response-ack"
      printf 'response_id=response-123\ngate_generation=2\nstatus=done\n' \
        > "$response_archive/proof"
      ;;
  esac

  set +e
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-cleanup" "response-$response_case" \
    > "$TEST_ROOT/response-$response_case.log" 2>&1
  response_status=$?
  set -e
  [[ "$response_status" -ne 0 ]]
  grep -Fq 'pending or incomplete response acknowledgement' \
    "$TEST_ROOT/response-$response_case.log"
  [[ -d "$response_worktree" && -d "$response_state" ]]
done

setup_response_cleanup_fixture complete
mkdir -p "$response_state/terminal-evidence"
printf 'response-123\n' > "$response_worktree/.sergeant-response-ack"
cp "$response_worktree/.sergeant-status" "$response_state/terminal-evidence/.sergeant-status"
cp "$response_worktree/.sergeant-result" "$response_state/terminal-evidence/.sergeant-result"
cp "$response_worktree/.sergeant-response-ack" \
  "$response_state/terminal-evidence/.sergeant-response-ack"
printf 'response-123\n' > "$response_state/response_ack"
rm -rf "$response_worktree"
SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" response-complete >/dev/null
[[ ! -e "$TEST_ROOT/fleet/response-complete" ]]

lock_state="$TEST_ROOT/fleet/response-lock/app"
lock_worktree="$TEST_ROOT/response-lock-missing-worktree"
mkdir -p "$lock_state/terminal-evidence"
printf '%s\n' "$lock_worktree" > "$lock_state/worktree"
printf 'done\n' > "$lock_state/status"
printf 'result\n' > "$lock_state/result"
printf 'done\n' > "$lock_state/terminal-evidence/.sergeant-status"
printf 'result\n' > "$lock_state/terminal-evidence/.sergeant-result"
printf 'invalid-owner\n' > "$lock_state/response.lock"
set +e
SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" response-lock > "$TEST_ROOT/response-lock.log" 2>&1
lock_status=$?
set -e
[[ "$lock_status" -ne 0 ]]
grep -Fq 'Response lock has an invalid owner' "$TEST_ROOT/response-lock.log"
[[ -d "$lock_state" ]]

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
record_retry_owner failed-task app "$TEST_ROOT/failed-task"
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
  "$TEST_ROOT/fake-bin" "$TEST_ROOT/config"
cat > "$TEST_ROOT/config/removal-failure.yaml" <<EOF
name: removal-failure
repos:
  - name: aaa
    path: $TEST_ROOT/removal-success
  - name: app
    path: $TEST_ROOT/removal-failure
EOF
printf 'Project: removal-failure\n' > "$TEST_ROOT/fleet/removal-failure/brief.md"
init_test_repo "$TEST_ROOT/removal-success"
mkdir -p "$TEST_ROOT/removal-success-sgt-removal-failure"
printf '%s\n' "$TEST_ROOT/removal-success-sgt-removal-failure" > \
  "$TEST_ROOT/fleet/removal-failure/aaa/worktree"
printf 'done\n' > "$TEST_ROOT/fleet/removal-failure/aaa/status"
printf 'success result\n' > "$TEST_ROOT/fleet/removal-failure/aaa/result"
printf 'done\n' > "$TEST_ROOT/removal-success-sgt-removal-failure/.sergeant-status"
printf 'success result\n' > "$TEST_ROOT/removal-success-sgt-removal-failure/.sergeant-result"
printf 'earlier diagnostic\n' > \
  "$TEST_ROOT/removal-success-sgt-removal-failure/.sergeant-diagnostic"
init_test_repo "$TEST_ROOT/removal-failure"
printf 'second fixture\n' >> "$TEST_ROOT/removal-failure/README.md"
git -C "$TEST_ROOT/removal-failure" add README.md
git -C "$TEST_ROOT/removal-failure" commit -qm 'second fixture'
git init -q --bare "$TEST_ROOT/removal-failure-origin.git"
git -C "$TEST_ROOT/removal-failure" remote add origin \
  "$TEST_ROOT/removal-failure-origin.git"
git -C "$TEST_ROOT/removal-failure" push -q -u origin HEAD:main
git -C "$TEST_ROOT/removal-failure-origin.git" symbolic-ref HEAD refs/heads/main
mkdir -p "$TEST_ROOT/removal-failure-sgt-removal-failure"
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
  *" rev-list "*|*" for-each-ref "*|*" config --get remote.origin.url "*|*" status --porcelain=v1 "*|*" diff "*|*" ls-files "*|*" hash-object "*) "$REAL_GIT" "$@" ;;
  *" rev-parse "*) printf 'true\n' ;;
  *" status "*) ;;
  *" worktree remove "*)
    worktree="${!#}"
    printf '%s\n' "$worktree" >> "$FAKE_GIT_LOG"
    if [[ "$worktree" == *removal-success* ]]; then
      rm -rf "$worktree"
    elif [[ -e "$FAKE_GIT_STATE" ]]; then
      rm -rf "$worktree"
    else
      rm -rf "$worktree"
      touch "$FAKE_GIT_STATE"
      exit 1
    fi
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/git"
if PATH="$TEST_ROOT/fake-bin:$PATH" FAKE_GIT_STATE="$TEST_ROOT/git-failed-once" \
  FAKE_GIT_LOG="$TEST_ROOT/git-removals" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" removal-failure >/dev/null 2>&1; then
  printf 'cleanup succeeded after worktree removal failed\n' >&2
  exit 1
fi
[[ ! -e "$TEST_ROOT/removal-failure-sgt-removal-failure" ]]
[[ ! -e "$TEST_ROOT/removal-success-sgt-removal-failure" ]]
[[ -d "$TEST_ROOT/fleet/removal-failure" ]]
[[ "$(cat "$TEST_ROOT/fleet/removal-failure/aaa/cleanup-phase")" == \
  $'reconciled-absent\n'"$TEST_ROOT/removal-success-sgt-removal-failure" ]]
[[ "$(cat "$TEST_ROOT/fleet/removal-failure/app/cleanup-phase")" == \
  $'partial-removal\n'"$TEST_ROOT/removal-failure-sgt-removal-failure"$'\ngit\n'"$TEST_ROOT/removal-failure" ]]
[[ "$(wc -l < "$TEST_ROOT/git-removals")" -eq 2 ]]
[[ "$(cat "$TEST_ROOT/fleet/removal-failure/aaa/terminal-evidence/.sergeant-diagnostic")" == \
  'earlier diagnostic' ]]
[[ "$(cat "$TEST_ROOT/fleet/removal-failure/app/terminal-evidence/.sergeant-diagnostic")" == \
  'removal diagnostic' ]]
printf '%s\n' "$TEST_ROOT/different-worktree" > \
  "$TEST_ROOT/fleet/removal-failure/app/worktree"
if PATH="$TEST_ROOT/fake-bin:$PATH" FAKE_GIT_STATE="$TEST_ROOT/git-failed-once" \
  FAKE_GIT_LOG="$TEST_ROOT/git-removals" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" removal-failure >/dev/null 2>&1; then
  printf 'cleanup reconciled partial removal against a different worktree\n' >&2
  exit 1
fi
[[ -d "$TEST_ROOT/fleet/removal-failure" ]]
[[ -f "$TEST_ROOT/fleet/removal-failure/app/terminal-evidence/.sergeant-status" ]]
[[ "$(cat "$TEST_ROOT/fleet/removal-failure/app/cleanup-phase")" == \
  $'partial-removal\n'"$TEST_ROOT/removal-failure-sgt-removal-failure"$'\ngit\n'"$TEST_ROOT/removal-failure" ]]
[[ "$(wc -l < "$TEST_ROOT/git-removals")" -eq 2 ]]
printf '%s\n' "$TEST_ROOT/removal-failure-sgt-removal-failure" > \
  "$TEST_ROOT/fleet/removal-failure/app/worktree"
cp -a "$TEST_ROOT/removal-failure/.git" "$TEST_ROOT/removal-failure-git-state"
cp -p "$TEST_ROOT/removal-failure/README.md" "$TEST_ROOT/removal-failure-readme"

restore_removal_failure_repo() {
  local path

  for path in "$TEST_ROOT/removal-failure/.git"/* \
    "$TEST_ROOT/removal-failure/.git"/.[!.]* \
    "$TEST_ROOT/removal-failure/.git"/..?*; do
    [[ -e "$path" || -L "$path" ]] && rm -rf "$path"
  done
  cp -a "$TEST_ROOT/removal-failure-git-state/." "$TEST_ROOT/removal-failure/.git/"
  cp -p "$TEST_ROOT/removal-failure-readme" "$TEST_ROOT/removal-failure/README.md"
}

assert_retry_owner_rejected() {
  local evidence_before label="$1" phase_before

  phase_before="$(cat "$TEST_ROOT/fleet/removal-failure/app/cleanup-phase")"
  evidence_before="$(cksum "$TEST_ROOT/fleet/removal-failure/app/terminal-evidence"/.sergeant-*)"
  if PATH="$TEST_ROOT/fake-bin:$PATH" FAKE_GIT_STATE="$TEST_ROOT/git-failed-once" \
    FAKE_GIT_LOG="$TEST_ROOT/git-removals" \
    SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-cleanup" removal-failure >/dev/null 2>&1; then
    printf 'cleanup accepted unsafe retry owner: %s\n' "$label" >&2
    exit 1
  fi
  [[ "$(wc -l < "$TEST_ROOT/git-removals")" -eq 2 ]]
  [[ "$(cat "$TEST_ROOT/fleet/removal-failure/app/cleanup-phase")" == "$phase_before" ]]
  [[ "$(cksum "$TEST_ROOT/fleet/removal-failure/app/terminal-evidence"/.sergeant-*)" == \
    "$evidence_before" ]]
}

printf 'Project: missing-project\n' > "$TEST_ROOT/fleet/removal-failure/brief.md"
assert_retry_owner_rejected 'missing project config'
printf 'Project: removal-failure\n' > "$TEST_ROOT/fleet/removal-failure/brief.md"

ln -s "$TEST_ROOT/removal-failure" "$TEST_ROOT/removal-failure-alias"
printf 'partial-removal\n%s\ngit\n%s\n' \
  "$TEST_ROOT/removal-failure-sgt-removal-failure" \
  "$TEST_ROOT/removal-failure-alias" > \
  "$TEST_ROOT/fleet/removal-failure/app/cleanup-phase"
assert_retry_owner_rejected 'symlink-aliased repository'
cat > "$TEST_ROOT/config/removal-failure.yaml" <<EOF
name: removal-failure
repos:
  - name: aaa
    path: $TEST_ROOT/removal-success
  - name: app
    path: $TEST_ROOT/removal-failure
EOF

mv "$TEST_ROOT/removal-failure" "$TEST_ROOT/removal-failure-original"
git clone -q "$TEST_ROOT/removal-failure-origin.git" "$TEST_ROOT/removal-failure"
[[ "$(git -C "$TEST_ROOT/removal-failure" rev-parse HEAD)" == \
  "$(git -C "$TEST_ROOT/removal-failure-original" rev-parse HEAD)" ]]
[[ "$(git -C "$TEST_ROOT/removal-failure" config --get remote.origin.url)" == \
  "$(git -C "$TEST_ROOT/removal-failure-original" config --get remote.origin.url)" ]]
[[ "$(git -C "$TEST_ROOT/removal-failure" rev-list --max-parents=0 --all | sort)" == \
  "$(git -C "$TEST_ROOT/removal-failure-original" rev-list --max-parents=0 --all | sort)" ]]
[[ ! -e "$TEST_ROOT/removal-failure/.git/sergeant-instance" ]]
assert_retry_owner_rejected 'same-origin clone replacement'
rm -rf "$TEST_ROOT/removal-failure"
mv "$TEST_ROOT/removal-failure-original" "$TEST_ROOT/removal-failure"

git -C "$TEST_ROOT/removal-failure" reset -q --hard HEAD^
assert_retry_owner_rejected 'repository reset changed HEAD and refs'
restore_removal_failure_repo

git -C "$TEST_ROOT/removal-failure" checkout -q --detach HEAD^
assert_retry_owner_rejected 'repository HEAD changed independently'
restore_removal_failure_repo

git -C "$TEST_ROOT/removal-failure" tag retry-ref-drift
assert_retry_owner_rejected 'repository ref changed independently'
restore_removal_failure_repo

git -C "$TEST_ROOT/removal-failure" config sergeant.fixture changed
assert_retry_owner_rejected 'in-place repository metadata change'
restore_removal_failure_repo

printf '#!/bin/sh\n' > "$TEST_ROOT/removal-failure/.git/hooks/cleanup-review"
assert_retry_owner_rejected 'in-place hook metadata change'
restore_removal_failure_repo

printf 'edited fixture\n' >> "$TEST_ROOT/removal-failure/README.md"
assert_retry_owner_rejected 'configured repository worktree edit'
restore_removal_failure_repo

mv "$TEST_ROOT/removal-failure" "$TEST_ROOT/removal-failure-original"
mkdir -p "$TEST_ROOT/removal-failure/.git"
printf 'partial-removal\n%s\ngit\n%s\n' \
  "$TEST_ROOT/removal-failure-sgt-removal-failure" \
  "$TEST_ROOT/removal-failure" > \
  "$TEST_ROOT/fleet/removal-failure/app/cleanup-phase"
assert_retry_owner_rejected 'repository replaced at the same path'
rm -rf "$TEST_ROOT/removal-failure"
mv "$TEST_ROOT/removal-failure-original" "$TEST_ROOT/removal-failure"

mv "$TEST_ROOT/removal-failure" "$TEST_ROOT/removal-failure-moved"
printf 'partial-removal\n%s\ngit\n%s\n' \
  "$TEST_ROOT/removal-failure-sgt-removal-failure" \
  "$TEST_ROOT/removal-failure" > \
  "$TEST_ROOT/fleet/removal-failure/app/cleanup-phase"
assert_retry_owner_rejected 'moved repository'
mv "$TEST_ROOT/removal-failure-moved" "$TEST_ROOT/removal-failure"

mkdir -p "$TEST_ROOT/removal-failure-other/.git"
cat > "$TEST_ROOT/config/cross-project.yaml" <<EOF
name: cross-project
repos:
  - name: app
    path: $TEST_ROOT/removal-failure-other
EOF
printf 'Project: cross-project\n' > "$TEST_ROOT/fleet/removal-failure/brief.md"
printf 'partial-removal\n%s\ngit\n%s\n' \
  "$TEST_ROOT/removal-failure-sgt-removal-failure" \
  "$TEST_ROOT/removal-failure-other" > \
  "$TEST_ROOT/fleet/removal-failure/app/cleanup-phase"
assert_retry_owner_rejected 'cross-project prefix-colliding repository'
printf 'Project: removal-failure\n' > "$TEST_ROOT/fleet/removal-failure/brief.md"
printf 'partial-removal\n%s\ngit\n%s\n' \
  "$TEST_ROOT/removal-failure-sgt-removal-failure" \
  "$TEST_ROOT/removal-failure" > \
  "$TEST_ROOT/fleet/removal-failure/app/cleanup-phase"
cat > "$TEST_ROOT/config/cross-project.yaml" <<EOF
name: cross-project
repos:
  - name: app
    path: $TEST_ROOT/removal-failure
EOF
printf 'Project: cross-project\n' > "$TEST_ROOT/fleet/removal-failure/brief.md"
assert_retry_owner_rejected 'cross-project repository at the same path'
printf 'Project: removal-failure\n' > "$TEST_ROOT/fleet/removal-failure/brief.md"
rm "$TEST_ROOT/config/removal-failure.yaml"
PATH="$TEST_ROOT/fake-bin:$PATH" FAKE_GIT_STATE="$TEST_ROOT/git-failed-once" \
  FAKE_GIT_LOG="$TEST_ROOT/git-removals" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" removal-failure >/dev/null
[[ "$(wc -l < "$TEST_ROOT/git-removals")" -eq 3 ]]
[[ ! -e "$TEST_ROOT/fleet/removal-failure" ]]

mkdir -p "$TEST_ROOT/fleet/dirty-retry/app" \
  "$TEST_ROOT/dirty-retry-sgt-dirty-retry"
init_test_repo "$TEST_ROOT/dirty-retry"
record_retry_owner dirty-retry app "$TEST_ROOT/dirty-retry"
printf 'dirty before cleanup\n' >> "$TEST_ROOT/dirty-retry/README.md"
printf 'untracked before cleanup\n' > "$TEST_ROOT/dirty-retry/untracked.txt"
printf '%s\n' "$TEST_ROOT/dirty-retry-sgt-dirty-retry" > \
  "$TEST_ROOT/fleet/dirty-retry/app/worktree"
printf 'done\n' > "$TEST_ROOT/fleet/dirty-retry/app/status"
printf 'result\n' > "$TEST_ROOT/fleet/dirty-retry/app/result"
printf 'done\n' > "$TEST_ROOT/dirty-retry-sgt-dirty-retry/.sergeant-status"
printf 'result\n' > "$TEST_ROOT/dirty-retry-sgt-dirty-retry/.sergeant-result"
if PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_GIT_STATE="$TEST_ROOT/dirty-retry-failed-once" \
  FAKE_GIT_LOG="$TEST_ROOT/dirty-retry-removals" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" dirty-retry >/dev/null 2>&1; then
  printf 'cleanup succeeded after dirty retry removal failed\n' >&2
  exit 1
fi
[[ "$(wc -l < "$TEST_ROOT/dirty-retry-removals")" -eq 1 ]]
printf 'different dirty contents\n' > "$TEST_ROOT/dirty-retry/README.md"
if PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_GIT_STATE="$TEST_ROOT/dirty-retry-failed-once" \
  FAKE_GIT_LOG="$TEST_ROOT/dirty-retry-removals" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" dirty-retry >/dev/null 2>&1; then
  printf 'cleanup accepted changed contents with unchanged dirty status\n' >&2
  exit 1
fi
[[ "$(wc -l < "$TEST_ROOT/dirty-retry-removals")" -eq 1 ]]
[[ -f "$TEST_ROOT/fleet/dirty-retry/app/terminal-evidence/.sergeant-status" ]]
printf 'fixture\ndirty before cleanup\n' > "$TEST_ROOT/dirty-retry/README.md"
printf 'different untracked contents\n' > "$TEST_ROOT/dirty-retry/untracked.txt"
if PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_GIT_STATE="$TEST_ROOT/dirty-retry-failed-once" \
  FAKE_GIT_LOG="$TEST_ROOT/dirty-retry-removals" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" dirty-retry >/dev/null 2>&1; then
  printf 'cleanup accepted changed untracked contents with unchanged status\n' >&2
  exit 1
fi
[[ "$(wc -l < "$TEST_ROOT/dirty-retry-removals")" -eq 1 ]]
rm "$TEST_ROOT/fake-bin/git"

mkdir -p "$TEST_ROOT/fleet/partial-publication/app" \
  "$TEST_ROOT/partial-publication-sgt-partial-publication"
init_test_repo "$TEST_ROOT/partial-publication"
record_retry_owner partial-publication app "$TEST_ROOT/partial-publication"
printf '%s\n' "$TEST_ROOT/partial-publication-sgt-partial-publication" > \
  "$TEST_ROOT/fleet/partial-publication/app/worktree"
printf 'done\n' > "$TEST_ROOT/fleet/partial-publication/app/status"
printf 'result\n' > "$TEST_ROOT/fleet/partial-publication/app/result"
printf 'done\n' > \
  "$TEST_ROOT/partial-publication-sgt-partial-publication/.sergeant-status"
printf 'result\n' > \
  "$TEST_ROOT/partial-publication-sgt-partial-publication/.sergeant-result"
cat > "$TEST_ROOT/fake-bin/git" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" rev-list "*|*" for-each-ref "*|*" config --get remote.origin.url "*|*" status --porcelain=v1 "*|*" diff "*|*" ls-files "*|*" hash-object "*) "$REAL_GIT" "$@" ;;
  *" rev-parse "*) printf 'true\n' ;;
  *" status "*) ;;
  *" worktree remove "*)
    printf '%s\n' "${!#}" >> "$FAKE_GIT_LOG"
    rm -rf "${!#}"
    if [[ ! -e "$FAKE_GIT_STATE" ]]; then
      touch "$FAKE_GIT_STATE"
      exit 1
    fi
    ;;
  *) exit 1 ;;
esac
EOF
REAL_MV="$(command -v mv)"
export REAL_MV
cat > "$TEST_ROOT/fake-bin/mv" <<'EOF'
#!/usr/bin/env bash
if [[ "$(sed -n '1p' "$1")" == "partial-removal" && ! -e "$FAKE_MV_STATE" ]]; then
  touch "$FAKE_MV_STATE"
  exit 1
fi
"$REAL_MV" "$@"
EOF
chmod +x "$TEST_ROOT/fake-bin/git" "$TEST_ROOT/fake-bin/mv"
if PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_GIT_LOG="$TEST_ROOT/partial-publication-removals" \
  FAKE_GIT_STATE="$TEST_ROOT/partial-publication-git-failed" \
  FAKE_MV_STATE="$TEST_ROOT/partial-publication-mv-failed" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" partial-publication >/dev/null 2>&1; then
  printf 'cleanup succeeded after partial-removal publication failed\n' >&2
  exit 1
fi
[[ "$(cat "$TEST_ROOT/fleet/partial-publication/app/cleanup-phase")" == \
  $'removing\n'"$TEST_ROOT/partial-publication-sgt-partial-publication"$'\ngit\n'"$TEST_ROOT/partial-publication" ]]
[[ -f "$TEST_ROOT/fleet/partial-publication/app/terminal-evidence/.sergeant-status" ]]
PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_GIT_LOG="$TEST_ROOT/partial-publication-removals" \
  FAKE_GIT_STATE="$TEST_ROOT/partial-publication-git-failed" \
  FAKE_MV_STATE="$TEST_ROOT/partial-publication-mv-failed" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" partial-publication >/dev/null
[[ "$(wc -l < "$TEST_ROOT/partial-publication-removals")" -eq 2 ]]
[[ ! -e "$TEST_ROOT/fleet/partial-publication" ]]
rm "$TEST_ROOT/fake-bin/git" "$TEST_ROOT/fake-bin/mv"

mkdir -p "$TEST_ROOT/fleet/treehouse-partial/app" \
  "$TEST_ROOT/treehouse-worktree"
init_test_repo "$TEST_ROOT/treehouse-main"
record_retry_owner treehouse-partial app "$TEST_ROOT/treehouse-main"
printf 'gitdir: %s\n' "$TEST_ROOT/treehouse-main/.git/worktrees/lease" > \
  "$TEST_ROOT/treehouse-worktree/.git"
printf '%s\n' "$TEST_ROOT/treehouse-worktree" > \
  "$TEST_ROOT/fleet/treehouse-partial/app/worktree"
printf 'treehouse\n' > "$TEST_ROOT/fleet/treehouse-partial/app/wt_type"
printf 'sgt-treehouse-partial-app\n' > \
  "$TEST_ROOT/fleet/treehouse-partial/app/wt_holder"
printf 'done\n' > "$TEST_ROOT/fleet/treehouse-partial/app/status"
printf 'result\n' > "$TEST_ROOT/fleet/treehouse-partial/app/result"
printf 'done\n' > "$TEST_ROOT/treehouse-worktree/.sergeant-status"
printf 'result\n' > "$TEST_ROOT/treehouse-worktree/.sergeant-result"
cat > "$TEST_ROOT/fake-bin/git" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" rev-list "*|*" for-each-ref "*|*" config --get remote.origin.url "*|*" status --porcelain=v1 "*|*" diff "*|*" ls-files "*|*" hash-object "*) "$REAL_GIT" "$@" ;;
  *" rev-parse "*) printf 'true\n' ;;
  *" status "*) ;;
  *) exit 1 ;;
esac
EOF
cat > "$TEST_ROOT/fake-bin/treehouse" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "return" ]]
printf '%s|%s\n' "$PWD" "$2" >> "$FAKE_TREEHOUSE_LOG"
if [[ ! -e "$FAKE_TREEHOUSE_STATE" ]]; then
  rm -rf "$2"
  touch "$FAKE_TREEHOUSE_STATE"
  exit 1
fi
EOF
chmod +x "$TEST_ROOT/fake-bin/git" "$TEST_ROOT/fake-bin/treehouse"
if PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_TREEHOUSE_LOG="$TEST_ROOT/treehouse-removals" \
  FAKE_TREEHOUSE_STATE="$TEST_ROOT/treehouse-failed-once" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" treehouse-partial >/dev/null 2>&1; then
  printf 'cleanup succeeded after treehouse removed the worktree and failed\n' >&2
  exit 1
fi
[[ ! -e "$TEST_ROOT/treehouse-worktree" ]]
[[ "$(cat "$TEST_ROOT/fleet/treehouse-partial/app/cleanup-phase")" == \
  $'partial-removal\n'"$TEST_ROOT/treehouse-worktree"$'\ntreehouse\n'"$TEST_ROOT/treehouse-main" ]]
[[ -f "$TEST_ROOT/fleet/treehouse-partial/app/terminal-evidence/.sergeant-status" ]]
printf 'sgt-another-task-app\n' > \
  "$TEST_ROOT/fleet/treehouse-partial/app/wt_holder"
if PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_TREEHOUSE_LOG="$TEST_ROOT/treehouse-removals" \
  FAKE_TREEHOUSE_STATE="$TEST_ROOT/treehouse-failed-once" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" treehouse-partial >/dev/null 2>&1; then
  printf 'cleanup retried a treehouse lease owned by another holder\n' >&2
  exit 1
fi
[[ "$(wc -l < "$TEST_ROOT/treehouse-removals")" -eq 1 ]]
[[ -f "$TEST_ROOT/fleet/treehouse-partial/app/terminal-evidence/.sergeant-status" ]]
printf 'sgt-treehouse-partial-app\n' > \
  "$TEST_ROOT/fleet/treehouse-partial/app/wt_holder"
printf '%s\n' "$TEST_ROOT/another-treehouse-worktree" > \
  "$TEST_ROOT/fleet/treehouse-partial/app/worktree"
printf 'partial-removal\n%s\ntreehouse\n%s\n' \
  "$TEST_ROOT/another-treehouse-worktree" "$TEST_ROOT/treehouse-main" > \
  "$TEST_ROOT/fleet/treehouse-partial/app/cleanup-phase"
if PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_TREEHOUSE_LOG="$TEST_ROOT/treehouse-removals" \
  FAKE_TREEHOUSE_STATE="$TEST_ROOT/treehouse-failed-once" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" treehouse-partial >/dev/null 2>&1; then
  printf 'cleanup retried a treehouse path not bound to its lease\n' >&2
  exit 1
fi
[[ "$(wc -l < "$TEST_ROOT/treehouse-removals")" -eq 1 ]]
[[ -f "$TEST_ROOT/fleet/treehouse-partial/app/terminal-evidence/.sergeant-status" ]]
printf '%s\n' "$TEST_ROOT/treehouse-worktree" > \
  "$TEST_ROOT/fleet/treehouse-partial/app/worktree"
printf 'partial-removal\n%s\ntreehouse\n%s\n' \
  "$TEST_ROOT/treehouse-worktree" "$TEST_ROOT/treehouse-main" > \
  "$TEST_ROOT/fleet/treehouse-partial/app/cleanup-phase"
PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_TREEHOUSE_LOG="$TEST_ROOT/treehouse-removals" \
  FAKE_TREEHOUSE_STATE="$TEST_ROOT/treehouse-failed-once" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" treehouse-partial >/dev/null
[[ "$(wc -l < "$TEST_ROOT/treehouse-removals")" -eq 2 ]]
[[ "$(sort -u "$TEST_ROOT/treehouse-removals")" == \
  "$TEST_ROOT/treehouse-main|$TEST_ROOT/treehouse-worktree" ]]
[[ ! -e "$TEST_ROOT/fleet/treehouse-partial" ]]
rm "$TEST_ROOT/fake-bin/git" "$TEST_ROOT/fake-bin/treehouse"

mkdir -p "$TEST_ROOT/fleet/marker-publication/app" \
  "$TEST_ROOT/marker-sgt-marker-publication"
init_test_repo "$TEST_ROOT/marker"
record_retry_owner marker-publication app "$TEST_ROOT/marker"
printf '%s\n' "$TEST_ROOT/marker-sgt-marker-publication" > \
  "$TEST_ROOT/fleet/marker-publication/app/worktree"
printf 'done\n' > "$TEST_ROOT/fleet/marker-publication/app/status"
printf 'result\n' > "$TEST_ROOT/fleet/marker-publication/app/result"
printf 'done\n' > "$TEST_ROOT/marker-sgt-marker-publication/.sergeant-status"
printf 'result\n' > "$TEST_ROOT/marker-sgt-marker-publication/.sergeant-result"
cat > "$TEST_ROOT/fake-bin/git" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" rev-list "*|*" for-each-ref "*|*" config --get remote.origin.url "*|*" status --porcelain=v1 "*|*" diff "*|*" ls-files "*|*" hash-object "*) "$REAL_GIT" "$@" ;;
  *" rev-parse "*) printf 'true\n' ;;
  *" status "*) ;;
  *" worktree remove "*)
    printf '%s\n' "${!#}" >> "$FAKE_GIT_LOG"
    [[ ! -e "$FAKE_GIT_STATE" ]] || exit 1
    touch "$FAKE_GIT_STATE"
    rm -rf "${!#}"
    ;;
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
  FAKE_GIT_STATE="$TEST_ROOT/marker-git-removed" \
  FAKE_GIT_LOG="$TEST_ROOT/marker-removals" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" marker-publication >/dev/null 2>&1; then
  printf 'cleanup succeeded after reconciled phase publication failed\n' >&2
  exit 1
fi
[[ ! -e "$TEST_ROOT/marker-sgt-marker-publication" ]]
[[ "$(sed -n '1p' "$TEST_ROOT/fleet/marker-publication/app/cleanup-phase")" == \
  'removed' ]]
PATH="$TEST_ROOT/fake-bin:$PATH" FAKE_MV_STATE="$TEST_ROOT/mv-failed-once" \
  FAKE_GIT_STATE="$TEST_ROOT/marker-git-removed" \
  FAKE_GIT_LOG="$TEST_ROOT/marker-removals" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" marker-publication >/dev/null
[[ "$(wc -l < "$TEST_ROOT/marker-removals")" -eq 1 ]]
[[ ! -e "$TEST_ROOT/fleet/marker-publication" ]]
rm "$TEST_ROOT/fake-bin/git" "$TEST_ROOT/fake-bin/mv"

mkdir -p "$TEST_ROOT/fleet/staging-failure/app" \
  "$TEST_ROOT/staging-sgt-staging-failure"
init_test_repo "$TEST_ROOT/staging"
record_retry_owner staging-failure app "$TEST_ROOT/staging"
printf '%s\n' "$TEST_ROOT/staging-sgt-staging-failure" > \
  "$TEST_ROOT/fleet/staging-failure/app/worktree"
printf 'done\n' > "$TEST_ROOT/fleet/staging-failure/app/status"
printf 'result\n' > "$TEST_ROOT/fleet/staging-failure/app/result"
printf 'done\n' > "$TEST_ROOT/staging-sgt-staging-failure/.sergeant-status"
printf 'result\n' > "$TEST_ROOT/staging-sgt-staging-failure/.sergeant-result"
cat > "$TEST_ROOT/fake-bin/git" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" rev-list "*|*" for-each-ref "*|*" config --get remote.origin.url "*|*" status --porcelain=v1 "*|*" diff "*|*" ls-files "*|*" hash-object "*) "$REAL_GIT" "$@" ;;
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

mkdir -p "$TEST_ROOT/fleet/legacy-task/app" "$TEST_ROOT/legacy-repo"
git -C "$TEST_ROOT/legacy-repo" init -q
git -C "$TEST_ROOT/legacy-repo" config user.name Test
git -C "$TEST_ROOT/legacy-repo" config user.email test@example.invalid
touch "$TEST_ROOT/legacy-repo/README.md"
git -C "$TEST_ROOT/legacy-repo" add README.md
git -C "$TEST_ROOT/legacy-repo" commit -qm fixture

legacy_worktree="$TEST_ROOT/legacy-repo-sgt-legacy-task"
legacy_repo_state="$TEST_ROOT/fleet/legacy-task/app"
git -C "$TEST_ROOT/legacy-repo" worktree add -q -b test-cleanup-legacy "$legacy_worktree"
legacy_validation_worktree="${legacy_worktree}-validation-legacy-task"
git clone -q "$legacy_worktree" "$legacy_validation_worktree"
printf '%s\n' "$legacy_validation_worktree" > "$legacy_repo_state/validation_worktree"
printf '%s\n' "$(git -C "$legacy_validation_worktree" rev-parse HEAD)" > \
  "$legacy_repo_state/validation_head"
printf '%s\n' "$legacy_worktree" > "$legacy_repo_state/worktree"
printf 'git\n' > "$legacy_repo_state/wt_type"
printf 'done\n' > "$legacy_repo_state/status"
printf 'result\n' > "$legacy_repo_state/result"
printf 'done\n' > "$legacy_worktree/.sergeant-status"
printf 'result\n' > "$legacy_worktree/.sergeant-result"

SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" legacy-task >/dev/null
[[ ! -e "$legacy_validation_worktree" && ! -e "$legacy_worktree" && \
  ! -e "$TEST_ROOT/fleet/legacy-task" ]]

mkdir -p "$TEST_ROOT/fleet/task-123/app" "$TEST_ROOT/repo"
git -C "$TEST_ROOT/repo" init -q
git -C "$TEST_ROOT/repo" config user.name Test
git -C "$TEST_ROOT/repo" config user.email test@example.invalid
touch "$TEST_ROOT/repo/README.md"
git -C "$TEST_ROOT/repo" add README.md
git -C "$TEST_ROOT/repo" commit -qm fixture
record_retry_owner task-123 app "$TEST_ROOT/repo"

worktree="$TEST_ROOT/repo-sgt-task-123"
repo_state="$TEST_ROOT/fleet/task-123/app"
git -C "$TEST_ROOT/repo" worktree add -q -b test-cleanup "$worktree"
validation_worktree="${worktree}-validation-task-123"
git clone -q "$worktree" "$validation_worktree"
printf '%s\n' "$validation_worktree" > "$repo_state/validation_worktree"
path_identity() {
  stat -c '%d:%i:%w' "$1" 2>/dev/null || stat -f '%d:%i:%B' "$1"
}
validation_identity="$(path_identity "$validation_worktree")"
validation_git_dir="$(git -C "$validation_worktree" rev-parse --path-format=absolute --git-common-dir)"
validation_git_identity="$(path_identity "$validation_git_dir")"
validation_head="$(git -C "$validation_worktree" rev-parse HEAD)"
validation_owner="task-123/app/validation-launch|test-owner|$validation_head"
printf '%s\n' "$validation_identity" > "$repo_state/validation_worktree_identity"
printf '%s\n' "$validation_git_dir" > "$repo_state/validation_worktree_git_dir"
printf '%s\n' "$validation_git_identity" > "$repo_state/validation_worktree_git_identity"
printf '%s\n' "$validation_head" > "$repo_state/validation_head"
printf '%s\n' "$validation_owner" > "$repo_state/validation_worktree_owner"
printf '%s\n' "$validation_owner" > "$validation_git_dir/sergeant-validation-owner"
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

bash -c '
  set -euo pipefail
  source "$1"
  repo_state="$2"
  acquired="$3"
  _sgt_response_lock_acquire "$repo_state"
  touch "$acquired"
  for _ in $(seq 1 500); do
    compgen -G "$repo_state/.response.lock.*" >/dev/null && break
    sleep 0.01
  done
  compgen -G "$repo_state/.response.lock.*" >/dev/null
  archive="$repo_state/response-archive/response-123"
  mkdir -p "$archive"
  printf "response-123\n" > "$repo_state/response_id"
  printf "1\n" > "$repo_state/response_generation"
  printf "response body\n" > "$archive/body"
  printf "1\n" > "$archive/gate_generation"
  printf "done\n" > "$archive/applied_status"
  printf "response_id=response-123\ngate_generation=1\nstatus=done\n" > "$archive/proof"
  _sgt_response_lock_release
' _ "$ROOT_DIR/bin/_sgt-response-lock.sh" "$repo_state" "$TEST_ROOT/contention-acquired" &
lock_holder_pid=$!
for _ in $(seq 1 500); do
  [[ -e "$TEST_ROOT/contention-acquired" ]] && break
  sleep 0.01
done
[[ -e "$TEST_ROOT/contention-acquired" ]]
set +e
SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" task-123 > "$TEST_ROOT/response-contention.log" 2>&1
contention_status=$?
set -e
wait "$lock_holder_pid"
[[ "$contention_status" -ne 0 ]]
grep -Fq 'pending or incomplete response acknowledgement' "$TEST_ROOT/response-contention.log"
[[ -d "$worktree" && -d "$repo_state" ]]
[[ -f "$repo_state/response-archive/response-123/body" ]]
rm -rf "$repo_state/response-archive"
rm -f "$repo_state/response_id" "$repo_state/response_generation"

cat > "$TEST_ROOT/fake-bin/fake-agent" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$AGENT_PID_FILE"
trap '' TERM HUP
trap 'exit 0' INT
while :; do sleep 1; done
EOF
chmod +x "$TEST_ROOT/fake-bin/fake-agent"

cat > "$TEST_ROOT/fake-bin/sgt-interactive-worker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$WORKER_PID_FILE"
"$FAKE_AGENT" &
wait "$!"
EOF
chmod +x "$TEST_ROOT/fake-bin/sgt-interactive-worker"
cat > "$TEST_ROOT/fake-bin/sgt-validation-worker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$VALIDATION_PID_FILE"
sh -c 'printf "%s\n" "$$" > "$VALIDATION_CHILD_PID_FILE"; trap "" HUP; while :; do sleep 1; done' &
while [[ ! -e "$VALIDATION_EXIT_FILE" ]]; do sleep 0.01; done
EOF
chmod +x "$TEST_ROOT/fake-bin/sgt-validation-worker"

tmux new-session -d -s "$TMUX_SESSION" -n unrelated \
  "while :; do sleep 1; done"
unrelated_pid="$(tmux display-message -p -t "$TMUX_SESSION:unrelated" '#{pane_pid}')"
worker_pane="$(tmux new-window -P -F '#{pane_id}' -t "$TMUX_SESSION:" -n worker \
  "env WORKER_PID_FILE='$TEST_ROOT/worker.pid' AGENT_PID_FILE='$TEST_ROOT/agent.pid' \
  FAKE_AGENT='$TEST_ROOT/fake-bin/fake-agent' \
  '$TEST_ROOT/fake-bin/sgt-interactive-worker' '$repo_state' '$worktree'")"
printf '%s\n' "$worker_pane" > "$repo_state/pane"
tmux display-message -p -t "$worker_pane" \
  '#{pane_dead}|#{pane_id}|#{pane_pid}|#{pane_created}|#{pane_start_command}' \
  > "$repo_state/pane_identity"
chmod 600 "$repo_state/pane_identity"
validation_pane="$(tmux new-window -P -F '#{pane_id}' -t "$TMUX_SESSION:" -n validation \
  "env VALIDATION_PID_FILE='$TEST_ROOT/validation.pid' \
  VALIDATION_CHILD_PID_FILE='$TEST_ROOT/validation-child.pid' \
  VALIDATION_EXIT_FILE='$TEST_ROOT/validation-exit' \
  '$TEST_ROOT/fake-bin/sgt-validation-worker' '$repo_state' '$worktree'")"
printf '%s\n' "$validation_pane" > "$repo_state/validation_pane"
tmux display-message -p -t "$validation_pane" \
  '#{pane_dead}|#{pane_id}|#{pane_pid}|#{pane_created}|#{pane_start_command}' \
  > "$repo_state/validation_pane_identity"
chmod 600 "$repo_state/validation_pane_identity"

for pid_file in "$TEST_ROOT/worker.pid" "$TEST_ROOT/agent.pid" "$TEST_ROOT/validation.pid" \
  "$TEST_ROOT/validation-child.pid"; do
  for _ in $(seq 1 100); do
    [[ -s "$pid_file" ]] && break
    sleep 0.01
  done
  [[ -s "$pid_file" ]]
done
worker_pid="$(cat "$TEST_ROOT/worker.pid")"
agent_pid="$(cat "$TEST_ROOT/agent.pid")"
validation_pid="$(cat "$TEST_ROOT/validation.pid")"
validation_child_pid="$(cat "$TEST_ROOT/validation-child.pid")"
printf '%s\n' "$validation_pid" > "$repo_state/validation_pane_pid"
ps -o pgid= -p "$validation_pid" | tr -d ' ' > "$repo_state/validation_process_group"
ps -o lstart= -p "$validation_pid" | awk '{$1=$1; print}' > "$repo_state/validation_process_start"
validation_start="$(cat "$repo_state/validation_process_start")"
printf 'stale process start\n' > "$repo_state/validation_process_start"
set +e
SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" task-123 > "$TEST_ROOT/reused-validation-owner.log" 2>&1
cleanup_status=$?
set -e
[[ "$cleanup_status" -ne 0 ]]
grep -Fq 'Validation owner PID was reused' "$TEST_ROOT/reused-validation-owner.log"
kill -0 "$validation_pid"
kill -0 "$validation_child_pid"
[[ -d "$worktree" && -d "$validation_worktree" ]]
printf '%s\n' "$validation_start" > "$repo_state/validation_process_start"
touch "$TEST_ROOT/validation-exit"
for _ in $(seq 1 100); do
  kill -0 "$validation_pid" 2>/dev/null || break
  sleep 0.01
done
if kill -0 "$validation_pid" 2>/dev/null || ! kill -0 "$validation_child_pid" 2>/dev/null; then
  printf 'validation detached-child fixture did not reach the required state\n' >&2
  exit 1
fi

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
if kill -0 "$validation_pid" 2>/dev/null; then
  printf 'validation process still running after blocked cleanup: %s\n' "$validation_pid" >&2
  exit 1
fi
if kill -0 "$validation_child_pid" 2>/dev/null; then
  printf 'detached validation child still running after blocked cleanup: %s\n' \
    "$validation_child_pid" >&2
  exit 1
fi

tmux kill-pane -t "$holder_pane"
saved_validation_start="$(cat "$repo_state/validation_process_start")"
rm "$repo_state/validation_process_start"
set +e
SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" task-123 > "$TEST_ROOT/missing-validation-provenance.log" 2>&1
cleanup_status=$?
set -e
[[ "$cleanup_status" -ne 0 ]]
grep -Fq 'Validation pane ownership provenance is incomplete' \
  "$TEST_ROOT/missing-validation-provenance.log"
printf '%s\n' "$saved_validation_start" > "$repo_state/validation_process_start"

assert_validation_checkout_rejected() {
  local label="$1" output status
  set +e
  output="$(SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-cleanup" task-123 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 && "$output" == *'Validation checkout'* ]]
  [[ -e "$validation_worktree" || -L "$validation_worktree" ]] || {
    printf '%s replacement validation checkout was removed\n' "$label" >&2
    exit 1
  }
}

printf 'wrong-owner\n' > "$validation_git_dir/sergeant-validation-owner"
assert_validation_checkout_rejected owner
printf '%s\n' "$validation_owner" > "$validation_git_dir/sergeant-validation-owner"

mv "$validation_git_dir" "$TEST_ROOT/original-validation-git"
git -C "$validation_worktree" init -q
assert_validation_checkout_rejected reinitialized
rm -rf "$validation_worktree/.git"
mv "$TEST_ROOT/original-validation-git" "$validation_git_dir"

mv "$validation_worktree" "$TEST_ROOT/original-validation-worktree"
git clone -q "$worktree" "$validation_worktree"
assert_validation_checkout_rejected replacement
rm -rf "$validation_worktree"
mv "$TEST_ROOT/original-validation-worktree" "$validation_worktree"

mv "$validation_worktree" "$TEST_ROOT/original-validation-worktree"
ln -s "$TEST_ROOT/missing-validation-worktree" "$validation_worktree"
assert_validation_checkout_rejected dangling
rm "$validation_worktree"
mv "$TEST_ROOT/original-validation-worktree" "$validation_worktree"

real_mv="$(command -v mv)"
real_git="$(command -v git)"
cat > "$TEST_ROOT/fake-bin/mv" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${VALIDATION_REPLACE_ON_MOVE:-}" && "$1" == "$VALIDATION_PATH" && \
  "${2:-}" == "$VALIDATION_PATH".cleanup.* ]]; then
  "$REAL_MV" "$1" "$RACE_ORIGINAL"
  "$REAL_GIT" clone -q "$SOURCE_WORKTREE" "$VALIDATION_PATH"
  printf 'race-replacement\n' > "$VALIDATION_PATH/race-sentinel"
fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$TEST_ROOT/fake-bin/mv"
set +e
race_output="$(PATH="$TEST_ROOT/fake-bin:$PATH" REAL_MV="$real_mv" REAL_GIT="$real_git" \
  VALIDATION_REPLACE_ON_MOVE=1 VALIDATION_PATH="$validation_worktree" \
  RACE_ORIGINAL="$TEST_ROOT/race-original-validation" SOURCE_WORKTREE="$worktree" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" task-123 2>&1)"
race_status=$?
set -e
[[ "$race_status" -ne 0 && "$race_output" == *'changed during cleanup and was preserved'* ]]
[[ "$(cat "$validation_worktree/race-sentinel")" == race-replacement ]]
rm -rf "$validation_worktree"
mv "$TEST_ROOT/race-original-validation" "$validation_worktree"

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
[[ ! -e "$validation_worktree" ]]
[[ ! -e "$TEST_ROOT/fleet/task-123" ]]

SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" task-123 >/dev/null

# --- PR14-F1 regression: prefix/suffix-colliding task and worktree names ---
#
# Proves that cleanup identifies owned panes by exact recorded identity rather
# than by substring-matching the pane start command.  Three tasks share their
# name components in both prefix and suffix directions:
#
#   col-a   — task being cleaned up
#   col-ab  — PREFIX collision: "col-a" is a leading substring of "col-ab"
#   xcol-a  — SUFFIX collision: "col-a" is a trailing substring of "xcol-a"
#
# Corresponding worktree names also collide:
#   col-base-sgt-col-a   (the one being removed)
#   col-base-sgt-col-ab  (prefix: col-a is a prefix of col-ab)
#   col-base-sgt-xcol-a  (suffix: col-a is a suffix of xcol-a)
#
# The old code checked:
#   pane_command contains *sgt-worker*  AND  pane_command contains *"$repo_dir"*
#
# The new code stores the full tmux pane identity at dispatch time and compares
# with _sgt_pane_identity_matches for an exact match.  This ensures that neither
# col-ab's nor xcol-a's pane is touched when cleaning up col-a.

mkdir -p "$TEST_ROOT/fleet/col-a/app" "$TEST_ROOT/fleet/col-ab/app" \
  "$TEST_ROOT/fleet/xcol-a/app" "$TEST_ROOT/col-base"
git -C "$TEST_ROOT/col-base" init -q
git -C "$TEST_ROOT/col-base" config user.name Test
git -C "$TEST_ROOT/col-base" config user.email test@example.invalid
touch "$TEST_ROOT/col-base/README.md"
git -C "$TEST_ROOT/col-base" add README.md
git -C "$TEST_ROOT/col-base" commit -qm fixture

col_a_worktree="$TEST_ROOT/col-base-sgt-col-a"
col_ab_worktree="$TEST_ROOT/col-base-sgt-col-ab"
xcol_a_worktree="$TEST_ROOT/col-base-sgt-xcol-a"
git -C "$TEST_ROOT/col-base" worktree add -q -b col-a-branch "$col_a_worktree"
git -C "$TEST_ROOT/col-base" worktree add -q -b col-ab-branch "$col_ab_worktree"
git -C "$TEST_ROOT/col-base" worktree add -q -b xcol-a-branch "$xcol_a_worktree"

col_a_state="$TEST_ROOT/fleet/col-a/app"
col_ab_state="$TEST_ROOT/fleet/col-ab/app"
xcol_a_state="$TEST_ROOT/fleet/xcol-a/app"

printf 'done\n'      > "$col_a_state/status"
printf 'col-a\n'     > "$col_a_state/result"
printf '%s\n' "$col_a_worktree" > "$col_a_state/worktree"
printf 'git\n'       > "$col_a_state/wt_type"
printf 'done\n'      > "$col_a_worktree/.sergeant-status"
printf 'col-a\n'     > "$col_a_worktree/.sergeant-result"

printf 'done\n'      > "$col_ab_state/status"
printf 'col-ab\n'    > "$col_ab_state/result"
printf '%s\n' "$col_ab_worktree" > "$col_ab_state/worktree"
printf 'git\n'       > "$col_ab_state/wt_type"
printf 'done\n'      > "$col_ab_worktree/.sergeant-status"
printf 'col-ab\n'    > "$col_ab_worktree/.sergeant-result"

printf 'done\n'      > "$xcol_a_state/status"
printf 'xcol-a\n'    > "$xcol_a_state/result"
printf '%s\n' "$xcol_a_worktree" > "$xcol_a_state/worktree"
printf 'git\n'       > "$xcol_a_state/wt_type"
printf 'done\n'      > "$xcol_a_worktree/.sergeant-status"
printf 'xcol-a\n'    > "$xcol_a_worktree/.sergeant-result"

# col-ab's pane command deliberately contains col-a's fleet path as a substring
# (prefix collision: "col-a" is a leading substring of "col-ab").
# xcol-a's pane command contains col-a's fleet path as a trailing substring
# (suffix collision: "col-a" is a trailing substring of "xcol-a").
# The old code's *"$col_a_state"* pattern would incorrectly match these panes.
col_a_pane="$(tmux new-window -P -F '#{pane_id}' -t "$TMUX_SESSION:" -n col-a-worker \
  "while :; do sleep 1; done")"
col_ab_pane="$(tmux new-window -P -F '#{pane_id}' -t "$TMUX_SESSION:" -n col-ab-worker \
  "env 'COL_A_STATE=$col_a_state' bash -c 'while :; do sleep 1; done'")"
xcol_a_pane="$(tmux new-window -P -F '#{pane_id}' -t "$TMUX_SESSION:" -n xcol-a-worker \
  "env 'XCOL_A_PARENT=$col_a_state' bash -c 'while :; do sleep 1; done'")"

printf '%s\n' "$col_a_pane" > "$col_a_state/pane"
tmux display-message -p -t "$col_a_pane" \
  '#{pane_dead}|#{pane_id}|#{pane_pid}|#{pane_created}|#{pane_start_command}' \
  > "$col_a_state/pane_identity"
chmod 600 "$col_a_state/pane_identity"

printf '%s\n' "$col_ab_pane" > "$col_ab_state/pane"
tmux display-message -p -t "$col_ab_pane" \
  '#{pane_dead}|#{pane_id}|#{pane_pid}|#{pane_created}|#{pane_start_command}' \
  > "$col_ab_state/pane_identity"
chmod 600 "$col_ab_state/pane_identity"

printf '%s\n' "$xcol_a_pane" > "$xcol_a_state/pane"
tmux display-message -p -t "$xcol_a_pane" \
  '#{pane_dead}|#{pane_id}|#{pane_pid}|#{pane_created}|#{pane_start_command}' \
  > "$xcol_a_state/pane_identity"
chmod 600 "$xcol_a_state/pane_identity"

SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" col-a >/dev/null

# col-a's pane must be dead (exact identity matched → terminated)
for _ in $(seq 1 100); do
  tmux list-panes -a -F '#{pane_id}' | grep -Fxq "$col_a_pane" || break
  sleep 0.01
done
if tmux list-panes -a -F '#{pane_id}' | grep -Fxq "$col_a_pane"; then
  printf 'col-a worker pane still alive after cleanup\n' >&2
  exit 1
fi

# col-ab's pane must survive (PREFIX collision must not kill sibling)
if ! tmux display-message -p -t "$col_ab_pane" '#{pane_id}' >/dev/null 2>&1; then
  printf 'col-ab worker pane was incorrectly killed (prefix collision bug)\n' >&2
  exit 1
fi

# xcol-a's pane must survive (SUFFIX collision must not kill sibling)
if ! tmux display-message -p -t "$xcol_a_pane" '#{pane_id}' >/dev/null 2>&1; then
  printf 'xcol-a worker pane was incorrectly killed (suffix collision bug)\n' >&2
  exit 1
fi

# col-a's worktree and fleet state must be removed
[[ ! -d "$col_a_worktree" ]] || {
  printf 'col-a worktree not removed after cleanup\n' >&2; exit 1
}
[[ ! -d "$TEST_ROOT/fleet/col-a" ]] || {
  printf 'col-a fleet state not removed after cleanup\n' >&2; exit 1
}

# col-ab's worktree and fleet state must survive (prefix collision)
[[ -d "$col_ab_worktree" ]] || {
  printf 'col-ab worktree was incorrectly removed (prefix collision bug)\n' >&2; exit 1
}
[[ -d "$TEST_ROOT/fleet/col-ab" ]] || {
  printf 'col-ab fleet state was incorrectly removed (prefix collision bug)\n' >&2; exit 1
}

# xcol-a's worktree and fleet state must survive (suffix collision)
[[ -d "$xcol_a_worktree" ]] || {
  printf 'xcol-a worktree was incorrectly removed (suffix collision bug)\n' >&2; exit 1
}
[[ -d "$TEST_ROOT/fleet/xcol-a" ]] || {
  printf 'xcol-a fleet state was incorrectly removed (suffix collision bug)\n' >&2; exit 1
}

# Idempotent cleanup of siblings to leave session in known state
SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" col-ab >/dev/null
SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" xcol-a >/dev/null

# --- PR14-F1 regression: pane recycling with substring-matching command ---
#
# If a recorded pane ID is recycled and the replacement pane runs a command
# that would have matched the old *sgt-worker* + *"$repo_dir"* substring check,
# the new code must reject it because the stored pane_identity will not match
# the live pane's exact identity.
#
# Simulation: stub tmux returns a live pane whose identity differs from the
# stored pane_identity file.  The pane start command deliberately contains the
# task's repo_dir path so that the old substring check *would* have matched.
# The new code's _sgt_pane_identity_matches must return false and leave the
# pane untouched.

recycled_state="$TEST_ROOT/fleet/recycled-pane/app"
mkdir -p "$recycled_state" "$TEST_ROOT/recycled-bin"
printf 'done\n'   > "$recycled_state/status"
printf 'result\n' > "$recycled_state/result"
printf '%s\n' "$TEST_ROOT/missing-recycled-worktree" > "$recycled_state/worktree"

# Stored identity: pane %88, pid 8800, created at a specific past timestamp.
# This is what was recorded when the original worker was dispatched.
stored_pane_id='%88'
stored_identity="0|${stored_pane_id}|8800|Mon Jan  1 00:00:00 2000|original-sgt-worker ${recycled_state}"
printf '%s\n' "$stored_pane_id" > "$recycled_state/pane"
printf '%s\n' "$stored_identity" > "$recycled_state/pane_identity"
chmod 600 "$recycled_state/pane_identity"

# Stub tmux simulates pane recycling: %88 is now alive but with a NEW identity
# (different pid and creation time — a different process than the one we owned).
# The start command still contains recycled_state so the old substring check
# (*"$recycled_state"*) *would* have fired.
cat > "$TEST_ROOT/recycled-bin/tmux" <<EOF
#!/usr/bin/env bash
# Stub covers only the tmux commands reachable in the identity-mismatch path
# of _stop_local_worker: _sgt_pane_identity (full format) and, if the pane
# were killed, the #{pane_id} existence probe.  Because identity mismatches
# cause _stop_local_worker to skip to "recorded pane no longer belongs", the
# kill-pane path is never reached, so the catch-all returns exit 0 silently,
# which is safe — no actual tmux side-effects are exercised beyond these two.
case "\${*}" in
  *'display-message'*'-t'*'%88'*'#{pane_dead}'*)
    # Full identity query (#{pane_dead}|#{pane_id}|...) — return a DIFFERENT
    # identity than the stored one: same pane_id but different pid and time.
    # This simulates pane recycling: %88 is live but belongs to a new process.
    printf '0|%%88|9900|Tue Feb  2 11:11:11 2025|recycled-sgt-worker ${recycled_state}\n'
    ;;
  *'display-message'*'-t'*'%88'*)
    # Existence probe (#{pane_id} only) — pane %88 is present
    printf '%%88\n'
    ;;
  *'kill-pane'*)
    printf '%s\n' "\$*" >> "$TEST_ROOT/recycled-kills.log"
    ;;
  *) ;;
esac
EOF
chmod +x "$TEST_ROOT/recycled-bin/tmux"

set +e
PATH="$TEST_ROOT/recycled-bin:$PATH" SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" recycled-pane > "$TEST_ROOT/recycled-pane.log" 2>&1
recycled_status=$?
set -e

# Cleanup must succeed (absent worktree → reconciled-absent → fleet state cleared)
[[ "$recycled_status" -eq 0 ]] || {
  printf 'recycled-pane cleanup failed unexpectedly: %s\n' \
    "$(cat "$TEST_ROOT/recycled-pane.log")" >&2
  exit 1
}
# The recycled pane must NOT have been killed: identity mismatch must have
# caused the new code to skip it with "recorded pane no longer belongs to this
# worker", not to invoke kill-pane.
[[ ! -e "$TEST_ROOT/recycled-kills.log" ]] || {
  printf 'recycled pane was incorrectly killed (pane identity not checked exactly):\n%s\n' \
    "$(cat "$TEST_ROOT/recycled-kills.log")" >&2
  exit 1
}
grep -Fq 'recorded pane no longer belongs to this worker' "$TEST_ROOT/recycled-pane.log"

# === PR14-F2 regression: escaped descendant terminated after pane exits ===
# Scenario: the worker pane exits BEFORE cleanup runs.  The escaped descendant
# ignores SIGTERM/SIGHUP and has changed CWD away from the worktree, so neither
# the tree-records (empty — pane dead) nor the CWD guard catch it.
# sgt-interactive-worker records its PGID in fleet state at startup; cleanup
# uses that stored PGID to terminate any surviving process-group members.

escaped_state="$TEST_ROOT/fleet/escaped-task/app"
escaped_worktree="$TEST_ROOT/escaped-repo-sgt-escaped-task"
mkdir -p "$escaped_state" "$TEST_ROOT/escaped-repo"
git -C "$TEST_ROOT/escaped-repo" init -q
git -C "$TEST_ROOT/escaped-repo" config user.name Test
git -C "$TEST_ROOT/escaped-repo" config user.email test@example.invalid
touch "$TEST_ROOT/escaped-repo/README.md"
git -C "$TEST_ROOT/escaped-repo" add README.md
git -C "$TEST_ROOT/escaped-repo" commit -qm fixture
git -C "$TEST_ROOT/escaped-repo" worktree add -q -b test-escaped "$escaped_worktree"
printf '%s\n' "$escaped_worktree" > "$escaped_state/worktree"
printf 'git\n' > "$escaped_state/wt_type"
printf 'local-tmux\n' > "$escaped_state/backend"
printf 'done\n' > "$escaped_state/status"
printf 'result\n' > "$escaped_state/result"
printf 'done\n' > "$escaped_worktree/.sergeant-status"
printf 'result\n' > "$escaped_worktree/.sergeant-result"

# fake-escaped-descendant: ignores SIGTERM+SIGHUP, changes CWD, loops forever.
cat > "$TEST_ROOT/fake-bin/fake-escaped-descendant" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$ESCAPED_PID_FILE"
trap '' TERM HUP
cd /tmp
while :; do sleep 1; done
EOF
chmod +x "$TEST_ROOT/fake-bin/fake-escaped-descendant"

# fake-worker-for-escape: records its own PID/PGID/start to simulate what
# sgt-interactive-worker does at startup, spawns the escaped descendant, then
# exits — leaving the descendant running after the pane becomes dead.
cat > "$TEST_ROOT/fake-bin/fake-worker-for-escape" <<'EOF'
#!/usr/bin/env bash
pgid="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ')"
start="$(ps -o lstart= -p "$$" 2>/dev/null | sed 's/^ *//;s/ *$//')"
printf '%s\n' "$$"    > "$WORKER_STATE_DIR/worker_pid"
printf '%s\n' "$pgid" > "$WORKER_STATE_DIR/worker_process_group"
printf '%s\n' "$start" > "$WORKER_STATE_DIR/worker_process_start"
"$FAKE_ESCAPED_BIN" &
for _ in $(seq 1 100); do
  [[ -s "$ESCAPED_PID_FILE" ]] && break
  sleep 0.01
done
exit 0
EOF
chmod +x "$TEST_ROOT/fake-bin/fake-worker-for-escape"

escaped_pane="$(tmux new-window -P -F '#{pane_id}' -t "$TMUX_SESSION:" -n escaped \
  "env WORKER_STATE_DIR='$escaped_state' \
  FAKE_ESCAPED_BIN='$TEST_ROOT/fake-bin/fake-escaped-descendant' \
  ESCAPED_PID_FILE='$TEST_ROOT/escaped.pid' \
  '$TEST_ROOT/fake-bin/fake-worker-for-escape'")"
printf '%s\n' "$escaped_pane" > "$escaped_state/pane"
tmux display-message -p -t "$escaped_pane" \
  '#{pane_dead}|#{pane_id}|#{pane_pid}|#{pane_created}|#{pane_start_command}' \
  > "$escaped_state/pane_identity"
chmod 600 "$escaped_state/pane_identity"

# Wait for the escaped descendant's PID file to appear.
for _ in $(seq 1 200); do
  [[ -s "$TEST_ROOT/escaped.pid" ]] && break
  sleep 0.01
done
[[ -s "$TEST_ROOT/escaped.pid" ]]
escaped_pid="$(cat "$TEST_ROOT/escaped.pid")"

# Wait for the worker pane to exit (pane_dead=1) before running cleanup,
# so cleanup sees a dead pane — exactly the PR14-F2 scenario.
for _ in $(seq 1 200); do
  pane_dead_val="$(tmux display-message -p -t "$escaped_pane" '#{pane_dead}' 2>/dev/null || echo 1)"
  [[ "$pane_dead_val" != "0" ]] && break
  sleep 0.05
done
pane_dead_check="$(tmux display-message -p -t "$escaped_pane" '#{pane_dead}' 2>/dev/null || echo 1)"
if [[ "$pane_dead_check" == "0" ]]; then
  printf 'worker pane did not exit before cleanup — PR14-F2 scenario not reproduced\n' >&2
  exit 1
fi

# Verify escaped descendant is still alive before cleanup (reproduces the bug).
if ! kill -0 "$escaped_pid" 2>/dev/null; then
  printf 'escaped descendant exited before cleanup — PR14-F2 scenario not reproduced\n' >&2
  exit 1
fi

SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" escaped-task >/dev/null

# Escaped descendant must be terminated by cleanup.
if kill -0 "$escaped_pid" 2>/dev/null; then
  printf 'escaped descendant still running after cleanup: %s\n' "$escaped_pid" >&2
  exit 1
fi
# Unrelated session must survive.
tmux has-session -t "$TMUX_SESSION"
kill -0 "$unrelated_pid"
[[ ! -e "$escaped_worktree" ]]
[[ ! -e "$TEST_ROOT/fleet/escaped-task" ]]

printf 'sgt-cleanup worker termination: ok\n'
printf 'sgt-cleanup escaped-descendant termination (PR14-F2): ok\n'

# === _recover_escaped_worker_pgid safety guards ===
# AC4: blocked termination must preserve diagnostics and refuse destructive cleanup.

# --- Guard 1: PID reuse (start time mismatch) must block cleanup ---
# Use the test script's own PID as the "live" recorded worker PID, but
# write a deliberately wrong start time so the reuse check fires.
# Use a non-existent worktree path: _require_terminal_repos synthesizes
# terminal evidence from fleet state so the preflights pass, and the main
# loop still calls _stop_local_worker where the guard fires.
pid_reuse_state="$TEST_ROOT/fleet/pid-reuse-task/app"
pid_reuse_worktree="$TEST_ROOT/pid-reuse-missing-worktree"
mkdir -p "$pid_reuse_state"
# worktree path must NOT exist so _require_terminal_repos synthesizes evidence.
printf '%s\n' "$pid_reuse_worktree" > "$pid_reuse_state/worktree"
printf 'done\n' > "$pid_reuse_state/status"
printf 'result\n' > "$pid_reuse_state/result"
# pane that doesn't exist → hits "pane already gone" → calls _recover_escaped_worker_pgid
printf '%%99999\n' > "$pid_reuse_state/pane"
printf '%s\n' "$$" > "$pid_reuse_state/worker_pid"
printf '%s\n' "$$" > "$pid_reuse_state/worker_process_group"
printf 'stale start time mismatch\n' > "$pid_reuse_state/worker_process_start"

set +e
SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" pid-reuse-task > "$TEST_ROOT/pid-reuse.log" 2>&1
pid_reuse_status=$?
set -e
[[ "$pid_reuse_status" -ne 0 ]] || {
  printf 'cleanup accepted pid-reuse-task with stale start time\n' >&2; exit 1
}
grep -Fq 'Worker PID was reused' "$TEST_ROOT/pid-reuse.log" || {
  printf 'unexpected pid-reuse error: %s\n' "$(cat "$TEST_ROOT/pid-reuse.log")" >&2; exit 1
}
[[ -d "$pid_reuse_state" ]] || {
  printf 'fleet state was removed despite pid-reuse guard\n' >&2; exit 1
}

# --- Guard 2: non-group-leader with live group members must block cleanup ---
# Spawn a process in a new process group (setsid), giving us a live PGID.
# Record a different dead PID as worker_pid (not the group leader) so the
# non-group-leader guard fires.
nonleader_state="$TEST_ROOT/fleet/nonleader-task/app"
nonleader_worktree="$TEST_ROOT/nonleader-missing-worktree"
mkdir -p "$nonleader_state"
# worktree path must NOT exist — same synthesis approach as guard-1.
printf '%s\n' "$nonleader_worktree" > "$nonleader_state/worktree"
printf 'done\n' > "$nonleader_state/status"
printf 'result\n' > "$nonleader_state/result"
printf '%%99999\n' > "$nonleader_state/pane"
# Spawn a setsid group in the background; its PID == its PGID (it is the leader).
setsid bash -c "printf '%s\n' \"\$\$\" > \"$TEST_ROOT/setsid.pid\"; while :; do sleep 1; done" \
  &>/dev/null &
for _ in $(seq 1 100); do
  [[ -s "$TEST_ROOT/setsid.pid" ]] && break
  sleep 0.01
done
[[ -s "$TEST_ROOT/setsid.pid" ]]
setsid_pid="$(cat "$TEST_ROOT/setsid.pid")"
setsid_pgid="$(ps -o pgid= -p "$setsid_pid" 2>/dev/null | tr -d ' ')"
# Obtain a dead PID: spawn a short-lived subshell and capture its PID.
bash -c 'printf "%s\n" "$$"' > "$TEST_ROOT/dead.pid"
dead_pid="$(cat "$TEST_ROOT/dead.pid")"
# Ensure it's dead (it should be, but wait briefly).
for _ in $(seq 1 20); do
  kill -0 "$dead_pid" 2>/dev/null || break
  sleep 0.01
done
# worker_pid is the dead PID (not the setsid group leader), worker_process_group
# is the setsid group (has live members).  Since dead_pid != setsid_pgid, the
# non-group-leader guard must fire.
printf '%s\n' "$dead_pid"    > "$nonleader_state/worker_pid"
printf '%s\n' "$setsid_pgid" > "$nonleader_state/worker_process_group"
printf 'irrelevant\n'        > "$nonleader_state/worker_process_start"

set +e
SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" nonleader-task > "$TEST_ROOT/nonleader.log" 2>&1
nonleader_status=$?
set -e
# Clean up the setsid process regardless of outcome.
kill "$setsid_pid" 2>/dev/null || true
[[ "$nonleader_status" -ne 0 ]] || {
  printf 'cleanup accepted nonleader-task with unverified group descendants\n' >&2; exit 1
}
grep -Fq 'unverified detached descendants' "$TEST_ROOT/nonleader.log" || {
  printf 'unexpected nonleader error: %s\n' "$(cat "$TEST_ROOT/nonleader.log")" >&2; exit 1
}
[[ -d "$nonleader_state" ]] || {
  printf 'fleet state was removed despite non-group-leader guard\n' >&2; exit 1
}

printf 'sgt-cleanup escaped-descendant blocked-termination guards (PR14-F2 AC4): ok\n'
