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

  if [[ -d "$repo_root/.git" ]]; then
    rm -rf "$repo_root"
  fi
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

repo_owner_identity() {
  local common_dir common_identity marker token repo_root="$1"

  common_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir)"
  common_identity="$(stat -c '%d:%i' "$common_dir" 2>/dev/null || \
    stat -f '%d:%i' "$common_dir" 2>/dev/null)"
  marker="$common_dir/sergeant-instance"
  if [[ ! -e "$marker" ]]; then
    token="$(printf '%s\n%s\n%s\n%s\n' "$common_dir" "$$" "$RANDOM" "$(date +%s)" | \
      git hash-object --stdin)"
    printf '%s\n' "$token" > "$marker"
  fi
  token="$(cat "$marker")"
  printf '%s\n%s\n%s\n' "$common_dir" "$common_identity" "$token" | \
    git hash-object --stdin
}

worker_evidence_identity() {
  local evidence_dir="$1"

  (
    cd "$evidence_dir" || exit 1
    export LC_ALL=C
    for evidence in .sergeant-*; do
      [[ -f "$evidence" ]] || continue
      printf 'file\n%s\n' "$evidence"
      git hash-object "$evidence" || exit 1
    done
  ) | git hash-object --stdin
}

record_absent_cleanup_owner() {
  local evidence_dir="$6" repo_root="$3" repo_state="$TEST_ROOT/fleet/$1/$2" \
    task_id="$1" worktree="$4" wt_type="${5:-git}"
  local evidence_identity owner_identity

  owner_identity="$(repo_owner_identity "$repo_root")"
  evidence_identity="$(worker_evidence_identity "$evidence_dir")"
  printf '4\n%s\n%s\n%s\n%s\n%s\nabsent\n%s\n\n' \
    "$task_id" "$repo_root" "$worktree" "$wt_type" "$owner_identity" \
    "$evidence_identity" > "$repo_state/cleanup-owner"
  printf 'reconciled-absent\n%s\n' "$worktree" > "$repo_state/cleanup-phase"
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
init_test_repo "$TEST_ROOT/stale-dead-pane-repo"
git -C "$TEST_ROOT/stale-dead-pane-repo" worktree add -q -b stale-dead-pane-worker \
  "$TEST_ROOT/stale-dead-pane-sgt-stale-dead-pane"
record_retry_owner stale-dead-pane app "$TEST_ROOT/stale-dead-pane-repo"
printf '%s\n' "$TEST_ROOT/stale-dead-pane-sgt-stale-dead-pane" > "$stale_state/worktree"
printf 'git\n' > "$stale_state/wt_type"
printf 'done\n' > "$stale_state/status"
printf 'result\n' > "$stale_state/result"
printf 'done\n' > "$TEST_ROOT/stale-dead-pane-sgt-stale-dead-pane/.sergeant-status"
printf 'result\n' > "$TEST_ROOT/stale-dead-pane-sgt-stale-dead-pane/.sergeant-result"
# Run partial cleanup to get "removed" phase with absent worktree, then advance to reconciled-absent
SGT_CLEANUP_FAIL_POINT=phase-publish-reconciled-absent \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" stale-dead-pane >/dev/null 2>&1 || true
[[ "$(sed -n '1p' "$stale_state/cleanup-phase")" == "removed" ]]
[[ ! -d "$TEST_ROOT/stale-dead-pane-sgt-stale-dead-pane" ]]
# Advance to reconciled-absent (simulating a prior successful reconciliation)
worktree_path="$TEST_ROOT/stale-dead-pane-sgt-stale-dead-pane"
printf 'reconciled-absent\n%s\n' "$worktree_path" > "$stale_state/cleanup-phase"
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
SERGEANT_CONFIG="$TEST_ROOT/config" \
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

legacy_reconciled_state="$TEST_ROOT/fleet/legacy-reconciled-absent/app"
legacy_reconciled_worktree="$TEST_ROOT/legacy-reconciled-absent-worktree"
mkdir -p "$legacy_reconciled_state/terminal-evidence"
printf '%s\n' "$legacy_reconciled_worktree" > "$legacy_reconciled_state/worktree"
printf 'done\n' > "$legacy_reconciled_state/status"
printf 'result\n' > "$legacy_reconciled_state/result"
printf 'done\n' > "$legacy_reconciled_state/terminal-evidence/.sergeant-status"
printf 'result\n' > "$legacy_reconciled_state/terminal-evidence/.sergeant-result"
printf 'reconciled-absent\n%s\n' "$legacy_reconciled_worktree" > \
  "$legacy_reconciled_state/cleanup-phase"
legacy_reconciled_before="$(cksum "$legacy_reconciled_state/status" \
  "$legacy_reconciled_state/result" "$legacy_reconciled_state/worktree" \
  "$legacy_reconciled_state/cleanup-phase" \
  "$legacy_reconciled_state/terminal-evidence"/.sergeant-*)"
if SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" legacy-reconciled-absent >/dev/null 2>&1; then
  printf 'cleanup accepted ownerless reconciled-absent state\n' >&2
  exit 1
fi
[[ "$(cksum "$legacy_reconciled_state/status" \
  "$legacy_reconciled_state/result" "$legacy_reconciled_state/worktree" \
  "$legacy_reconciled_state/cleanup-phase" \
  "$legacy_reconciled_state/terminal-evidence"/.sergeant-*)" == \
  "$legacy_reconciled_before" ]]

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

response_state="$TEST_ROOT/fleet/response-complete/app"
response_worktree="$TEST_ROOT/response-complete-worktree"
response_archive="$response_state/response-archive/response-123"
mkdir -p "$response_archive"
init_test_repo "$TEST_ROOT/response-complete-repo"
git -C "$TEST_ROOT/response-complete-repo" worktree add -q -b response-complete-worker \
  "$response_worktree"
record_retry_owner response-complete app "$TEST_ROOT/response-complete-repo"
printf '%s\n' "$response_worktree" > "$response_state/worktree"
printf 'git\n' > "$response_state/wt_type"
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
printf 'response-123\n' > "$response_worktree/.sergeant-response-ack"
printf 'response-123\n' > "$response_state/response_ack"
SGT_CLEANUP_FAIL_POINT=phase-publish-reconciled-absent \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" response-complete >/dev/null 2>&1 || true
[[ "$(sed -n '1p' "$response_state/cleanup-phase")" == "removed" ]]
[[ ! -d "$response_worktree" ]]
SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" response-complete >/dev/null
[[ ! -e "$TEST_ROOT/fleet/response-complete" ]]

lock_state="$TEST_ROOT/fleet/response-lock/app"
lock_worktree="$TEST_ROOT/response-lock-worktree"
mkdir -p "$lock_state"
init_test_repo "$TEST_ROOT/response-lock-repo"
git -C "$TEST_ROOT/response-lock-repo" worktree add -q -b response-lock-worker \
  "$lock_worktree"
record_retry_owner response-lock app "$TEST_ROOT/response-lock-repo"
printf '%s\n' "$lock_worktree" > "$lock_state/worktree"
printf 'git\n' > "$lock_state/wt_type"
printf 'done\n' > "$lock_state/status"
printf 'result\n' > "$lock_state/result"
printf 'done\n' > "$lock_worktree/.sergeant-status"
printf 'result\n' > "$lock_worktree/.sergeant-result"
SGT_CLEANUP_FAIL_POINT=phase-publish-reconciled-absent \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" response-lock >/dev/null 2>&1 || true
[[ "$(sed -n '1p' "$lock_state/cleanup-phase")" == "removed" ]]
[[ ! -d "$lock_worktree" ]]
printf 'invalid-owner\n' > "$lock_state/response.lock"
set +e
SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" response-lock > "$TEST_ROOT/response-lock.log" 2>&1
lock_status=$?
set -e
[[ "$lock_status" -ne 0 ]]
grep -Fq 'Response lock has an invalid owner' "$TEST_ROOT/response-lock.log"
[[ -d "$lock_state" ]]

legacy_reconciled_state="$TEST_ROOT/fleet/legacy-reconciled-absent/app"
legacy_reconciled_worktree="$TEST_ROOT/legacy-reconciled-absent-worktree"
mkdir -p "$legacy_reconciled_state/terminal-evidence"
printf '%s\n' "$legacy_reconciled_worktree" > "$legacy_reconciled_state/worktree"
printf 'done\n' > "$legacy_reconciled_state/status"
printf 'result\n' > "$legacy_reconciled_state/result"
printf 'done\n' > "$legacy_reconciled_state/terminal-evidence/.sergeant-status"
printf 'result\n' > "$legacy_reconciled_state/terminal-evidence/.sergeant-result"
printf 'reconciled-absent\n%s\n' "$legacy_reconciled_worktree" > \
  "$legacy_reconciled_state/cleanup-phase"
legacy_reconciled_before="$(cksum "$legacy_reconciled_state/status" \
  "$legacy_reconciled_state/result" "$legacy_reconciled_state/worktree" \
  "$legacy_reconciled_state/cleanup-phase" \
  "$legacy_reconciled_state/terminal-evidence"/.sergeant-*)"
if SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" legacy-reconciled-absent >/dev/null 2>&1; then
  printf 'cleanup accepted ownerless reconciled-absent state\n' >&2
  exit 1
fi
[[ "$(cksum "$legacy_reconciled_state/status" \
  "$legacy_reconciled_state/result" "$legacy_reconciled_state/worktree" \
  "$legacy_reconciled_state/cleanup-phase" \
  "$legacy_reconciled_state/terminal-evidence"/.sergeant-*)" == \
  "$legacy_reconciled_before" ]]

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


mkdir -p "$TEST_ROOT/fleet/absent-missing-record/app"
printf 'done\n' > "$TEST_ROOT/fleet/absent-missing-record/app/status"
printf 'result\n' > "$TEST_ROOT/fleet/absent-missing-record/app/result"
SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" absent-missing-record \
    > "$TEST_ROOT/absent-missing-record.log" 2>&1
[[ ! -e "$TEST_ROOT/fleet/absent-missing-record" ]]

# pre-existing: worktree recorded but externally removed — cleanup should succeed
# (no cleanup-phase means the worktree was externally removed; allow cleanup).
mkdir -p "$TEST_ROOT/fleet/absent-pre-existing/app"
printf 'done\n' > "$TEST_ROOT/fleet/absent-pre-existing/app/status"
printf 'result\n' > "$TEST_ROOT/fleet/absent-pre-existing/app/result"
printf '%s\n' "$TEST_ROOT/absent-worktree" > "$TEST_ROOT/fleet/absent-pre-existing/app/worktree"
SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" absent-pre-existing \
    > "$TEST_ROOT/absent-pre-existing.log" 2>&1
[[ ! -e "$TEST_ROOT/fleet/absent-pre-existing" ]]

mkdir -p "$TEST_ROOT/fleet/no-worktree-failed/app"
printf 'failed: dispatch incomplete: no worktree or owned live pane\n' > \
  "$TEST_ROOT/fleet/no-worktree-failed/app/status"
printf 'dispatch never acquired a worktree or owned live pane\n' > \
  "$TEST_ROOT/fleet/no-worktree-failed/app/diagnostic"
SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" no-worktree-failed >/dev/null
[[ ! -e "$TEST_ROOT/fleet/no-worktree-failed" ]]

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

mkdir -p "$TEST_ROOT/fleet/unowned-worktree/app" "$TEST_ROOT/fake-bin"
init_test_repo "$TEST_ROOT/unowned-configured"
init_test_repo "$TEST_ROOT/unowned-other"
git -C "$TEST_ROOT/unowned-other" worktree add -q -b unowned-worker \
  "$TEST_ROOT/unowned-worker"
record_retry_owner unowned-worktree app "$TEST_ROOT/unowned-configured"
printf '%s\n' "$TEST_ROOT/unowned-worker" > \
  "$TEST_ROOT/fleet/unowned-worktree/app/worktree"
printf 'done\n' > "$TEST_ROOT/fleet/unowned-worktree/app/status"
printf 'result\n' > "$TEST_ROOT/fleet/unowned-worktree/app/result"
printf 'done\n' > "$TEST_ROOT/unowned-worker/.sergeant-status"
printf 'result\n' > "$TEST_ROOT/unowned-worker/.sergeant-result"
cat > "$TEST_ROOT/fake-bin/git" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" worktree remove "*) printf '%s\n' "${!#}" >> "$FAKE_GIT_LOG" ;;
esac
"$REAL_GIT" "$@"
EOF
chmod +x "$TEST_ROOT/fake-bin/git"
if PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_GIT_LOG="$TEST_ROOT/unowned-removals" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" unowned-worktree app >/dev/null 2>&1; then
  printf 'cleanup accepted a worktree owned by an unrelated repository\n' >&2
  exit 1
fi
[[ -d "$TEST_ROOT/unowned-worker" ]]
[[ ! -e "$TEST_ROOT/unowned-removals" ]]
[[ ! -e "$TEST_ROOT/fleet/unowned-worktree/app/terminal-evidence" ]]
[[ ! -e "$TEST_ROOT/fleet/unowned-worktree/app/cleanup-owner" ]]
[[ ! -e "$TEST_ROOT/fleet/unowned-worktree/app/cleanup-phase" ]]
[[ ! -e "$TEST_ROOT/unowned-configured/.git/sergeant-instance" ]]

git -C "$TEST_ROOT/unowned-configured" worktree add -q -b owned-worker \
  "$TEST_ROOT/owned-worker"
printf '%s\n' "$TEST_ROOT/owned-worker" > \
  "$TEST_ROOT/fleet/unowned-worktree/app/worktree"
printf 'done\n' > "$TEST_ROOT/owned-worker/.sergeant-status"
printf 'result\n' > "$TEST_ROOT/owned-worker/.sergeant-result"
PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_GIT_LOG="$TEST_ROOT/owned-removals" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" unowned-worktree app >/dev/null
[[ ! -e "$TEST_ROOT/owned-worker" ]]
[[ "$(cat "$TEST_ROOT/owned-removals")" == "$TEST_ROOT/owned-worker" ]]
rm "$TEST_ROOT/fake-bin/git"

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
git -C "$TEST_ROOT/removal-success" worktree add -q -b removal-success-worker \
  "$TEST_ROOT/removal-success-sgt-removal-failure"
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
git -C "$TEST_ROOT/removal-failure" worktree add -q -b removal-failure-worker \
  "$TEST_ROOT/removal-failure-sgt-removal-failure"
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
  *" rev-list "*|*" for-each-ref "*|*" config --get remote.origin.url "*|*" status --porcelain=v1 "*|*" diff "*|*" ls-files "*|*" hash-object "*|*" check-ref-format "*|*" worktree list --porcelain -z "*) "$REAL_GIT" "$@" ;;
  *" rev-parse --is-inside-work-tree "*) printf 'true\n' ;;
  *" rev-parse "*) "$REAL_GIT" "$@" ;;
  *" status "*) ;;
  *" worktree list --porcelain -z "*) "$REAL_GIT" "$@" ;;
  *" worktree remove "*)
    worktree="${!#}"
    printf '%s\n' "$worktree" >> "$FAKE_GIT_LOG"
    if [[ "$worktree" == *removal-success* ]]; then
      "$REAL_GIT" "$@"
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
[[ "$(cat "$TEST_ROOT/fleet/removal-failure/app/cleanup-phase")" == \
  $'partial-removal\n'"$TEST_ROOT/removal-failure-sgt-removal-failure"$'\ngit\n'"$TEST_ROOT/removal-failure" ]]
[[ "$(wc -l < "$TEST_ROOT/git-removals")" -eq 2 ]]
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
mv "$TEST_ROOT/config/removal-failure.yaml" \
  "$TEST_ROOT/config/removal-failure.yaml.saved"
assert_retry_owner_rejected 'missing current project config'
mv "$TEST_ROOT/config/removal-failure.yaml.saved" \
  "$TEST_ROOT/config/removal-failure.yaml"
registered_owner_before="$(cksum \
  "$TEST_ROOT/fleet/removal-failure/app/cleanup-owner")"
registered_phase_before="$(cksum \
  "$TEST_ROOT/fleet/removal-failure/app/cleanup-phase")"
registered_evidence_before="$(cksum \
  "$TEST_ROOT/fleet/removal-failure/app/terminal-evidence"/.sergeant-*)"
if PATH="$TEST_ROOT/fake-bin:$PATH" FAKE_GIT_STATE="$TEST_ROOT/git-failed-once" \
  FAKE_GIT_LOG="$TEST_ROOT/git-removals" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" removal-failure >/dev/null 2>&1; then
  printf 'cleanup reconciled an absent but registered git worktree\n' >&2
  exit 1
fi
[[ "$(wc -l < "$TEST_ROOT/git-removals")" -eq 2 ]]
[[ "$(cksum "$TEST_ROOT/fleet/removal-failure/app/cleanup-owner")" == \
  "$registered_owner_before" ]]
[[ "$(cksum "$TEST_ROOT/fleet/removal-failure/app/cleanup-phase")" == \
  "$registered_phase_before" ]]
[[ "$(cksum \
  "$TEST_ROOT/fleet/removal-failure/app/terminal-evidence"/.sergeant-*)" == \
  "$registered_evidence_before" ]]
printf 'removed\n%s\ngit\n%s\n' \
  "$TEST_ROOT/removal-failure-sgt-removal-failure" \
  "$TEST_ROOT/removal-failure" > \
  "$TEST_ROOT/fleet/removal-failure/app/cleanup-phase"
removed_owner_before="$(cksum \
  "$TEST_ROOT/fleet/removal-failure/app/cleanup-owner")"
removed_phase_before="$(cksum \
  "$TEST_ROOT/fleet/removal-failure/app/cleanup-phase")"
removed_evidence_before="$(cksum \
  "$TEST_ROOT/fleet/removal-failure/app/terminal-evidence"/.sergeant-*)"
if PATH="$TEST_ROOT/fake-bin:$PATH" FAKE_GIT_STATE="$TEST_ROOT/git-failed-once" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" removal-failure >/dev/null 2>&1; then
  printf 'cleanup trusted a removed marker for a registered git worktree\n' >&2
  exit 1
fi
[[ "$(cksum "$TEST_ROOT/fleet/removal-failure/app/cleanup-owner")" == \
  "$removed_owner_before" ]]
[[ "$(cksum "$TEST_ROOT/fleet/removal-failure/app/cleanup-phase")" == \
  "$removed_phase_before" ]]
[[ "$(cksum \
  "$TEST_ROOT/fleet/removal-failure/app/terminal-evidence"/.sergeant-*)" == \
  "$removed_evidence_before" ]]
"$REAL_GIT" -C "$TEST_ROOT/removal-failure" worktree prune --expire now
PATH="$TEST_ROOT/fake-bin:$PATH" FAKE_GIT_STATE="$TEST_ROOT/git-failed-once" \
  FAKE_GIT_LOG="$TEST_ROOT/git-removals" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" removal-failure >/dev/null
[[ "$(wc -l < "$TEST_ROOT/git-removals")" -eq 2 ]]
[[ ! -e "$TEST_ROOT/fleet/removal-failure" ]]

rm "$TEST_ROOT/fake-bin/git"

mkdir -p "$TEST_ROOT/fleet/present-retry/app" \
  "$TEST_ROOT/fake-bin"
init_test_repo "$TEST_ROOT/present-retry"
printf 'second fixture\n' >> "$TEST_ROOT/present-retry/README.md"
git -C "$TEST_ROOT/present-retry" add README.md
git -C "$TEST_ROOT/present-retry" commit -qm 'second fixture'
git -C "$TEST_ROOT/present-retry" worktree add -q -b present-retry-worker \
  "$TEST_ROOT/present-retry-sgt-present-retry"
record_retry_owner present-retry app "$TEST_ROOT/present-retry"
printf '%s\n' "$TEST_ROOT/present-retry-sgt-present-retry" > \
  "$TEST_ROOT/fleet/present-retry/app/worktree"
printf 'done\n' > "$TEST_ROOT/fleet/present-retry/app/status"
printf 'result\n' > "$TEST_ROOT/fleet/present-retry/app/result"
printf 'done\n' > "$TEST_ROOT/present-retry-sgt-present-retry/.sergeant-status"
printf 'result\n' > "$TEST_ROOT/present-retry-sgt-present-retry/.sergeant-result"
cat > "$TEST_ROOT/fake-bin/git" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" rev-list "*|*" for-each-ref "*|*" config --get remote.origin.url "*|*" status --porcelain=v1 "*|*" diff "*|*" ls-files "*|*" hash-object "*|*" check-ref-format "*|*" worktree list --porcelain -z "*) "$REAL_GIT" "$@" ;;
  *" rev-parse --is-inside-work-tree "*) printf 'true\n' ;;
  *" rev-parse "*) "$REAL_GIT" "$@" ;;
  *" status "*) ;;
  *" check-ref-format "*|*" worktree list --porcelain -z "*) "$REAL_GIT" "$@" ;;
  *" worktree remove "*)
    printf '%s\n' "${!#}" >> "$FAKE_GIT_LOG"
    if [[ -e "${FAKE_GIT_ALLOW:-}" ]]; then
      "$REAL_GIT" "$@"
      exit $?
    fi
    exit 1
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/git"
if PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_GIT_LOG="$TEST_ROOT/present-retry-removals" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" present-retry >/dev/null 2>&1; then
  printf 'cleanup succeeded after present-worktree removal failed\n' >&2
  exit 1
fi
[[ "$(wc -l < "$TEST_ROOT/present-retry-removals")" -eq 1 ]]
present_owner_before="$(cksum "$TEST_ROOT/fleet/present-retry/app/cleanup-owner")"
present_phase_before="$(cksum "$TEST_ROOT/fleet/present-retry/app/cleanup-phase")"
present_evidence_before="$(cksum \
  "$TEST_ROOT/fleet/present-retry/app/terminal-evidence"/.sergeant-*)"

rm "$TEST_ROOT/present-retry-sgt-present-retry"/.sergeant-*
printf 'changed fleet result\n' > "$TEST_ROOT/fleet/present-retry/app/result"
if PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_GIT_LOG="$TEST_ROOT/present-retry-removals" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" present-retry >/dev/null 2>&1; then
  printf 'cleanup accepted changed fleet result during retry preflight\n' >&2
  exit 1
fi
[[ ! -e "$TEST_ROOT/present-retry-sgt-present-retry/.sergeant-status" ]]
[[ ! -e "$TEST_ROOT/present-retry-sgt-present-retry/.sergeant-result" ]]
[[ "$(wc -l < "$TEST_ROOT/present-retry-removals")" -eq 1 ]]
printf 'result\n' > "$TEST_ROOT/fleet/present-retry/app/result"
if PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_GIT_LOG="$TEST_ROOT/present-retry-removals" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" present-retry >/dev/null 2>&1; then
  printf 'cleanup unexpectedly succeeded during crash-window retry\n' >&2
  exit 1
fi
[[ "$(wc -l < "$TEST_ROOT/present-retry-removals")" -eq 2 ]] || {
  printf 'cleanup did not reach the remover after absent evidence replay\n' >&2
  exit 1
}
for evidence in .sergeant-status .sergeant-result; do
  cmp -s "$TEST_ROOT/fleet/present-retry/app/terminal-evidence/$evidence" \
    "$TEST_ROOT/present-retry-sgt-present-retry/$evidence" || {
    printf 'cleanup did not restore validated absent evidence: %s\n' "$evidence" >&2
    exit 1
  }
done
[[ "$(cksum "$TEST_ROOT/fleet/present-retry/app/cleanup-owner")" == \
  "$present_owner_before" ]]
[[ "$(cksum "$TEST_ROOT/fleet/present-retry/app/cleanup-phase")" == \
  "$present_phase_before" ]]
[[ "$(cksum "$TEST_ROOT/fleet/present-retry/app/terminal-evidence"/.sergeant-*)" == \
  "$present_evidence_before" ]]
[[ "$(sed -n '1p' "$TEST_ROOT/fleet/present-retry/app/cleanup-owner")" == "4" ]]

assert_present_worker_identity_rejected() {
  local label="$1" output status worktree_evidence_before

  worktree_evidence_before="$(cksum \
    "$TEST_ROOT/present-retry-sgt-present-retry"/.sergeant-*)"
  set +e
  output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
    FAKE_GIT_LOG="$TEST_ROOT/present-retry-removals" \
    SERGEANT_CONFIG="$TEST_ROOT/config" \
    SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-cleanup" present-retry 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || {
    printf 'cleanup accepted changed worker worktree identity: %s\n' "$label" >&2
    exit 1
  }
  [[ "$output" == *"Retry worker"* ]] || {
    printf 'cleanup returned an unexpected worker identity error for %s: %s\n' \
      "$label" "$output" >&2
    exit 1
  }
  [[ "$(wc -l < "$TEST_ROOT/present-retry-removals")" -eq 2 ]]
  [[ "$(cksum "$TEST_ROOT/fleet/present-retry/app/cleanup-owner")" == \
    "$present_owner_before" ]]
  [[ "$(cksum "$TEST_ROOT/fleet/present-retry/app/cleanup-phase")" == \
    "$present_phase_before" ]]
  [[ "$(cksum "$TEST_ROOT/fleet/present-retry/app/terminal-evidence"/.sergeant-*)" == \
    "$present_evidence_before" ]]
  [[ "$(cksum "$TEST_ROOT/present-retry-sgt-present-retry"/.sergeant-*)" == \
    "$worktree_evidence_before" ]]
}

assert_present_persisted_evidence_rejected() {
  local evidence_before label="$1" output status worktree_evidence_before

  evidence_before="$(cksum \
    "$TEST_ROOT/fleet/present-retry/app/terminal-evidence"/.sergeant-*)"
  worktree_evidence_before="$(cksum \
    "$TEST_ROOT/present-retry-sgt-present-retry"/.sergeant-*)"
  set +e
  output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
    FAKE_GIT_LOG="$TEST_ROOT/present-retry-removals" \
    SERGEANT_CONFIG="$TEST_ROOT/config" \
    SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-cleanup" present-retry 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 && "$output" == *"persisted terminal evidence"* ]] || {
    printf 'cleanup accepted invalid persisted evidence for %s: %s\n' \
      "$label" "$output" >&2
    exit 1
  }
  [[ "$(wc -l < "$TEST_ROOT/present-retry-removals")" -eq 2 ]]
  [[ "$(cksum "$TEST_ROOT/fleet/present-retry/app/cleanup-owner")" == \
    "$present_owner_before" ]]
  [[ "$(cksum "$TEST_ROOT/fleet/present-retry/app/cleanup-phase")" == \
    "$present_phase_before" ]]
  [[ "$(cksum "$TEST_ROOT/fleet/present-retry/app/terminal-evidence"/.sergeant-*)" == \
    "$evidence_before" ]]
  [[ "$(cksum "$TEST_ROOT/present-retry-sgt-present-retry"/.sergeant-*)" == \
    "$worktree_evidence_before" ]]
}

printf 'tampered persisted result\n' > \
  "$TEST_ROOT/fleet/present-retry/app/terminal-evidence/.sergeant-result"
assert_present_persisted_evidence_rejected 'tampered manifest member'
cp -p "$TEST_ROOT/present-retry-sgt-present-retry/.sergeant-result" \
  "$TEST_ROOT/fleet/present-retry/app/terminal-evidence/.sergeant-result"
rm "$TEST_ROOT/fleet/present-retry/app/terminal-evidence/.sergeant-result"
assert_present_persisted_evidence_rejected 'partial manifest'
cp -p "$TEST_ROOT/present-retry-sgt-present-retry/.sergeant-result" \
  "$TEST_ROOT/fleet/present-retry/app/terminal-evidence/.sergeant-result"

rm "$TEST_ROOT/present-retry-sgt-present-retry/.sergeant-result"
assert_present_worker_identity_rejected 'partial live evidence'
cp -p "$TEST_ROOT/fleet/present-retry/app/terminal-evidence/.sergeant-result" \
  "$TEST_ROOT/present-retry-sgt-present-retry/.sergeant-result"

init_test_repo "$TEST_ROOT/present-retry-other"
for reappeared_phase in partial-removal removed reconciled-absent; do
  if [[ "$reappeared_phase" == "reconciled-absent" ]]; then
    printf '%s\n%s\n' "$reappeared_phase" \
      "$TEST_ROOT/present-retry-sgt-present-retry" > \
      "$TEST_ROOT/fleet/present-retry/app/cleanup-phase"
  else
    printf '%s\n%s\ngit\n%s\n' "$reappeared_phase" \
      "$TEST_ROOT/present-retry-sgt-present-retry" "$TEST_ROOT/present-retry" > \
      "$TEST_ROOT/fleet/present-retry/app/cleanup-phase"
  fi
  reappeared_owner_before="$(cksum \
    "$TEST_ROOT/fleet/present-retry/app/cleanup-owner")"
  reappeared_phase_before="$(cksum \
    "$TEST_ROOT/fleet/present-retry/app/cleanup-phase")"
  reappeared_terminal_before="$(cksum \
    "$TEST_ROOT/fleet/present-retry/app/terminal-evidence"/.sergeant-*)"
  reappeared_current_before="$(cksum \
    "$TEST_ROOT/present-retry-sgt-present-retry"/.sergeant-*)"
  cat > "$TEST_ROOT/config/present-retry.yaml" <<EOF
name: present-retry
repos:
  - name: app
    path: $TEST_ROOT/present-retry-other
EOF
  if PATH="$TEST_ROOT/fake-bin:$PATH" \
    FAKE_GIT_LOG="$TEST_ROOT/present-retry-removals" \
    SERGEANT_CONFIG="$TEST_ROOT/config" \
    SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-cleanup" present-retry \
      > "$TEST_ROOT/reappeared-$reappeared_phase-owner.log" 2>&1; then
    printf 'cleanup skipped owner validation during %s replay\n' \
      "$reappeared_phase" >&2
    exit 1
  fi
  grep -Fq 'Configured retry owner changed: app' \
    "$TEST_ROOT/reappeared-$reappeared_phase-owner.log"
  record_retry_owner present-retry app "$TEST_ROOT/present-retry"
  if [[ "$reappeared_phase" == "reconciled-absent" ]]; then
    printf 'other\n' > "$TEST_ROOT/fleet/present-retry/app/wt_type"
    if PATH="$TEST_ROOT/fake-bin:$PATH" \
      FAKE_GIT_LOG="$TEST_ROOT/present-retry-removals" \
      SERGEANT_CONFIG="$TEST_ROOT/config" \
      SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
      "$ROOT_DIR/bin/sgt-cleanup" present-retry \
        > "$TEST_ROOT/reappeared-$reappeared_phase-type.log" 2>&1; then
      printf 'cleanup accepted type drift during %s replay\n' \
        "$reappeared_phase" >&2
      exit 1
    fi
    grep -Fq 'Unsupported worktree removal type: app: other' \
      "$TEST_ROOT/reappeared-$reappeared_phase-type.log"
    [[ "$(wc -l < "$TEST_ROOT/present-retry-removals")" -eq 2 ]]
    printf 'git\n' > "$TEST_ROOT/fleet/present-retry/app/wt_type"
  fi
  if PATH="$TEST_ROOT/fake-bin:$PATH" \
    FAKE_GIT_LOG="$TEST_ROOT/present-retry-removals" \
    SERGEANT_CONFIG="$TEST_ROOT/config" \
    SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-cleanup" present-retry \
      > "$TEST_ROOT/reappeared-$reappeared_phase.log" 2>&1; then
    printf 'cleanup accepted a worktree reappearing during %s\n' \
      "$reappeared_phase" >&2
    exit 1
  fi
  grep -Fq 'Previously removed worktree reappeared: app' \
    "$TEST_ROOT/reappeared-$reappeared_phase.log"
  [[ "$(wc -l < "$TEST_ROOT/present-retry-removals")" -eq 2 ]]
  [[ "$(cksum "$TEST_ROOT/fleet/present-retry/app/cleanup-owner")" == \
    "$reappeared_owner_before" ]]
  [[ "$(cksum "$TEST_ROOT/fleet/present-retry/app/cleanup-phase")" == \
    "$reappeared_phase_before" ]]
  [[ "$(cksum "$TEST_ROOT/fleet/present-retry/app/terminal-evidence"/.sergeant-*)" == \
    "$reappeared_terminal_before" ]]
  [[ "$(cksum "$TEST_ROOT/present-retry-sgt-present-retry"/.sergeant-*)" == \
    "$reappeared_current_before" ]]
done
printf 'removing\n%s\ngit\n%s\n' \
  "$TEST_ROOT/present-retry-sgt-present-retry" "$TEST_ROOT/present-retry" > \
  "$TEST_ROOT/fleet/present-retry/app/cleanup-phase"
present_worker_git_dir="$(git -C \
  "$TEST_ROOT/present-retry-sgt-present-retry" rev-parse --path-format=absolute --git-dir)"
printf '[fixture]\n\tworkerMetadata = changed\n' > \
  "$present_worker_git_dir/config.worktree"
assert_present_worker_identity_rejected 'linked-worktree metadata drift'
rm "$present_worker_git_dir/config.worktree"

present_worker_stage_before="$(git -C \
  "$TEST_ROOT/present-retry-sgt-present-retry" ls-files --stage -- README.md)"
present_worker_content_before="$(cksum \
  "$TEST_ROOT/present-retry-sgt-present-retry/README.md")"
cp -p "$present_worker_git_dir/index" "$TEST_ROOT/present-worker-index"
git -C "$TEST_ROOT/present-retry-sgt-present-retry" update-index \
  --assume-unchanged README.md
if cmp -s "$TEST_ROOT/present-worker-index" "$present_worker_git_dir/index"; then
  printf 'assume-unchanged did not change the raw worker index\n' >&2
  exit 1
fi
[[ "$(git -C "$TEST_ROOT/present-retry-sgt-present-retry" \
  ls-files --stage -- README.md)" == "$present_worker_stage_before" ]]
[[ "$(cksum "$TEST_ROOT/present-retry-sgt-present-retry/README.md")" == \
  "$present_worker_content_before" ]]
assert_present_worker_identity_rejected 'linked-worktree raw index flag drift'
cp -p "$TEST_ROOT/present-worker-index" "$present_worker_git_dir/index"

git -C "$TEST_ROOT/present-retry-sgt-present-retry" checkout -q --detach HEAD^
assert_present_worker_identity_rejected 'HEAD drift'
git -C "$TEST_ROOT/present-retry-sgt-present-retry" checkout -q present-retry-worker

# Tag additions change refs in the common git dir, not the per-worktree git
# dir.  Stable identity intentionally excludes all-refs (which changes on
# every git fetch), so local tag drift no longer invalidates a retry.
git -C "$TEST_ROOT/present-retry-sgt-present-retry" tag worker-ref-drift
git -C "$TEST_ROOT/present-retry-sgt-present-retry" tag -d worker-ref-drift >/dev/null

printf 'changed worker contents\n' >> \
  "$TEST_ROOT/present-retry-sgt-present-retry/README.md"
assert_present_worker_identity_rejected 'content drift'
git -C "$TEST_ROOT/present-retry-sgt-present-retry" checkout -q -- README.md

printf 'replacement evidence\n' > \
  "$TEST_ROOT/present-retry-sgt-present-retry/.sergeant-result"
assert_present_worker_identity_rejected 'evidence replacement'
printf 'result\n' > "$TEST_ROOT/present-retry-sgt-present-retry/.sergeant-result"

mv "$TEST_ROOT/present-retry-sgt-present-retry" \
  "$TEST_ROOT/present-retry-sgt-present-retry-original"
mkdir "$TEST_ROOT/present-retry-sgt-present-retry"
printf 'done\n' > "$TEST_ROOT/present-retry-sgt-present-retry/.sergeant-status"
printf 'result\n' > "$TEST_ROOT/present-retry-sgt-present-retry/.sergeant-result"
assert_present_worker_identity_rejected 'worktree replacement'
rm -rf "$TEST_ROOT/present-retry-sgt-present-retry"
mv "$TEST_ROOT/present-retry-sgt-present-retry-original" \
  "$TEST_ROOT/present-retry-sgt-present-retry"

present_worktree_evidence_before="$(cksum \
  "$TEST_ROOT/present-retry-sgt-present-retry"/.sergeant-*)"
git -C "$TEST_ROOT/present-retry" config sergeant.fixture changed
if PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_GIT_LOG="$TEST_ROOT/present-retry-removals" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" present-retry >/dev/null 2>&1; then
  printf 'cleanup accepted changed owner on present-worktree retry\n' >&2
  exit 1
fi
[[ "$(wc -l < "$TEST_ROOT/present-retry-removals")" -eq 2 ]]
[[ "$(cksum "$TEST_ROOT/fleet/present-retry/app/cleanup-owner")" == \
  "$present_owner_before" ]]
[[ "$(cksum "$TEST_ROOT/fleet/present-retry/app/cleanup-phase")" == \
  "$present_phase_before" ]]
[[ "$(cksum "$TEST_ROOT/fleet/present-retry/app/terminal-evidence"/.sergeant-*)" == \
  "$present_evidence_before" ]]
[[ "$(cksum "$TEST_ROOT/present-retry-sgt-present-retry"/.sergeant-*)" == \
  "$present_worktree_evidence_before" ]]
git -C "$TEST_ROOT/present-retry" config --unset sergeant.fixture
cat > "$TEST_ROOT/config/present-retry.yaml" <<EOF
name: present-retry
repos:
  - name: app
    path: $TEST_ROOT/present-retry-other
EOF
if PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_GIT_LOG="$TEST_ROOT/present-retry-removals" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" present-retry >/dev/null 2>&1; then
  printf 'cleanup accepted configured root drift on present-worktree retry\n' >&2
  exit 1
fi
[[ "$(wc -l < "$TEST_ROOT/present-retry-removals")" -eq 2 ]]
[[ "$(cksum "$TEST_ROOT/fleet/present-retry/app/cleanup-owner")" == \
  "$present_owner_before" ]]
[[ "$(cksum "$TEST_ROOT/fleet/present-retry/app/cleanup-phase")" == \
  "$present_phase_before" ]]
[[ "$(cksum "$TEST_ROOT/fleet/present-retry/app/terminal-evidence"/.sergeant-*)" == \
  "$present_evidence_before" ]]
[[ "$(cksum "$TEST_ROOT/present-retry-sgt-present-retry"/.sergeant-*)" == \
  "$present_worktree_evidence_before" ]]
record_retry_owner present-retry app "$TEST_ROOT/present-retry"
printf 'other\n' > "$TEST_ROOT/fleet/present-retry/app/wt_type"
if PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_GIT_LOG="$TEST_ROOT/present-retry-removals" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" present-retry >/dev/null 2>&1; then
  printf 'cleanup accepted removal-type drift on present-worktree retry\n' >&2
  exit 1
fi
[[ "$(wc -l < "$TEST_ROOT/present-retry-removals")" -eq 2 ]]
[[ "$(cksum "$TEST_ROOT/fleet/present-retry/app/cleanup-owner")" == \
  "$present_owner_before" ]]
[[ "$(cksum "$TEST_ROOT/fleet/present-retry/app/cleanup-phase")" == \
  "$present_phase_before" ]]
[[ "$(cksum "$TEST_ROOT/fleet/present-retry/app/terminal-evidence"/.sergeant-*)" == \
  "$present_evidence_before" ]]
[[ "$(cksum "$TEST_ROOT/present-retry-sgt-present-retry"/.sergeant-*)" == \
  "$present_worktree_evidence_before" ]]
cp -p "$TEST_ROOT/fleet/present-retry/app/cleanup-owner" \
  "$TEST_ROOT/present-retry-cleanup-owner"
cp -p "$TEST_ROOT/fleet/present-retry/app/cleanup-phase" \
  "$TEST_ROOT/present-retry-cleanup-phase"
{
  sed -n '1,4p' "$TEST_ROOT/present-retry-cleanup-owner"
  printf 'other\n'
  sed -n '6,9p' "$TEST_ROOT/present-retry-cleanup-owner"
} > "$TEST_ROOT/fleet/present-retry/app/cleanup-owner"
printf 'removing\n%s\nother\n%s\n' \
  "$TEST_ROOT/present-retry-sgt-present-retry" "$TEST_ROOT/present-retry" > \
  "$TEST_ROOT/fleet/present-retry/app/cleanup-phase"
if PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_GIT_LOG="$TEST_ROOT/present-retry-removals" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" present-retry >/dev/null 2>&1; then
  printf 'cleanup accepted matching unknown removal type\n' >&2
  exit 1
fi
[[ "$(wc -l < "$TEST_ROOT/present-retry-removals")" -eq 2 ]]
mv "$TEST_ROOT/present-retry-cleanup-owner" \
  "$TEST_ROOT/fleet/present-retry/app/cleanup-owner"
mv "$TEST_ROOT/present-retry-cleanup-phase" \
  "$TEST_ROOT/fleet/present-retry/app/cleanup-phase"
printf 'git\n' > "$TEST_ROOT/fleet/present-retry/app/wt_type"
rm "$TEST_ROOT/fake-bin/git"

# Regression for td-777c21: configured repo whose .git is a file (linked worktree)
# must be accepted by cleanup-owner identity validation during retry.
# Prior to the fix, _repo_git_dir required .git to be a directory and rejected linked
# worktrees at cleanup-owner recording and validation time.
mkdir -p "$TEST_ROOT/fleet/linked-retry/app" \
  "$TEST_ROOT/linked-retry-sgt-linked-retry"
init_test_repo "$TEST_ROOT/linked-retry-main"
git -C "$TEST_ROOT/linked-retry-main" worktree add -q -b linked-retry-configured \
  "$TEST_ROOT/linked-retry"
# Guard: .git must be a file (the linked-worktree pointer), not a directory.
[[ -f "$TEST_ROOT/linked-retry/.git" ]]
[[ ! -d "$TEST_ROOT/linked-retry/.git" ]]
record_retry_owner linked-retry app "$TEST_ROOT/linked-retry"
git -C "$TEST_ROOT/linked-retry" worktree add -q -b linked-retry-worker \
  "$TEST_ROOT/linked-retry-sgt-linked-retry"
printf '%s\n' "$TEST_ROOT/linked-retry-sgt-linked-retry" > \
  "$TEST_ROOT/fleet/linked-retry/app/worktree"
printf 'done\n' > "$TEST_ROOT/fleet/linked-retry/app/status"
printf 'result\n' > "$TEST_ROOT/fleet/linked-retry/app/result"
printf 'done\n' > "$TEST_ROOT/linked-retry-sgt-linked-retry/.sergeant-status"
printf 'result\n' > "$TEST_ROOT/linked-retry-sgt-linked-retry/.sergeant-result"
cat > "$TEST_ROOT/fake-bin/git" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" rev-list "*|*" for-each-ref "*|*" config --get remote.origin.url "*|*" status --porcelain=v1 "*|*" diff "*|*" ls-files "*|*" hash-object "*|*" check-ref-format "*|*" worktree list --porcelain -z "*) "$REAL_GIT" "$@" ;;
  *" rev-parse --is-inside-work-tree "*) printf 'true\n' ;;
  *" rev-parse "*) "$REAL_GIT" "$@" ;;
  *" status "*) ;;
  *" worktree remove "*)
    printf '%s\n' "${!#}" >> "$FAKE_GIT_LOG"
    if [[ -e "${FAKE_GIT_ALLOW:-}" ]]; then
      "$REAL_GIT" "$@"
      exit $?
    fi
    exit 1
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/git"
# First attempt: worktree removal fails, puts fixture in removing phase.
if PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_GIT_LOG="$TEST_ROOT/linked-retry-removals" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" linked-retry >/dev/null 2>&1; then
  printf 'linked-worktree first cleanup should have failed at worktree removal\n' >&2
  exit 1
fi

# td-4bd82f: removing-state retry restore failure must produce a diagnosable error.
# Set up a dedicated removing-phase fixture and inject persisted-evidence drift at
# the before-retry-restore boundary to verify that _require_terminal_repos fails
# closed with "evidence restore failed during removing-state replay".
mkdir -p "$TEST_ROOT/fleet/restore-diag/app"
init_test_repo "$TEST_ROOT/restore-diag"
git -C "$TEST_ROOT/restore-diag" worktree add -q -b restore-diag-worker \
  "$TEST_ROOT/restore-diag-sgt-restore-diag"
record_retry_owner restore-diag app "$TEST_ROOT/restore-diag"
printf '%s\n' "$TEST_ROOT/restore-diag-sgt-restore-diag" > \
  "$TEST_ROOT/fleet/restore-diag/app/worktree"
printf 'done\n' > "$TEST_ROOT/fleet/restore-diag/app/status"
printf 'result\n' > "$TEST_ROOT/fleet/restore-diag/app/result"
printf 'done\n' > "$TEST_ROOT/restore-diag-sgt-restore-diag/.sergeant-status"
printf 'result\n' > "$TEST_ROOT/restore-diag-sgt-restore-diag/.sergeant-result"
# Initial removal fails to create the removing state
if PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_GIT_LOG="$TEST_ROOT/restore-diag-removals" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" restore-diag >/dev/null 2>&1; then
  printf 'restore-diag initial removal unexpectedly succeeded\n' >&2
  exit 1
fi
# Worktree is still present, cleanup-phase=removing, terminal-evidence populated
restore_diag_live_before="$(cksum "$TEST_ROOT/restore-diag-sgt-restore-diag"/.sergeant-*)"
restore_diag_owner="$(cksum "$TEST_ROOT/fleet/restore-diag/app/cleanup-owner")"
restore_diag_phase="$(cksum "$TEST_ROOT/fleet/restore-diag/app/cleanup-phase")"
set +e
restore_failure_output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
  SGT_CLEANUP_MUTATE_POINT=before-retry-restore \
  SGT_CLEANUP_MUTATE_PATH="$TEST_ROOT/fleet/restore-diag/app/terminal-evidence/.sergeant-status" \
  FAKE_GIT_LOG="$TEST_ROOT/restore-diag-removals" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" restore-diag 2>&1)"
restore_failure_status=$?
set -e
[[ "$restore_failure_status" -ne 0 ]] || {
  printf 'cleanup accepted removing-state restore failure without diagnostic\n' >&2; exit 1
}
[[ "$restore_failure_output" == *"Failed to restore persisted worker evidence: app"* ]] || {
  printf 'unexpected removing restore failure output: %s\n' "$restore_failure_output" >&2; exit 1
}
# Live worktree evidence must not be mutated
[[ "$(cksum "$TEST_ROOT/restore-diag-sgt-restore-diag"/.sergeant-*)" == \
  "$restore_diag_live_before" ]] || {
  printf 'failed restore mutated live evidence\n' >&2; exit 1
}
# Owner and phase must be preserved
[[ "$(cksum "$TEST_ROOT/fleet/restore-diag/app/cleanup-owner")" == \
  "$restore_diag_owner" ]]
[[ "$(cksum "$TEST_ROOT/fleet/restore-diag/app/cleanup-phase")" == \
  "$restore_diag_phase" ]]

# Positive-path partial-removal retry: a worktree directory was removed but the
# git command failed after that (partial removal).  After pruning the git registry,
# cleanup must reconcile the absence and remove fleet state.
mkdir -p "$TEST_ROOT/fleet/partial-retry-complete/app"
init_test_repo "$TEST_ROOT/partial-retry-complete"
git -C "$TEST_ROOT/partial-retry-complete" worktree add -q -b partial-retry-worker \
  "$TEST_ROOT/partial-retry-complete-sgt-partial-retry-complete"
record_retry_owner partial-retry-complete app "$TEST_ROOT/partial-retry-complete"
printf '%s\n' "$TEST_ROOT/partial-retry-complete-sgt-partial-retry-complete" > \
  "$TEST_ROOT/fleet/partial-retry-complete/app/worktree"
printf 'done\n' > "$TEST_ROOT/fleet/partial-retry-complete/app/status"
printf 'result\n' > "$TEST_ROOT/fleet/partial-retry-complete/app/result"
printf 'done\n' > \
  "$TEST_ROOT/partial-retry-complete-sgt-partial-retry-complete/.sergeant-status"
printf 'result\n' > \
  "$TEST_ROOT/partial-retry-complete-sgt-partial-retry-complete/.sergeant-result"
# Save the current fake-bin/git and create a partial-removal variant
cp -p "$TEST_ROOT/fake-bin/git" "$TEST_ROOT/fake-bin/git.saved"
cat > "$TEST_ROOT/fake-bin/git" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" rev-list "*|*" for-each-ref "*|*" config --get remote.origin.url "*|*" status --porcelain=v1 "*|*" diff "*|*" ls-files "*|*" hash-object "*) "$REAL_GIT" "$@" ;;
  *" rev-parse --is-inside-work-tree "*) printf 'true\n' ;;
  *" rev-parse "*) "$REAL_GIT" "$@" ;;
  *" status "*) ;;
  *" check-ref-format "*|*" worktree list --porcelain -z "*) "$REAL_GIT" "$@" ;;
  *" worktree remove "*)
    rm -rf "${!#}"
    exit 1
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/git"
if PATH="$TEST_ROOT/fake-bin:$PATH" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" partial-retry-complete >/dev/null 2>&1; then
  printf 'partial-retry-complete initial cleanup unexpectedly succeeded\n' >&2; exit 1
fi
[[ ! -e "$TEST_ROOT/partial-retry-complete-sgt-partial-retry-complete" ]]
[[ "$(sed -n '1p' "$TEST_ROOT/fleet/partial-retry-complete/app/cleanup-phase")" == \
  "partial-removal" ]] || {
  printf 'partial-removal phase not recorded after failed worktree removal\n' >&2; exit 1
}
# Prune git registry to prove removal completed, then retry → must reconcile
"$REAL_GIT" -C "$TEST_ROOT/partial-retry-complete" worktree prune --expire now
SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" partial-retry-complete >/dev/null || {
  printf 'partial-retry-complete reconcile failed\n' >&2; exit 1
}
[[ ! -e "$TEST_ROOT/fleet/partial-retry-complete" ]] || {
  printf 'fleet state not removed after partial-removal reconcile\n' >&2; exit 1
}
mv "$TEST_ROOT/fake-bin/git.saved" "$TEST_ROOT/fake-bin/git"

mkdir -p "$TEST_ROOT/fleet/unchanged-retry/app"
init_test_repo "$TEST_ROOT/unchanged-retry"
git -C "$TEST_ROOT/unchanged-retry" worktree add -q -b unchanged-retry-worker \
  "$TEST_ROOT/unchanged-retry-sgt-unchanged-retry"
record_retry_owner unchanged-retry app "$TEST_ROOT/unchanged-retry"
printf '%s\n' "$TEST_ROOT/unchanged-retry-sgt-unchanged-retry" > \
  "$TEST_ROOT/fleet/unchanged-retry/app/worktree"
printf 'done\n' > "$TEST_ROOT/fleet/unchanged-retry/app/status"
printf 'result\n' > "$TEST_ROOT/fleet/unchanged-retry/app/result"
printf 'done\n' > "$TEST_ROOT/unchanged-retry-sgt-unchanged-retry/.sergeant-status"
printf 'result\n' > "$TEST_ROOT/unchanged-retry-sgt-unchanged-retry/.sergeant-result"
if PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_GIT_LOG="$TEST_ROOT/unchanged-retry-removals" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" unchanged-retry >/dev/null 2>&1; then
  printf 'initial unchanged-retry removal unexpectedly succeeded\n' >&2
  exit 1
fi
[[ "$(wc -l < "$TEST_ROOT/unchanged-retry-removals")" -eq 1 ]]
touch "$TEST_ROOT/unchanged-retry-remove-allowed"
PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_GIT_ALLOW="$TEST_ROOT/unchanged-retry-remove-allowed" \
  FAKE_GIT_LOG="$TEST_ROOT/unchanged-retry-removals" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" unchanged-retry >/dev/null
[[ "$(wc -l < "$TEST_ROOT/unchanged-retry-removals")" -eq 2 ]]
[[ ! -e "$TEST_ROOT/fleet/unchanged-retry" ]]
rm "$TEST_ROOT/fake-bin/git"

# dirty-owner-retry: verify that unstaged changes to the configured owner repo
# invalidate a retry. The new _repo_identity includes worktree state
# (_repo_worktree_identity runs git diff HEAD), so content changes change the
# stored identity hash. A retry must be rejected when the owner's state differs.
mkdir -p "$TEST_ROOT/fleet/dirty-owner-retry/app" \
  "$TEST_ROOT/fake-bin"
init_test_repo "$TEST_ROOT/dirty-owner-retry"
git -C "$TEST_ROOT/dirty-owner-retry" worktree add -q -b dirty-owner-retry-worker \
  "$TEST_ROOT/dirty-owner-retry-sgt-dirty-owner-retry"
record_retry_owner dirty-owner-retry app "$TEST_ROOT/dirty-owner-retry"
printf '%s\n' "$TEST_ROOT/dirty-owner-retry-sgt-dirty-owner-retry" > \
  "$TEST_ROOT/fleet/dirty-owner-retry/app/worktree"
printf 'done\n' > "$TEST_ROOT/fleet/dirty-owner-retry/app/status"
printf 'result\n' > "$TEST_ROOT/fleet/dirty-owner-retry/app/result"
printf 'done\n' > "$TEST_ROOT/dirty-owner-retry-sgt-dirty-owner-retry/.sergeant-status"
printf 'result\n' > "$TEST_ROOT/dirty-owner-retry-sgt-dirty-owner-retry/.sergeant-result"
cat > "$TEST_ROOT/fake-bin/git" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" worktree remove "*) printf '%s\n' "${!#}" >> "$FAKE_GIT_LOG"; exit 1 ;;
esac
"$REAL_GIT" "$@"
EOF
chmod +x "$TEST_ROOT/fake-bin/git"
# First cleanup: fake git fails — records cleanup-phase=removing + cleanup-owner
if PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_GIT_LOG="$TEST_ROOT/dirty-owner-retry-removals" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" dirty-owner-retry >/dev/null 2>&1; then
  printf 'cleanup succeeded on fake-git failure (unexpected)\n' >&2
  exit 1
fi
[[ -f "$TEST_ROOT/fleet/dirty-owner-retry/app/cleanup-owner" ]] || {
  printf 'cleanup-owner not recorded after first failed attempt\n' >&2
  exit 1
}
# Modify the owner repo's working tree — identity must now differ
printf 'dirty content added after owner record\n' >> "$TEST_ROOT/dirty-owner-retry/README.md"
# Retry: must be rejected because identity changed
if PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_GIT_LOG="$TEST_ROOT/dirty-owner-retry-removals" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" dirty-owner-retry >/dev/null 2>&1; then
  printf 'cleanup accepted dirty-owner retry with changed identity (unexpected)\n' >&2
  exit 1
fi
[[ -e "$TEST_ROOT/fleet/dirty-owner-retry" ]] || {
  printf 'fleet state unexpectedly removed after rejected retry\n' >&2
  exit 1
}
rm "$TEST_ROOT/fake-bin/git"
printf 'sgt-cleanup dirty-owner-retry: changed identity correctly rejected\n'

mkdir -p "$TEST_ROOT/fleet/partial-publication/app" \
  "$TEST_ROOT/fake-bin"
init_test_repo "$TEST_ROOT/partial-publication"
git -C "$TEST_ROOT/partial-publication" worktree add -q \
  -b partial-publication-worker \
  "$TEST_ROOT/partial-publication-sgt-partial-publication"
git -C "$TEST_ROOT/partial-publication" worktree add -q \
  -b partial-publication-prefix-worker \
  "$TEST_ROOT/partial-publication-sgt-partial-publication-prefix-collision"
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
  *" rev-list "*|*" for-each-ref "*|*" config --get remote.origin.url "*|*" status --porcelain=v1 "*|*" diff "*|*" ls-files "*|*" hash-object "*|*" check-ref-format "*) "$REAL_GIT" "$@" ;;
  *" rev-parse --is-inside-work-tree "*) printf 'true\n' ;;
  *" rev-parse "*) "$REAL_GIT" "$@" ;;
  *" status "*) ;;
  *" check-ref-format "*) "$REAL_GIT" "$@" ;;
  *" worktree list --porcelain -z "*)
    case "${FAKE_GIT_LIST_MODE:-real}" in
      real) "$REAL_GIT" "$@" ;;
      registered)
        printf 'worktree %s\0HEAD 0000000000000000000000000000000000000000\0detached\0\0' \
          "$FAKE_GIT_WORKTREE"
        ;;
      duplicate)
        printf 'worktree %s\0HEAD 0000000000000000000000000000000000000000\0detached\0\0' \
          "$FAKE_GIT_WORKTREE"
        printf 'worktree %s\0HEAD 0000000000000000000000000000000000000000\0detached\0\0' \
          "$FAKE_GIT_WORKTREE"
        ;;
      alias)
        printf 'worktree %s/../%s\0HEAD 0000000000000000000000000000000000000000\0detached\0\0' \
          "$FAKE_GIT_WORKTREE" "$(basename "$FAKE_GIT_WORKTREE")"
        ;;
      existing-alias)
        printf 'worktree %s\0HEAD 0000000000000000000000000000000000000000\0detached\0\0' \
          "$FAKE_GIT_ALIAS_WORKTREE"
        ;;
      malformed)
        printf 'worktree %s-malformed\0unexpected field\0\0' \
          "$FAKE_GIT_WORKTREE"
        ;;
      branch-refs-root)
        printf 'worktree %s-malformed\0HEAD 0000000000000000000000000000000000000000\0branch refs/\0\0' \
          "$FAKE_GIT_WORKTREE"
        ;;
      branch-double-slash)
        printf 'worktree %s-malformed\0HEAD 0000000000000000000000000000000000000000\0branch refs//bad\0\0' \
          "$FAKE_GIT_WORKTREE"
        ;;
      branch-trailing-slash)
        printf 'worktree %s-malformed\0HEAD 0000000000000000000000000000000000000000\0branch refs/heads/bad/\0\0' \
          "$FAKE_GIT_WORKTREE"
        ;;
      branch-invalid)
        printf 'worktree %s-malformed\0HEAD 0000000000000000000000000000000000000000\0branch refs/heads/bad..name\0\0' \
          "$FAKE_GIT_WORKTREE"
        ;;
      probe-failure) exit 1 ;;
    esac
    ;;
  *" worktree remove "*)
    printf '%s\n' "${!#}" >> "$FAKE_GIT_LOG"
    "$REAL_GIT" "$@"
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
if compgen -G "$TEST_ROOT/fleet/partial-publication/app/cleanup-phase.tmp*" \
  >/dev/null; then
  printf 'partial-removal publication left a phase temporary\n' >&2
  exit 1
fi
partial_owner_before="$(cksum "$TEST_ROOT/fleet/partial-publication/app/cleanup-owner")"
partial_phase_before="$(cksum "$TEST_ROOT/fleet/partial-publication/app/cleanup-phase")"
partial_evidence_before="$(cksum \
  "$TEST_ROOT/fleet/partial-publication/app/terminal-evidence"/.sergeant-*)"
ln -s "$TEST_ROOT/partial-publication-sgt-partial-publication-prefix-collision" \
  "$TEST_ROOT/partial-publication-registered-alias"
for list_mode in registered duplicate alias existing-alias malformed \
  branch-refs-root branch-double-slash branch-trailing-slash branch-invalid \
  probe-failure; do
  if PATH="$TEST_ROOT/fake-bin:$PATH" \
    FAKE_GIT_LIST_MODE="$list_mode" \
    FAKE_GIT_WORKTREE="$TEST_ROOT/partial-publication-sgt-partial-publication" \
    FAKE_GIT_ALIAS_WORKTREE="$TEST_ROOT/partial-publication-registered-alias" \
    FAKE_GIT_LOG="$TEST_ROOT/partial-publication-removals" \
    FAKE_GIT_STATE="$TEST_ROOT/partial-publication-git-failed" \
    FAKE_MV_STATE="$TEST_ROOT/partial-publication-mv-failed" \
    SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-cleanup" partial-publication >/dev/null 2>&1; then
    printf 'cleanup accepted unsafe git worktree registry state: %s\n' \
      "$list_mode" >&2
    exit 1
  fi
  [[ "$(wc -l < "$TEST_ROOT/partial-publication-removals")" -eq 1 ]]
  [[ "$(cksum "$TEST_ROOT/fleet/partial-publication/app/cleanup-owner")" == \
    "$partial_owner_before" ]]
  [[ "$(cksum "$TEST_ROOT/fleet/partial-publication/app/cleanup-phase")" == \
    "$partial_phase_before" ]]
  [[ "$(cksum \
    "$TEST_ROOT/fleet/partial-publication/app/terminal-evidence"/.sergeant-*)" == \
    "$partial_evidence_before" ]]
done
PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_GIT_LIST_MODE=real \
  FAKE_GIT_LOG="$TEST_ROOT/partial-publication-removals" \
  FAKE_GIT_STATE="$TEST_ROOT/partial-publication-git-failed" \
  FAKE_MV_STATE="$TEST_ROOT/partial-publication-mv-failed" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" partial-publication >/dev/null
[[ "$(wc -l < "$TEST_ROOT/partial-publication-removals")" -eq 1 ]]
[[ ! -e "$TEST_ROOT/fleet/partial-publication" ]]
rm "$TEST_ROOT/fake-bin/git" "$TEST_ROOT/fake-bin/mv"

mkdir -p "$TEST_ROOT/fleet/treehouse-partial/app" \
  "$TEST_ROOT/fake-bin"
init_test_repo "$TEST_ROOT/treehouse-main"
git -C "$TEST_ROOT/treehouse-main" worktree add -q -b treehouse-worker \
  "$TEST_ROOT/treehouse-worktree"
record_retry_owner treehouse-partial app "$TEST_ROOT/treehouse-main"
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
  *" rev-list "*|*" for-each-ref "*|*" config --get remote.origin.url "*|*" status --porcelain=v1 "*|*" diff "*|*" ls-files "*|*" hash-object "*|*" check-ref-format "*|*" worktree list --porcelain -z "*) "$REAL_GIT" "$@" ;;
  *" rev-parse --is-inside-work-tree "*) printf 'true\n' ;;
  *" rev-parse "*) "$REAL_GIT" "$@" ;;
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
treehouse_owner_before="$(cksum \
  "$TEST_ROOT/fleet/treehouse-partial/app/cleanup-owner")"
treehouse_phase_before="$(cksum \
  "$TEST_ROOT/fleet/treehouse-partial/app/cleanup-phase")"
treehouse_evidence_before="$(cksum \
  "$TEST_ROOT/fleet/treehouse-partial/app/terminal-evidence"/.sergeant-*)"
if PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_TREEHOUSE_LOG="$TEST_ROOT/treehouse-removals" \
  FAKE_TREEHOUSE_STATE="$TEST_ROOT/treehouse-failed-once" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" treehouse-partial >/dev/null 2>&1; then
  printf 'cleanup replayed an absent partial treehouse removal\n' >&2
  exit 1
fi
[[ "$(wc -l < "$TEST_ROOT/treehouse-removals")" -eq 1 ]]
[[ "$(cksum "$TEST_ROOT/fleet/treehouse-partial/app/cleanup-owner")" == \
  "$treehouse_owner_before" ]]
[[ "$(cksum "$TEST_ROOT/fleet/treehouse-partial/app/cleanup-phase")" == \
  "$treehouse_phase_before" ]]
[[ "$(cksum \
  "$TEST_ROOT/fleet/treehouse-partial/app/terminal-evidence"/.sergeant-*)" == \
  "$treehouse_evidence_before" ]]
printf 'removed\n%s\ntreehouse\n%s\n' \
  "$TEST_ROOT/treehouse-worktree" "$TEST_ROOT/treehouse-main" > \
  "$TEST_ROOT/fleet/treehouse-partial/app/cleanup-phase"
treehouse_removed_phase_before="$(cksum \
  "$TEST_ROOT/fleet/treehouse-partial/app/cleanup-phase")"
if PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_TREEHOUSE_LOG="$TEST_ROOT/treehouse-removals" \
  FAKE_TREEHOUSE_STATE="$TEST_ROOT/treehouse-failed-once" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" treehouse-partial >/dev/null 2>&1; then
  printf 'cleanup trusted a removed treehouse marker without lease proof\n' >&2
  exit 1
fi
[[ "$(wc -l < "$TEST_ROOT/treehouse-removals")" -eq 1 ]]
[[ "$(cksum "$TEST_ROOT/fleet/treehouse-partial/app/cleanup-owner")" == \
  "$treehouse_owner_before" ]]
[[ "$(cksum "$TEST_ROOT/fleet/treehouse-partial/app/cleanup-phase")" == \
  "$treehouse_removed_phase_before" ]]
[[ "$(cksum \
  "$TEST_ROOT/fleet/treehouse-partial/app/terminal-evidence"/.sergeant-*)" == \
  "$treehouse_evidence_before" ]]
rm "$TEST_ROOT/fake-bin/git" "$TEST_ROOT/fake-bin/treehouse"

mkdir -p "$TEST_ROOT/fleet/marker-publication/app" \
  "$TEST_ROOT/fake-bin"
init_test_repo "$TEST_ROOT/marker"
git -C "$TEST_ROOT/marker" worktree add -q -b marker-worker \
  "$TEST_ROOT/marker-sgt-marker-publication"
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
  *" rev-list "*|*" for-each-ref "*|*" config --get remote.origin.url "*|*" status --porcelain=v1 "*|*" diff "*|*" ls-files "*|*" hash-object "*|*" check-ref-format "*|*" worktree list --porcelain -z "*) "$REAL_GIT" "$@" ;;
  *" rev-parse --is-inside-work-tree "*) printf 'true\n' ;;
  *" rev-parse "*) "$REAL_GIT" "$@" ;;
  *" status "*) ;;
  *" check-ref-format "*|*" worktree list --porcelain -z "*) "$REAL_GIT" "$@" ;;
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
set +e
marker_initial_output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_MV_STATE="$TEST_ROOT/mv-failed-once" \
  FAKE_GIT_STATE="$TEST_ROOT/marker-git-removed" \
  FAKE_GIT_LOG="$TEST_ROOT/marker-removals" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" marker-publication 2>&1)"
marker_initial_status=$?
set -e
if [[ "$marker_initial_status" -eq 0 ]]; then
  printf 'cleanup succeeded after reconciled phase publication failed\n' >&2
  exit 1
fi
[[ "$marker_initial_output" == \
  *'Cannot prove completed git worktree removal:'* ]]
[[ ! -e "$TEST_ROOT/marker-sgt-marker-publication" ]]
[[ "$(sed -n '1p' "$TEST_ROOT/fleet/marker-publication/app/cleanup-phase")" == \
  'removed' ]]
if compgen -G "$TEST_ROOT/fleet/marker-publication/app/cleanup-phase.tmp*" \
  >/dev/null; then
  printf 'reconciled-absent publication left a phase temporary\n' >&2
  exit 1
fi
marker_phase_before="$(cksum \
  "$TEST_ROOT/fleet/marker-publication/app/cleanup-phase")"
marker_evidence_before="$(cksum \
  "$TEST_ROOT/fleet/marker-publication/app/terminal-evidence"/.sergeant-*)"
"$REAL_GIT" -C "$TEST_ROOT/marker" worktree prune --expire now
set +e
marker_rollback_output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
  SGT_CLEANUP_FAIL_POINT='phase-publish-reconciled-absent,phase-rollback-reconciled-absent' \
  FAKE_MV_STATE="$TEST_ROOT/mv-failed-once" \
  FAKE_GIT_STATE="$TEST_ROOT/marker-git-removed" \
  FAKE_GIT_LOG="$TEST_ROOT/marker-removals" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" marker-publication 2>&1)"
marker_rollback_status=$?
set -e
[[ "$marker_rollback_status" -ne 0 ]]
[[ "$marker_rollback_output" == *'CRITICAL: rollback cleanup failed'* ]]
[[ "$(cksum "$TEST_ROOT/fleet/marker-publication/app/cleanup-phase")" == \
  "$marker_phase_before" ]]
[[ "$(cksum \
  "$TEST_ROOT/fleet/marker-publication/app/terminal-evidence"/.sergeant-*)" == \
  "$marker_evidence_before" ]]
marker_phase_temp="$(compgen -G \
  "$TEST_ROOT/fleet/marker-publication/app/cleanup-phase.tmp.*")"
[[ -f "$marker_phase_temp" ]]
rm "$marker_phase_temp"
touch "$TEST_ROOT/mv-failed-once"
PATH="$TEST_ROOT/fake-bin:$PATH" FAKE_MV_STATE="$TEST_ROOT/mv-failed-once" \
  FAKE_GIT_STATE="$TEST_ROOT/marker-git-removed" \
  FAKE_GIT_LOG="$TEST_ROOT/marker-removals" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" marker-publication >/dev/null
[[ "$(wc -l < "$TEST_ROOT/marker-removals")" -eq 1 ]]
[[ ! -e "$TEST_ROOT/fleet/marker-publication" ]]
rm "$TEST_ROOT/fake-bin/git" "$TEST_ROOT/fake-bin/mv"

mkdir -p "$TEST_ROOT/fleet/staging-failure/app" \
  "$TEST_ROOT/fake-bin"
init_test_repo "$TEST_ROOT/staging"
git -C "$TEST_ROOT/staging" worktree add -q -b staging-failure-worker \
  "$TEST_ROOT/staging-sgt-staging-failure"
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
  *" rev-list "*|*" for-each-ref "*|*" config --get remote.origin.url "*|*" status --porcelain=v1 "*|*" diff "*|*" ls-files "*|*" hash-object "*|*" check-ref-format "*|*" worktree list --porcelain -z "*) "$REAL_GIT" "$@" ;;
  *" rev-parse --is-inside-work-tree "*) printf 'true\n' ;;
  *" rev-parse "*) "$REAL_GIT" "$@" ;;
  *" status "*) ;;
  *" check-ref-format "*|*" worktree list --porcelain -z "*) "$REAL_GIT" "$@" ;;
  *" worktree remove "*)
    "$REAL_GIT" "$@"
    if [[ -n "${FAKE_GIT_MUTATE_PATH:-}" ]]; then
      printf 'changed during removal\n' > "$FAKE_GIT_MUTATE_PATH"
    fi
    ;;
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
if [[ -n "${FAKE_CP_MUTATE_STATE:-}" && " $* " == *".sergeant-result"* && \
  ! -e "$FAKE_CP_MUTATE_STATE" ]]; then
  "$REAL_CP" "$@"
  printf 'failed: changed during staging\n' > \
    "$FAKE_CP_MUTATE_SOURCE/.sergeant-status"
  touch "$FAKE_CP_MUTATE_STATE"
  exit 0
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
[[ ! -e "$TEST_ROOT/fleet/staging-failure/app/terminal-evidence" ]]
[[ ! -e "$TEST_ROOT/fleet/staging-failure/app/cleanup-owner" ]]
[[ ! -e "$TEST_ROOT/fleet/staging-failure/app/cleanup-phase" ]]
if PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_CP_STATE="$TEST_ROOT/cp-failed-once" \
  FAKE_CP_MUTATE_STATE="$TEST_ROOT/cp-mutated-once" \
  FAKE_CP_MUTATE_SOURCE="$TEST_ROOT/staging-sgt-staging-failure" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" staging-failure >/dev/null 2>&1; then
  printf 'cleanup accepted lifecycle evidence changed during staging\n' >&2
  exit 1
fi
[[ -d "$TEST_ROOT/staging-sgt-staging-failure" ]]
[[ ! -e "$TEST_ROOT/fleet/staging-failure/app/terminal-evidence" ]]
[[ ! -e "$TEST_ROOT/fleet/staging-failure/app/cleanup-owner" ]]
[[ ! -e "$TEST_ROOT/fleet/staging-failure/app/cleanup-phase" ]]
printf 'done\n' > "$TEST_ROOT/staging-sgt-staging-failure/.sergeant-status"
if PATH="$TEST_ROOT/fake-bin:$PATH" FAKE_CP_STATE="$TEST_ROOT/cp-failed-once" \
  FAKE_GIT_MUTATE_PATH="$TEST_ROOT/fleet/staging-failure/app/terminal-evidence/.sergeant-result" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" staging-failure >/dev/null 2>&1; then
  printf 'cleanup accepted persisted evidence changed during removal\n' >&2
  exit 1
fi
[[ "$(sed -n '1p' "$TEST_ROOT/fleet/staging-failure/app/cleanup-phase")" == \
  removed ]]
printf 'result\n' > \
  "$TEST_ROOT/fleet/staging-failure/app/terminal-evidence/.sergeant-result"
PATH="$TEST_ROOT/fake-bin:$PATH" FAKE_CP_STATE="$TEST_ROOT/cp-failed-once" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" staging-failure >/dev/null
[[ ! -e "$TEST_ROOT/fleet/staging-failure" ]]
rm "$TEST_ROOT/fake-bin/git" "$TEST_ROOT/fake-bin/cp"

init_test_repo "$TEST_ROOT/legacy-repo"
legacy_worktree="$TEST_ROOT/legacy-repo-sgt-legacy-task"
legacy_repo_state="$TEST_ROOT/fleet/legacy-task/app"
mkdir -p "$legacy_repo_state"
record_retry_owner legacy-task app "$TEST_ROOT/legacy-repo"
git -C "$TEST_ROOT/legacy-repo" worktree add -q -b test-cleanup-legacy "$legacy_worktree"
record_retry_owner legacy-task app "$TEST_ROOT/legacy-repo"
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

mkdir -p "$TEST_ROOT/fleet/publication-transaction/app"
init_test_repo "$TEST_ROOT/publication-transaction"
git -C "$TEST_ROOT/publication-transaction" worktree add -q \
  -b publication-transaction-worker \
  "$TEST_ROOT/publication-transaction-worker"
record_retry_owner publication-transaction app \
  "$TEST_ROOT/publication-transaction"
printf '%s\n' "$TEST_ROOT/publication-transaction-worker" > \
  "$TEST_ROOT/fleet/publication-transaction/app/worktree"
printf 'done\n' > "$TEST_ROOT/fleet/publication-transaction/app/status"
printf 'result\n' > "$TEST_ROOT/fleet/publication-transaction/app/result"
printf 'done\n' > \
  "$TEST_ROOT/publication-transaction-worker/.sergeant-status"
printf 'result\n' > \
  "$TEST_ROOT/publication-transaction-worker/.sergeant-result"
printf 'diagnostic bytes\n' > \
  "$TEST_ROOT/publication-transaction-worker/.sergeant-diagnostic"
publication_fleet_before="$(cksum \
  "$TEST_ROOT/fleet/publication-transaction/app/status" \
  "$TEST_ROOT/fleet/publication-transaction/app/result" \
  "$TEST_ROOT/fleet/publication-transaction/app/worktree")"
publication_live_before="$(cksum \
  "$TEST_ROOT/publication-transaction-worker"/.sergeant-*)"
publication_live_hashes="$(for evidence in \
  "$TEST_ROOT/publication-transaction-worker"/.sergeant-*; do
  git hash-object "$evidence"
done)"
for failure_point in stage-evidence record-owner record-phase \
  publish-evidence publish-owner publish-phase; do
  if SGT_CLEANUP_FAIL_POINT="$failure_point" \
    SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-cleanup" publication-transaction app \
      > "$TEST_ROOT/publication-$failure_point.log" 2>&1; then
    printf 'cleanup accepted injected publication failure: %s\n' \
      "$failure_point" >&2
    exit 1
  fi
  [[ "$(cksum \
    "$TEST_ROOT/fleet/publication-transaction/app/status" \
    "$TEST_ROOT/fleet/publication-transaction/app/result" \
    "$TEST_ROOT/fleet/publication-transaction/app/worktree")" == \
    "$publication_fleet_before" ]]
  [[ "$(cksum "$TEST_ROOT/publication-transaction-worker"/.sergeant-*)" == \
    "$publication_live_before" ]]
  [[ ! -e "$TEST_ROOT/fleet/publication-transaction/app/terminal-evidence" ]]
  [[ ! -e "$TEST_ROOT/fleet/publication-transaction/app/cleanup-owner" ]]
  [[ ! -e "$TEST_ROOT/fleet/publication-transaction/app/cleanup-phase" ]]
  [[ ! -e "$TEST_ROOT/publication-transaction/.git/sergeant-instance" ]]
  if compgen -G "$TEST_ROOT/fleet/publication-transaction/app/*.tmp*" \
    >/dev/null; then
    printf 'publication failure left a temporary artifact: %s\n' \
      "$failure_point" >&2
    exit 1
  fi
  if compgen -G "$TEST_ROOT/publication-transaction/.git/.sergeant-instance.*" \
    >/dev/null; then
    printf 'publication failure left an instance-marker temporary: %s\n' \
      "$failure_point" >&2
    exit 1
  fi
done
set +e
publication_rollback_output="$(SGT_CLEANUP_FAIL_POINT='publish-owner,initial-rollback-cleanup' \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" publication-transaction app 2>&1)"
publication_rollback_status=$?
set -e
[[ "$publication_rollback_status" -ne 0 ]]
[[ "$publication_rollback_output" == *'CRITICAL: rollback cleanup failed'* ]]
[[ -d "$TEST_ROOT/fleet/publication-transaction/app/terminal-evidence" ]]
if ! compgen -G \
  "$TEST_ROOT/fleet/publication-transaction/app/cleanup-transaction.tmp.*" \
  >/dev/null; then
  printf 'initial rollback cleanup failure did not preserve its transaction\n' >&2
  exit 1
fi
[[ ! -e "$TEST_ROOT/fleet/publication-transaction/app/cleanup-owner" ]]
[[ ! -e "$TEST_ROOT/fleet/publication-transaction/app/cleanup-phase" ]]
[[ "$(cksum "$TEST_ROOT/publication-transaction-worker"/.sergeant-*)" == \
  "$publication_live_before" ]]
rm -rf "$TEST_ROOT/fleet/publication-transaction/app/terminal-evidence" \
  "$TEST_ROOT/fleet/publication-transaction/app"/cleanup-transaction.tmp.*
rm -f "$TEST_ROOT/publication-transaction/.git/sergeant-instance"
printf 'preexisting-instance-token\n' > \
  "$TEST_ROOT/publication-transaction/.git/sergeant-instance"
publication_marker_before="$(cksum \
  "$TEST_ROOT/publication-transaction/.git/sergeant-instance")"
if SGT_CLEANUP_FAIL_POINT=publish-owner \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" publication-transaction app >/dev/null 2>&1; then
  printf 'cleanup accepted publication failure with an existing instance marker\n' >&2
  exit 1
fi
[[ "$(cksum "$TEST_ROOT/publication-transaction/.git/sergeant-instance")" == \
  "$publication_marker_before" ]]
[[ "$(cksum "$TEST_ROOT/publication-transaction-worker"/.sergeant-*)" == \
  "$publication_live_before" ]]
[[ ! -e "$TEST_ROOT/fleet/publication-transaction/app/terminal-evidence" ]]
[[ ! -e "$TEST_ROOT/fleet/publication-transaction/app/cleanup-owner" ]]
[[ ! -e "$TEST_ROOT/fleet/publication-transaction/app/cleanup-phase" ]]
if SGT_CLEANUP_FAIL_POINT=phase-publish-removed \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" publication-transaction app >/dev/null 2>&1; then
  printf 'cleanup accepted injected removed-phase publication failure\n' >&2
  exit 1
fi
[[ ! -e "$TEST_ROOT/publication-transaction-worker" ]]
[[ "$(sed -n '1p' \
  "$TEST_ROOT/fleet/publication-transaction/app/cleanup-phase")" == removing ]]
publication_persisted_hashes="$(for evidence in \
  "$TEST_ROOT/fleet/publication-transaction/app/terminal-evidence"/.sergeant-*; do
  git hash-object "$evidence"
done)"
[[ "$publication_persisted_hashes" == "$publication_live_hashes" ]]
if compgen -G "$TEST_ROOT/fleet/publication-transaction/app/cleanup-phase.tmp*" \
  >/dev/null; then
  printf 'removed publication left a phase temporary\n' >&2
  exit 1
fi
SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" publication-transaction app >/dev/null

mkdir -p "$TEST_ROOT/fleet/evidence-transaction/app" "$TEST_ROOT/fake-bin"
init_test_repo "$TEST_ROOT/evidence-transaction"
git -C "$TEST_ROOT/evidence-transaction" worktree add -q \
  -b evidence-transaction-worker "$TEST_ROOT/evidence-transaction-worker"
record_retry_owner evidence-transaction app "$TEST_ROOT/evidence-transaction"
printf '%s\n' "$TEST_ROOT/evidence-transaction-worker" > \
  "$TEST_ROOT/fleet/evidence-transaction/app/worktree"
printf 'done\n' > "$TEST_ROOT/fleet/evidence-transaction/app/status"
printf 'result\n' > "$TEST_ROOT/fleet/evidence-transaction/app/result"
printf 'done\n' > "$TEST_ROOT/evidence-transaction-worker/.sergeant-status"
printf 'result\n' > "$TEST_ROOT/evidence-transaction-worker/.sergeant-result"
printf 'diagnostic\n' > \
  "$TEST_ROOT/evidence-transaction-worker/.sergeant-diagnostic"
cat > "$TEST_ROOT/fake-bin/git" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${FAKE_GIT_HASH_TRIGGER_PATH:-}" && \
  " $* " == *"$FAKE_GIT_HASH_TRIGGER_PATH"* ]]; then
  trigger_count=0
  [[ ! -f "$FAKE_GIT_HASH_STATE" ]] || \
    trigger_count="$(cat "$FAKE_GIT_HASH_STATE")"
  trigger_count=$((trigger_count + 1))
  printf '%s\n' "$trigger_count" > "$FAKE_GIT_HASH_STATE"
  if [[ "$trigger_count" -eq "${FAKE_GIT_HASH_TRIGGER_AT:-1}" ]]; then
    case "${FAKE_GIT_HASH_ACTION:-fail}" in
      fail) exit 1 ;;
      precreate)
        ancestor_pid="$PPID"
        ancestor_count=0
        while [[ -n "$ancestor_pid" && "$ancestor_pid" != 1 && \
          "$ancestor_count" -lt 5 ]]; do
          mkdir -p "$FAKE_GIT_TRANSACTION_ROOT/restore-evidence.tmp.$ancestor_pid"
          ancestor_pid="$(ps -o ppid= -p "$ancestor_pid" | tr -d ' ')"
          ancestor_count=$((ancestor_count + 1))
        done
        ;;
    esac
  fi
fi
case " $* " in
  *" worktree remove "*)
    printf '%s\n' "${!#}" >> "$FAKE_GIT_LOG"
    exit 1
    ;;
esac
"$REAL_GIT" "$@"
EOF
chmod +x "$TEST_ROOT/fake-bin/git"
if PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_GIT_LOG="$TEST_ROOT/evidence-removals" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" evidence-transaction app >/dev/null 2>&1; then
  printf 'evidence transaction setup removal unexpectedly succeeded\n' >&2
  exit 1
fi
evidence_live_before="$(cksum \
  "$TEST_ROOT/evidence-transaction-worker"/.sergeant-*)"
evidence_persisted_before="$(cksum \
  "$TEST_ROOT/fleet/evidence-transaction/app/terminal-evidence"/.sergeant-*)"
evidence_owner_before="$(cksum \
  "$TEST_ROOT/fleet/evidence-transaction/app/cleanup-owner")"
evidence_phase_before="$(cksum \
  "$TEST_ROOT/fleet/evidence-transaction/app/cleanup-phase")"
if PATH="$TEST_ROOT/fake-bin:$PATH" \
  SGT_CLEANUP_MUTATE_POINT=before-live-removal \
  SGT_CLEANUP_MUTATE_PATH="$TEST_ROOT/evidence-transaction-worker/.sergeant-diagnostic" \
  FAKE_GIT_LOG="$TEST_ROOT/evidence-removals" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" evidence-transaction app >/dev/null 2>&1; then
  printf 'cleanup accepted live evidence changed at the removal boundary\n' >&2
  exit 1
fi
[[ "$(cat "$TEST_ROOT/evidence-transaction-worker/.sergeant-diagnostic")" == \
  'injected lifecycle evidence mutation' ]]
[[ "$(cksum \
  "$TEST_ROOT/fleet/evidence-transaction/app/terminal-evidence"/.sergeant-*)" == \
  "$evidence_persisted_before" ]]
[[ "$(cksum "$TEST_ROOT/fleet/evidence-transaction/app/cleanup-owner")" == \
  "$evidence_owner_before" ]]
[[ "$(cksum "$TEST_ROOT/fleet/evidence-transaction/app/cleanup-phase")" == \
  "$evidence_phase_before" ]]
[[ "$(wc -l < "$TEST_ROOT/evidence-removals")" -eq 1 ]]
if compgen -G "$TEST_ROOT/fleet/evidence-transaction/app/live-evidence.tmp.*" \
  >/dev/null; then
  printf 'live evidence race left a removal temporary\n' >&2
  exit 1
fi
printf 'diagnostic\n' > \
  "$TEST_ROOT/evidence-transaction-worker/.sergeant-diagnostic"
if PATH="$TEST_ROOT/fake-bin:$PATH" SGT_CLEANUP_FAIL_POINT=remove-live-2 \
  FAKE_GIT_LOG="$TEST_ROOT/evidence-removals" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" evidence-transaction app >/dev/null 2>&1; then
  printf 'cleanup accepted injected second live-evidence removal failure\n' >&2
  exit 1
fi
[[ "$(cksum "$TEST_ROOT/evidence-transaction-worker"/.sergeant-*)" == \
  "$evidence_live_before" ]]
[[ "$(cksum \
  "$TEST_ROOT/fleet/evidence-transaction/app/terminal-evidence"/.sergeant-*)" == \
  "$evidence_persisted_before" ]]
[[ "$(cksum "$TEST_ROOT/fleet/evidence-transaction/app/cleanup-owner")" == \
  "$evidence_owner_before" ]]
[[ "$(cksum "$TEST_ROOT/fleet/evidence-transaction/app/cleanup-phase")" == \
  "$evidence_phase_before" ]]
[[ "$(wc -l < "$TEST_ROOT/evidence-removals")" -eq 1 ]]
if compgen -G "$TEST_ROOT/fleet/evidence-transaction/app/live-evidence.tmp.*" \
  >/dev/null; then
  printf 'failed live-evidence removal left a backup artifact\n' >&2
  exit 1
fi

rm "$TEST_ROOT/evidence-transaction-worker"/.sergeant-*
set +e
restore_identity_output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_GIT_HASH_TRIGGER_PATH='.sergeant-diagnostic' \
  FAKE_GIT_HASH_TRIGGER_AT=2 FAKE_GIT_HASH_ACTION=fail \
  FAKE_GIT_HASH_STATE="$TEST_ROOT/restore-identity-hashes" \
  FAKE_GIT_LOG="$TEST_ROOT/evidence-removals" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" evidence-transaction app 2>&1)"
restore_identity_status=$?
set -e
[[ "$restore_identity_status" -ne 0 ]]
[[ "$restore_identity_output" == *'Failed to restore persisted worker evidence: app; inspect preserved evidence:'* ]]
if compgen -G "$TEST_ROOT/evidence-transaction-worker/.sergeant-*" >/dev/null; then
  printf 'persisted identity failure changed live evidence\n' >&2
  exit 1
fi
set +e
restore_existing_output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_GIT_HASH_TRIGGER_PATH='.sergeant-diagnostic' \
  FAKE_GIT_HASH_TRIGGER_AT=2 FAKE_GIT_HASH_ACTION=precreate \
  FAKE_GIT_HASH_STATE="$TEST_ROOT/restore-existing-hashes" \
  FAKE_GIT_TRANSACTION_ROOT="$TEST_ROOT/fleet/evidence-transaction/app" \
  FAKE_GIT_LOG="$TEST_ROOT/evidence-removals" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" evidence-transaction app 2>&1)"
restore_existing_status=$?
set -e
[[ "$restore_existing_status" -ne 0 ]]
[[ "$restore_existing_output" == *'restore artifacts:'* ]]
compgen -G "$TEST_ROOT/fleet/evidence-transaction/app/restore-evidence.tmp.*" \
  >/dev/null
rm -rf "$TEST_ROOT/fleet/evidence-transaction/app"/restore-evidence.tmp.*

REAL_MKDIR="$(command -v mkdir)"
export REAL_MKDIR
cat > "$TEST_ROOT/fake-bin/mkdir" <<'EOF'
#!/usr/bin/env bash
[[ " $* " != *'/restore-evidence.tmp.'* ]] || exit 1
"$REAL_MKDIR" "$@"
EOF
chmod +x "$TEST_ROOT/fake-bin/mkdir"
set +e
restore_setup_output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_GIT_LOG="$TEST_ROOT/evidence-removals" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" evidence-transaction app 2>&1)"
restore_setup_status=$?
set -e
[[ "$restore_setup_status" -ne 0 ]]
[[ "$restore_setup_output" == *'Failed to restore persisted worker evidence:'* ]]
rm "$TEST_ROOT/fake-bin/mkdir"

set +e
restore_staged_identity_output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_GIT_HASH_TRIGGER_PATH='.sergeant-diagnostic' \
  FAKE_GIT_HASH_TRIGGER_AT=4 FAKE_GIT_HASH_ACTION=fail \
  FAKE_GIT_HASH_STATE="$TEST_ROOT/restore-staged-identity-hashes" \
  FAKE_GIT_LOG="$TEST_ROOT/evidence-removals" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" evidence-transaction app 2>&1)"
restore_staged_identity_status=$?
set -e
[[ "$restore_staged_identity_status" -ne 0 ]]
[[ "$restore_staged_identity_output" == *'Failed to restore persisted worker evidence:'* ]]
if compgen -G "$TEST_ROOT/fleet/evidence-transaction/app/restore-evidence.tmp.*" \
  >/dev/null; then
  printf 'staged identity failure left a restore transaction\n' >&2
  exit 1
fi
set +e
restore_drift_output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
  SGT_CLEANUP_MUTATE_POINT=before-retry-restore \
  SGT_CLEANUP_MUTATE_PATH="$TEST_ROOT/fleet/evidence-transaction/app/terminal-evidence/.sergeant-diagnostic" \
  FAKE_GIT_LOG="$TEST_ROOT/evidence-removals" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" evidence-transaction app 2>&1)"
restore_drift_status=$?
set -e
if [[ "$restore_drift_status" -eq 0 ]]; then
  printf 'cleanup accepted persisted evidence changed at restore boundary\n' >&2
  exit 1
fi
[[ "$restore_drift_output" == *'Failed to restore persisted worker evidence: app; inspect preserved evidence:'* ]]
[[ "$(cat \
  "$TEST_ROOT/fleet/evidence-transaction/app/terminal-evidence/.sergeant-diagnostic")" == \
  'injected lifecycle evidence mutation' ]]
if compgen -G "$TEST_ROOT/evidence-transaction-worker/.sergeant-*" >/dev/null; then
  printf 'persisted restore race changed live evidence\n' >&2
  exit 1
fi
[[ "$(wc -l < "$TEST_ROOT/evidence-removals")" -eq 1 ]]
printf 'diagnostic\n' > \
  "$TEST_ROOT/fleet/evidence-transaction/app/terminal-evidence/.sergeant-diagnostic"
set +e
restore_staged_output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
  SGT_CLEANUP_MUTATE_POINT=after-restore-copy \
  FAKE_GIT_LOG="$TEST_ROOT/evidence-removals" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" evidence-transaction app 2>&1)"
restore_staged_status=$?
set -e
if [[ "$restore_staged_status" -eq 0 ]]; then
  printf 'cleanup accepted staged evidence changed at restore boundary\n' >&2
  exit 1
fi
[[ "$restore_staged_output" == *'Failed to restore persisted worker evidence: app; inspect preserved evidence:'* ]]
if compgen -G "$TEST_ROOT/evidence-transaction-worker/.sergeant-*" >/dev/null; then
  printf 'staged restore race changed live evidence\n' >&2
  exit 1
fi
[[ "$(cksum \
  "$TEST_ROOT/fleet/evidence-transaction/app/terminal-evidence"/.sergeant-*)" == \
  "$evidence_persisted_before" ]]
[[ "$(wc -l < "$TEST_ROOT/evidence-removals")" -eq 1 ]]
if compgen -G "$TEST_ROOT/fleet/evidence-transaction/app/restore-evidence.tmp.*" \
  >/dev/null; then
  printf 'staged restore race left a transaction temporary\n' >&2
  exit 1
fi
cp -p "$TEST_ROOT/fleet/evidence-transaction/app/terminal-evidence"/.sergeant-* \
  "$TEST_ROOT/evidence-transaction-worker/"
restore_backup_before="$(cksum \
  "$TEST_ROOT/evidence-transaction-worker"/.sergeant-*)"
REAL_MV="$(command -v mv)"
export REAL_MV
cat > "$TEST_ROOT/fake-bin/mv" <<'EOF'
#!/usr/bin/env bash
[[ -z "${FAKE_MV_FAIL_SOURCE:-}" || "$1" != "$FAKE_MV_FAIL_SOURCE" ]] || exit 1
[[ -z "${FAKE_MV_FAIL_SOURCE_SUFFIX:-}" || \
  "$1" != *"$FAKE_MV_FAIL_SOURCE_SUFFIX" ]] || exit 1
"$REAL_MV" "$@"
EOF
chmod +x "$TEST_ROOT/fake-bin/mv"
set +e
restore_backup_output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_MV_FAIL_SOURCE="$TEST_ROOT/evidence-transaction-worker/.sergeant-result" \
  FAKE_GIT_LOG="$TEST_ROOT/evidence-removals" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" evidence-transaction app 2>&1)"
restore_backup_status=$?
set -e
[[ "$restore_backup_status" -ne 0 ]]
[[ "$restore_backup_output" == *'Failed to restore persisted worker evidence: app; inspect preserved evidence:'* ]]
[[ "$(cksum \
  "$TEST_ROOT/evidence-transaction-worker"/.sergeant-*)" == \
  "$restore_backup_before" ]]
if compgen -G "$TEST_ROOT/fleet/evidence-transaction/app/restore-evidence.tmp.*" \
  >/dev/null; then
  printf 'failed live-evidence backup left a restore transaction\n' >&2
  exit 1
fi
set +e
restore_backup_rollback_output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_MV_FAIL_SOURCE="$TEST_ROOT/evidence-transaction-worker/.sergeant-result" \
  FAKE_MV_FAIL_SOURCE_SUFFIX='/original/.sergeant-diagnostic' \
  FAKE_GIT_LOG="$TEST_ROOT/evidence-removals" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" evidence-transaction app 2>&1)"
restore_backup_rollback_status=$?
set -e
[[ "$restore_backup_rollback_status" -ne 0 ]]
[[ "$restore_backup_rollback_output" == \
  *'CRITICAL: worker evidence restore backup failed and rollback failed:'* ]]
[[ "$restore_backup_rollback_output" == *'inspect preserved transaction:'* ]]
restore_backup_transaction="$(compgen -G \
  "$TEST_ROOT/fleet/evidence-transaction/app/restore-evidence.tmp.*")"
[[ -d "$restore_backup_transaction" ]]
"$REAL_MV" "$restore_backup_transaction/original/.sergeant-diagnostic" \
  "$TEST_ROOT/evidence-transaction-worker/.sergeant-diagnostic"
rm -rf "$restore_backup_transaction"
rm "$TEST_ROOT/evidence-transaction-worker"/.sergeant-*
rm "$TEST_ROOT/fake-bin/mv"
set +e
restore_rollback_output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
  SGT_CLEANUP_FAIL_POINT='restore-publish-2,restore-rollback-cleanup' \
  FAKE_GIT_LOG="$TEST_ROOT/evidence-removals" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" evidence-transaction app 2>&1)"
restore_rollback_status=$?
set -e
[[ "$restore_rollback_status" -ne 0 ]]
[[ "$restore_rollback_output" == \
  *'CRITICAL: rollback cleanup failed for published worker evidence restore; inspect preserved artifact:'* ]]
[[ -f "$TEST_ROOT/evidence-transaction-worker/.sergeant-diagnostic" ]]
if ! compgen -G \
  "$TEST_ROOT/fleet/evidence-transaction/app/restore-evidence.tmp.*" \
  >/dev/null; then
  printf 'restore rollback cleanup failure did not preserve its transaction\n' >&2
  exit 1
fi
[[ "$(cksum \
  "$TEST_ROOT/fleet/evidence-transaction/app/terminal-evidence"/.sergeant-*)" == \
  "$evidence_persisted_before" ]]
[[ "$(wc -l < "$TEST_ROOT/evidence-removals")" -eq 1 ]]
rm -f "$TEST_ROOT/evidence-transaction-worker"/.sergeant-*
rm -rf "$TEST_ROOT/fleet/evidence-transaction/app"/restore-evidence.tmp.*
set +e
restore_copy_output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
  SGT_CLEANUP_FAIL_POINT=restore-copy-2 \
  FAKE_GIT_LOG="$TEST_ROOT/evidence-removals" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" evidence-transaction app 2>&1)"
restore_copy_status=$?
set -e
if [[ "$restore_copy_status" -eq 0 ]]; then
  printf 'cleanup accepted injected second retry restore-copy failure\n' >&2
  exit 1
fi
[[ "$restore_copy_output" == *'Failed to restore persisted worker evidence: app; inspect preserved evidence:'* ]]
if compgen -G "$TEST_ROOT/evidence-transaction-worker/.sergeant-*" >/dev/null; then
  printf 'failed retry restore left partial live evidence\n' >&2
  exit 1
fi
[[ "$(cksum \
  "$TEST_ROOT/fleet/evidence-transaction/app/terminal-evidence"/.sergeant-*)" == \
  "$evidence_persisted_before" ]]
[[ "$(wc -l < "$TEST_ROOT/evidence-removals")" -eq 1 ]]
if compgen -G "$TEST_ROOT/evidence-transaction-worker/.sergeant-*.tmp.*" \
  >/dev/null; then
  printf 'failed retry restore left a copy temporary\n' >&2
  exit 1
fi
set +e
restore_publish_output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
  SGT_CLEANUP_FAIL_POINT=restore-publish-2 \
  FAKE_GIT_LOG="$TEST_ROOT/evidence-removals" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" evidence-transaction app 2>&1)"
restore_publish_status=$?
set -e
if [[ "$restore_publish_status" -eq 0 ]]; then
  printf 'cleanup accepted injected second retry restore-publication failure\n' >&2
  exit 1
fi
[[ "$restore_publish_output" == *'Failed to restore persisted worker evidence: app; inspect preserved evidence:'* ]]
if compgen -G "$TEST_ROOT/evidence-transaction-worker/.sergeant-*" >/dev/null; then
  printf 'failed retry restore publication left partial live evidence\n' >&2
  exit 1
fi
[[ "$(cksum \
  "$TEST_ROOT/fleet/evidence-transaction/app/terminal-evidence"/.sergeant-*)" == \
  "$evidence_persisted_before" ]]
[[ "$(wc -l < "$TEST_ROOT/evidence-removals")" -eq 1 ]]

cp -p "$TEST_ROOT/fleet/evidence-transaction/app/terminal-evidence"/.sergeant-* \
  "$TEST_ROOT/evidence-transaction-worker/"
cat > "$TEST_ROOT/fake-bin/mv" <<'EOF'
#!/usr/bin/env bash
[[ -z "${FAKE_MV_FAIL_SOURCE_SUFFIX:-}" || \
  "$1" != *"$FAKE_MV_FAIL_SOURCE_SUFFIX" ]] || exit 1
"$REAL_MV" "$@"
EOF
chmod +x "$TEST_ROOT/fake-bin/mv"
set +e
restore_publish_rollback_output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
  SGT_CLEANUP_FAIL_POINT=restore-publish-2 \
  FAKE_MV_FAIL_SOURCE_SUFFIX='/original/.sergeant-diagnostic' \
  FAKE_GIT_LOG="$TEST_ROOT/evidence-removals" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" evidence-transaction app 2>&1)"
restore_publish_rollback_status=$?
set -e
[[ "$restore_publish_rollback_status" -ne 0 ]]
[[ "$restore_publish_rollback_output" == \
  *'CRITICAL: worker evidence restore publication failed and rollback failed:'* ]]
[[ "$restore_publish_rollback_output" == *'inspect preserved transaction:'* ]]
restore_publish_transaction="$(compgen -G \
  "$TEST_ROOT/fleet/evidence-transaction/app/restore-evidence.tmp.*")"
[[ -d "$restore_publish_transaction" ]]
for evidence in "$restore_publish_transaction/original"/.sergeant-*; do
  "$REAL_MV" "$evidence" "$TEST_ROOT/evidence-transaction-worker/"
done
rm -rf "$restore_publish_transaction"
rm "$TEST_ROOT/evidence-transaction-worker"/.sergeant-* \
  "$TEST_ROOT/fake-bin/mv"

set +e
restore_cleanup_output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
  SGT_CLEANUP_FAIL_POINT=restore-cleanup \
  FAKE_GIT_LOG="$TEST_ROOT/evidence-removals" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" evidence-transaction app 2>&1)"
restore_cleanup_status=$?
set -e
[[ "$restore_cleanup_status" -ne 0 ]]
[[ "$restore_cleanup_output" == \
  *'CRITICAL: rollback cleanup failed for completed worker evidence restore; inspect preserved artifact:'* ]]
compgen -G "$TEST_ROOT/fleet/evidence-transaction/app/restore-evidence.tmp.*" \
  >/dev/null
[[ "$(cksum "$TEST_ROOT/evidence-transaction-worker"/.sergeant-*)" == \
  "$evidence_live_before" ]]
rm -rf "$TEST_ROOT/fleet/evidence-transaction/app"/restore-evidence.tmp.*
rm "$TEST_ROOT/evidence-transaction-worker"/.sergeant-* \
  "$TEST_ROOT/fake-bin/git"

# Fix 1: first-time cleanup must not bypass ownership even if _configured_repo_root
# returns a root that does not own the worktree.
mkdir -p "$TEST_ROOT/fleet/wrong-owner/app"
init_test_repo "$TEST_ROOT/wrong-owner-repo"
init_test_repo "$TEST_ROOT/wrong-owner-other"
git -C "$TEST_ROOT/wrong-owner-repo" worktree add -q -b wrong-owner-worker \
  "$TEST_ROOT/wrong-owner-sgt-wrong-owner"
cat > "$TEST_ROOT/config/wrong-owner.yaml" <<EOF
name: wrong-owner
repos:
  - name: app
    path: $TEST_ROOT/wrong-owner-other
EOF
printf 'Project: wrong-owner\n' > "$TEST_ROOT/fleet/wrong-owner/brief.md"
printf '%s\n' "$TEST_ROOT/wrong-owner-sgt-wrong-owner" > \
  "$TEST_ROOT/fleet/wrong-owner/app/worktree"
printf 'git\n' > "$TEST_ROOT/fleet/wrong-owner/app/wt_type"
printf 'done\n' > "$TEST_ROOT/fleet/wrong-owner/app/status"
printf 'result\n' > "$TEST_ROOT/fleet/wrong-owner/app/result"
printf 'done\n' > "$TEST_ROOT/wrong-owner-sgt-wrong-owner/.sergeant-status"
printf 'result\n' > "$TEST_ROOT/wrong-owner-sgt-wrong-owner/.sergeant-result"
set +e
wrong_owner_output="$(SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" wrong-owner 2>&1)"
wrong_owner_exit=$?
set -e
[[ "$wrong_owner_exit" -ne 0 ]] || {
  printf 'cleanup accepted mismatched configured owner for first-time cleanup\n' >&2
  exit 1
}
[[ "$wrong_owner_output" == *"configured cleanup owner"* || \
   "$wrong_owner_output" == *"does not belong"* ]] || {
  printf 'no ownership diagnostic for wrong-root first-time cleanup: %s\n' \
    "$wrong_owner_output" >&2
  exit 1
}

# Finding missing-project-config-cleanup-policy/no-yaml:
# First-pass cleanup must fail closed when project config is missing (no brief.md
# Project: line and no task-id-named YAML). No path-derived ownership fallback.
mkdir -p "$TEST_ROOT/fleet/fp-no-project/app"
init_test_repo "$TEST_ROOT/fp-no-project-repo"
git -C "$TEST_ROOT/fp-no-project-repo" worktree add -q -b fp-no-project-worker \
  "$TEST_ROOT/fp-no-project-sgt-fp-no-project"
# No brief.md and no config YAML — must fail closed, not fall back to path-derived root
printf '%s\n' "$TEST_ROOT/fp-no-project-sgt-fp-no-project" > \
  "$TEST_ROOT/fleet/fp-no-project/app/worktree"
printf 'git\n' > "$TEST_ROOT/fleet/fp-no-project/app/wt_type"
printf 'done\n' > "$TEST_ROOT/fleet/fp-no-project/app/status"
printf 'result\n' > "$TEST_ROOT/fleet/fp-no-project/app/result"
printf 'done\n' > "$TEST_ROOT/fp-no-project-sgt-fp-no-project/.sergeant-status"
printf 'result\n' > "$TEST_ROOT/fp-no-project-sgt-fp-no-project/.sergeant-result"
set +e
fp_no_project_output="$(SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" fp-no-project 2>&1)"
fp_no_project_exit=$?
set -e
[[ "$fp_no_project_exit" -ne 0 ]] || {
  printf 'FAIL: first-pass cleanup accepted missing project config (should fail closed)\n' >&2
  exit 1
}
[[ "$fp_no_project_output" == *"configured cleanup owner"* ]] || {
  printf 'FAIL: no ownership diagnostic for missing-project first-pass: %s\n' \
    "$fp_no_project_output" >&2
  exit 1
}
[[ -d "$TEST_ROOT/fp-no-project-sgt-fp-no-project" ]] || {
  printf 'FAIL: worktree removed despite missing project config\n' >&2
  exit 1
}
[[ -d "$TEST_ROOT/fleet/fp-no-project" ]] || {
  printf 'FAIL: fleet state removed despite missing project config\n' >&2
  exit 1
}
printf 'sgt-cleanup first-pass: missing project config rejected: ok\n'

# Finding missing-project-config-cleanup-policy/renamed-repo (git):
# First-pass cleanup must fail closed when the configured repo was renamed in the
# project YAML (Project: is set in brief.md but repo name does not appear in YAML).
mkdir -p "$TEST_ROOT/fleet/fp-renamed-repo/app"
init_test_repo "$TEST_ROOT/fp-renamed-repo-repo"
git -C "$TEST_ROOT/fp-renamed-repo-repo" worktree add -q -b fp-renamed-worker \
  "$TEST_ROOT/fp-renamed-repo-sgt-fp-renamed-repo"
cat > "$TEST_ROOT/config/fp-renamed-repo.yaml" <<EOF
name: fp-renamed-repo
repos:
  - name: old-app-name
    path: $TEST_ROOT/fp-renamed-repo-repo
EOF
printf 'Project: fp-renamed-repo\n' > "$TEST_ROOT/fleet/fp-renamed-repo/brief.md"
printf '%s\n' "$TEST_ROOT/fp-renamed-repo-sgt-fp-renamed-repo" > \
  "$TEST_ROOT/fleet/fp-renamed-repo/app/worktree"
printf 'git\n' > "$TEST_ROOT/fleet/fp-renamed-repo/app/wt_type"
printf 'done\n' > "$TEST_ROOT/fleet/fp-renamed-repo/app/status"
printf 'result\n' > "$TEST_ROOT/fleet/fp-renamed-repo/app/result"
printf 'done\n' > "$TEST_ROOT/fp-renamed-repo-sgt-fp-renamed-repo/.sergeant-status"
printf 'result\n' > "$TEST_ROOT/fp-renamed-repo-sgt-fp-renamed-repo/.sergeant-result"
set +e
fp_renamed_output="$(SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" fp-renamed-repo 2>&1)"
fp_renamed_exit=$?
set -e
[[ "$fp_renamed_exit" -ne 0 ]] || {
  printf 'FAIL: first-pass cleanup accepted renamed repo in project YAML (should fail closed)\n' >&2
  exit 1
}
[[ "$fp_renamed_output" == *"configured cleanup owner"* ]] || {
  printf 'FAIL: no ownership diagnostic for renamed-repo first-pass: %s\n' \
    "$fp_renamed_output" >&2
  exit 1
}
[[ -d "$TEST_ROOT/fp-renamed-repo-sgt-fp-renamed-repo" ]] || {
  printf 'FAIL: worktree removed despite renamed repo in project YAML\n' >&2
  exit 1
}
[[ -d "$TEST_ROOT/fleet/fp-renamed-repo" ]] || {
  printf 'FAIL: fleet state removed despite renamed repo in project YAML\n' >&2
  exit 1
}
printf 'sgt-cleanup first-pass: renamed repo in project YAML rejected: ok\n'

# Finding missing-project-config-cleanup-policy/no-yaml (treehouse):
# First-pass cleanup with wt_type=treehouse must also fail closed when project
# config is missing. The removed path-derived fallback had a treehouse branch;
# verify the fail-closed policy applies regardless of wt_type.
mkdir -p "$TEST_ROOT/fleet/fp-no-project-th/app"
init_test_repo "$TEST_ROOT/fp-no-project-th-repo"
git -C "$TEST_ROOT/fp-no-project-th-repo" worktree add -q -b fp-th-worker \
  "$TEST_ROOT/fp-no-project-th-sgt-fp-no-project-th"
# No brief.md and no config YAML
printf '%s\n' "$TEST_ROOT/fp-no-project-th-sgt-fp-no-project-th" > \
  "$TEST_ROOT/fleet/fp-no-project-th/app/worktree"
printf 'treehouse\n' > "$TEST_ROOT/fleet/fp-no-project-th/app/wt_type"
printf 'sgt-fp-no-project-th-app\n' > \
  "$TEST_ROOT/fleet/fp-no-project-th/app/wt_holder"
printf 'done\n' > "$TEST_ROOT/fleet/fp-no-project-th/app/status"
printf 'result\n' > "$TEST_ROOT/fleet/fp-no-project-th/app/result"
printf 'done\n' > "$TEST_ROOT/fp-no-project-th-sgt-fp-no-project-th/.sergeant-status"
printf 'result\n' > "$TEST_ROOT/fp-no-project-th-sgt-fp-no-project-th/.sergeant-result"
set +e
fp_th_output="$(SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" fp-no-project-th 2>&1)"
fp_th_exit=$?
set -e
[[ "$fp_th_exit" -ne 0 ]] || {
  printf 'FAIL: treehouse first-pass cleanup accepted missing project config (should fail closed)\n' >&2
  exit 1
}
[[ "$fp_th_output" == *"configured cleanup owner"* ]] || {
  printf 'FAIL: no ownership diagnostic for treehouse missing-project first-pass: %s\n' \
    "$fp_th_output" >&2
  exit 1
}
[[ -d "$TEST_ROOT/fp-no-project-th-sgt-fp-no-project-th" ]] || {
  printf 'FAIL: treehouse worktree removed despite missing project config\n' >&2
  exit 1
}
[[ -d "$TEST_ROOT/fleet/fp-no-project-th" ]] || {
  printf 'FAIL: fleet state removed despite treehouse missing project config\n' >&2
  exit 1
}
printf 'sgt-cleanup first-pass (treehouse): missing project config rejected: ok\n'

# Fix 2: absent-worktree cleanup must fail closed when pane/validation_pane
# metadata is present in fleet state, rather than silently proceeding.
# State: partial cleanup reached "removed" phase, worktree absent, validation_pane present.
mkdir -p "$TEST_ROOT/fleet/vp-absent/app"
init_test_repo "$TEST_ROOT/vp-absent-repo"
git -C "$TEST_ROOT/vp-absent-repo" worktree add -q -b vp-absent-worker \
  "$TEST_ROOT/vp-absent-sgt-vp-absent"
record_retry_owner vp-absent app "$TEST_ROOT/vp-absent-repo"
printf '%s\n' "$TEST_ROOT/vp-absent-sgt-vp-absent" > \
  "$TEST_ROOT/fleet/vp-absent/app/worktree"
printf 'git\n' > "$TEST_ROOT/fleet/vp-absent/app/wt_type"
printf 'done\n' > "$TEST_ROOT/fleet/vp-absent/app/status"
printf 'result\n' > "$TEST_ROOT/fleet/vp-absent/app/result"
printf 'done\n' > "$TEST_ROOT/vp-absent-sgt-vp-absent/.sergeant-status"
printf 'result\n' > "$TEST_ROOT/vp-absent-sgt-vp-absent/.sergeant-result"
# Run partial cleanup to get "removed" phase with absent worktree
SGT_CLEANUP_FAIL_POINT=phase-publish-reconciled-absent \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" vp-absent >/dev/null 2>&1 || true
[[ "$(sed -n '1p' "$TEST_ROOT/fleet/vp-absent/app/cleanup-phase")" == "removed" ]]
[[ ! -d "$TEST_ROOT/vp-absent-sgt-vp-absent" ]]
# Now add validation_pane metadata and retry — cleanup should fail closed
printf 'fake-pane-id\n' > "$TEST_ROOT/fleet/vp-absent/app/validation_pane"
set +e
vp_absent_output="$(SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" vp-absent 2>&1)"
vp_absent_exit=$?
set -e
[[ "$vp_absent_exit" -ne 0 ]] || {
  printf 'cleanup succeeded without stopping validation pane when worktree absent\n' >&2
  exit 1
}
[[ "$vp_absent_output" == *"validation"* || "$vp_absent_output" == *"pane"* ]] || {
  printf 'no pane diagnostic for absent-worktree validation_pane case: %s\n' \
    "$vp_absent_output" >&2
  exit 1
}

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
tmux display-message -p -t "$worker_pane" \
  '#{pane_dead}|#{pane_id}|#{pane_pid}|#{pane_created}|#{pane_start_command}' \
  > "$repo_state/pane_identity"

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

# Clean up any leftover repo state from the previous task-123 tmux section
rm -rf "$TEST_ROOT/repo" "$TEST_ROOT/repo-sgt-task-123"
tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

mkdir -p "$TEST_ROOT/fleet/task-123/app" "$TEST_ROOT/repo"
cat > "$TEST_ROOT/config/task-123.yaml" <<EOF
name: task-123
repos:
  - name: app
    path: $TEST_ROOT/repo
EOF
printf 'Project: task-123\n' > "$TEST_ROOT/fleet/task-123/brief.md"
git -C "$TEST_ROOT/repo" init -q
git -C "$TEST_ROOT/repo" config user.name Test
git -C "$TEST_ROOT/repo" config user.email test@example.invalid
touch "$TEST_ROOT/repo/README.md"
git -C "$TEST_ROOT/repo" add README.md
git -C "$TEST_ROOT/repo" commit -qm fixture

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

init_test_repo "$TEST_ROOT/col-base"
col_a_worktree="$TEST_ROOT/col-base-sgt-col-a"
col_ab_worktree="$TEST_ROOT/col-base-sgt-col-ab"
xcol_a_worktree="$TEST_ROOT/col-base-sgt-xcol-a"
mkdir -p "$TEST_ROOT/fleet/col-a/app" "$TEST_ROOT/fleet/col-ab/app" \
  "$TEST_ROOT/fleet/xcol-a/app"
record_retry_owner col-a app "$TEST_ROOT/col-base"
record_retry_owner col-ab app "$TEST_ROOT/col-base"
record_retry_owner xcol-a app "$TEST_ROOT/col-base"
git -C "$TEST_ROOT/col-base" worktree add -q -b col-a-branch "$col_a_worktree"
git -C "$TEST_ROOT/col-base" worktree add -q -b col-ab-branch "$col_ab_worktree"
git -C "$TEST_ROOT/col-base" worktree add -q -b xcol-a-branch "$xcol_a_worktree"
record_retry_owner col-a app "$TEST_ROOT/col-base"
record_retry_owner col-ab app "$TEST_ROOT/col-base"
record_retry_owner xcol-a app "$TEST_ROOT/col-base"

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
recycled_worktree="$TEST_ROOT/recycled-pane-sgt-recycled-pane"
mkdir -p "$recycled_state" "$TEST_ROOT/recycled-bin"
init_test_repo "$TEST_ROOT/recycled-pane-repo"
git -C "$TEST_ROOT/recycled-pane-repo" worktree add -q -b recycled-pane-worker \
  "$recycled_worktree"
record_retry_owner recycled-pane app "$TEST_ROOT/recycled-pane-repo"
printf 'done\n'   > "$recycled_state/status"
printf 'result\n' > "$recycled_state/result"
printf '%s\n' "$recycled_worktree" > "$recycled_state/worktree"
printf 'git\n' > "$recycled_state/wt_type"
printf 'done\n' > "$recycled_worktree/.sergeant-status"
printf 'result\n' > "$recycled_worktree/.sergeant-result"
SGT_CLEANUP_FAIL_POINT=phase-publish-reconciled-absent \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" recycled-pane >/dev/null 2>&1 || true
[[ "$(sed -n '1p' "$recycled_state/cleanup-phase")" == "removed" ]]
[[ ! -d "$recycled_worktree" ]]

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

# Cleanup must FAIL: Finding 1 requires cleanup to die if the worker pane is
# still active after _stop_local_worker (identity mismatch causes kill to be
# skipped, leaving an active pane that has not been verified as owned).
[[ "$recycled_status" -ne 0 ]] || {
  printf 'recycled-pane cleanup succeeded unexpectedly (pane still active after stop)\n' >&2
  exit 1
}
# The recycled pane must NOT have been killed: identity mismatch must have
# caused _stop_local_worker to skip with "recorded pane no longer belongs", not
# invoke kill-pane.
[[ ! -e "$TEST_ROOT/recycled-kills.log" ]] || {
  printf 'recycled pane was incorrectly killed (pane identity not checked exactly):\n%s\n' \
    "$(cat "$TEST_ROOT/recycled-kills.log")" >&2
  exit 1
}
grep -Fq 'recorded pane no longer belongs to this worker' "$TEST_ROOT/recycled-pane.log"
grep -Fq 'Worker pane still active after stop' "$TEST_ROOT/recycled-pane.log"
[[ -d "$TEST_ROOT/fleet/recycled-pane" ]]

# === PR14-F2 regression: escaped descendant terminated after pane exits ===
# Scenario: the worker pane exits BEFORE cleanup runs.  The escaped descendant
# ignores SIGTERM/SIGHUP and has changed CWD away from the worktree, so neither
# the tree-records (empty — pane dead) nor the CWD guard catch it.
# sgt-interactive-worker records its PGID in fleet state at startup; cleanup
# uses that stored PGID to terminate any surviving process-group members.

escaped_state="$TEST_ROOT/fleet/escaped-task/app"
escaped_worktree="$TEST_ROOT/escaped-repo-sgt-escaped-task"
init_test_repo "$TEST_ROOT/escaped-repo"
mkdir -p "$escaped_state"
record_retry_owner escaped-task app "$TEST_ROOT/escaped-repo"
git -C "$TEST_ROOT/escaped-repo" worktree add -q -b test-escaped "$escaped_worktree"
record_retry_owner escaped-task app "$TEST_ROOT/escaped-repo"
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
init_test_repo "$TEST_ROOT/pid-reuse-repo"
git -C "$TEST_ROOT/pid-reuse-repo" worktree add -q -b pid-reuse-worker \
  "$pid_reuse_worktree"
record_retry_owner pid-reuse-task app "$TEST_ROOT/pid-reuse-repo"
printf '%s\n' "$pid_reuse_worktree" > "$pid_reuse_state/worktree"
printf 'git\n' > "$pid_reuse_state/wt_type"
printf 'done\n' > "$pid_reuse_state/status"
printf 'result\n' > "$pid_reuse_state/result"
printf 'done\n' > "$pid_reuse_worktree/.sergeant-status"
printf 'result\n' > "$pid_reuse_worktree/.sergeant-result"
SGT_CLEANUP_FAIL_POINT=phase-publish-reconciled-absent \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" pid-reuse-task >/dev/null 2>&1 || true
[[ "$(sed -n '1p' "$pid_reuse_state/cleanup-phase")" == "removed" ]]
[[ ! -d "$pid_reuse_worktree" ]]
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
init_test_repo "$TEST_ROOT/nonleader-repo"
git -C "$TEST_ROOT/nonleader-repo" worktree add -q -b nonleader-worker \
  "$nonleader_worktree"
record_retry_owner nonleader-task app "$TEST_ROOT/nonleader-repo"
printf '%s\n' "$nonleader_worktree" > "$nonleader_state/worktree"
printf 'git\n' > "$nonleader_state/wt_type"
printf 'done\n' > "$nonleader_state/status"
printf 'result\n' > "$nonleader_state/result"
printf 'done\n' > "$nonleader_worktree/.sergeant-status"
printf 'result\n' > "$nonleader_worktree/.sergeant-result"
SGT_CLEANUP_FAIL_POINT=phase-publish-reconciled-absent \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" nonleader-task >/dev/null 2>&1 || true
[[ "$(sed -n '1p' "$nonleader_state/cleanup-phase")" == "removed" ]]
[[ ! -d "$nonleader_worktree" ]]
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

# ── Stable identity validation ────────────────────────────────────────────────
# The stable identity token (sentinel + inode/device + remote + root commits)
# excludes volatile state (HEAD, refs, staged/unstaged changes, config) so that
# legitimate retries after new commits are not rejected.

init_retry_repo() {
  local repo_root="$1"
  mkdir -p "$repo_root"
  git -C "$repo_root" init -q
  git -C "$repo_root" config user.name Test
  git -C "$repo_root" config user.email test@example.invalid
  printf 'fixture\n' > "$repo_root/README.md"
  git -C "$repo_root" add README.md
  git -C "$repo_root" commit -qm fixture
}

make_retry_config() {
  local task_id="$1" repo_name="$2" repo_root="$3"
  cat > "$TEST_ROOT/config/$task_id.yaml" <<EOF
name: $task_id
repos:
  - name: $repo_name
    path: $repo_root
EOF
  printf 'Project: %s\n' "$task_id" > "$TEST_ROOT/fleet/$task_id/brief.md"
}

# _capture_identity matches _repo_owner_identity: uses common-dir inode, creates
# sentinel token using _repo_instance_id formula, hashes with _repo_common_instance.
_capture_identity() {
  local repo_root="$1" mode="${2:-}"
  local git_common_dir common_inode_dev common_instance sentinel sentinel_file tmp tmp_token
  git_common_dir="$(git -C "$repo_root" \
    rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  common_inode_dev="$(stat -c '%d:%i' "$git_common_dir" 2>/dev/null || \
    stat -f '%d:%i' "$git_common_dir" 2>/dev/null)"
  common_instance="$(printf '%s\n%s\n' "$git_common_dir" "$common_inode_dev")"
  sentinel_file="$git_common_dir/sergeant-instance"
  if [[ ! -e "$sentinel_file" && "$mode" == "create" ]]; then
    tmp_token="$(printf '%s\n%s\n%s\n%s\n' \
      "$git_common_dir" "$$" "$RANDOM" "$(date +%s)" | git hash-object --stdin)"
    tmp="$(mktemp "$git_common_dir/.sergeant-instance.XXXXXX")"
    printf '%s\n' "$tmp_token" > "$tmp"
    ln "$tmp" "$sentinel_file" 2>/dev/null || true
    rm -f "$tmp"
  fi
  [[ -f "$sentinel_file" ]] || return 1
  sentinel="$(cat "$sentinel_file")"
  printf '%s\n%s\n' "$common_instance" "$sentinel" | \
    git hash-object --stdin
}

# _capture_evidence_identity computes the same hash as _worker_evidence_identity.
_capture_evidence_identity() {
  local evidence_dir="$1"
  (
    cd "$evidence_dir" || exit 1
    export LC_ALL=C
    for evidence in .sergeant-*; do
      [[ -e "$evidence" || -L "$evidence" ]] || continue
      [[ -f "$evidence" && ! -L "$evidence" ]] || exit 1
      printf 'file\n%s\n' "$evidence"
      git hash-object "$evidence" || exit 1
    done
  ) | git hash-object --stdin
}

# write_cleanup_owner_v4 writes a version-4 cleanup-owner with all required fields.
# Args: state_dir task_id repo_root worktree wt_type repo_identity worker_identity evidence_identity [holder]
write_cleanup_owner_v4() {
  local state_dir="$1" task_id="$2" repo_root="$3" worktree="$4" wt_type="$5"
  local repo_identity="$6" worker_identity="$7" evidence_identity="$8" holder="${9:-}"
  printf '4\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$task_id" "$repo_root" "$worktree" "$wt_type" \
    "$repo_identity" "$worker_identity" "$evidence_identity" "$holder" \
    > "$state_dir/cleanup-owner"
}

# run_stable_identity_first_pass runs a first-pass cleanup using a fake git that
# fails at 'worktree remove', causing cleanup to write the cleanup-owner and
# cleanup-phase but exit non-zero. The resulting cleanup-owner contains the
# correct v4 worker and evidence identity hashes for use in retry tests.
# Args: task_id fake_git_log [env vars]
run_stable_identity_first_pass() {
  local task_id="$1" fake_git_log="$2" task_dir config_file
  task_dir="$TEST_ROOT/fleet/$task_id"
  config_file="$TEST_ROOT/config/$task_id.yaml"

  cat > "$TEST_ROOT/fake-bin/git-stable-id" <<'GITEOF'
#!/usr/bin/env bash
case " $* " in
  *" worktree remove "*) printf '%s\n' "${!#}" >> "$FAKE_GIT_LOG"; exit 1 ;;
  *) "$REAL_GIT" "$@" ;;
esac
GITEOF
  chmod +x "$TEST_ROOT/fake-bin/git-stable-id"
  cp "$TEST_ROOT/fake-bin/git-stable-id" "$TEST_ROOT/fake-bin/git"

  PATH="$TEST_ROOT/fake-bin:$PATH" \
    FAKE_GIT_LOG="$fake_git_log" \
    SERGEANT_CONFIG="$TEST_ROOT/config" \
    SERGEANT_FLEET="$TEST_ROOT/fleet" \
    SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-cleanup" "$task_id" >/dev/null 2>&1 || true

  rm -f "$TEST_ROOT/fake-bin/git" "$TEST_ROOT/fake-bin/git-stable-id"
}

# tamper_repo_identity replaces the repo identity field (line 6) in a v4 cleanup-owner.
tamper_repo_identity() {
  local state_dir="$1" new_identity="${2:-wrong-identity-hash}"
  local before line6
  before="$(cat "$state_dir/cleanup-owner")"
  # Lines: 1=4, 2=project, 3=root, 4=worktree, 5=wt_type, 6=repo_identity, 7=worker, 8=evidence, 9=holder
  {
    printf '%s\n' "$before" | sed -n '1,5p'
    printf '%s\n' "$new_identity"
    printf '%s\n' "$before" | sed -n '7,$p'
  } > "$state_dir/cleanup-owner"
}

# Slice 1: tampered cleanup-owner identity is rejected before any destructive step.

tamper_state="$TEST_ROOT/fleet/tamper-retry/app"
mkdir -p "$tamper_state"
init_retry_repo "$TEST_ROOT/tamper-retry"
git -C "$TEST_ROOT/tamper-retry" worktree add -q -b tamper-branch \
  "$TEST_ROOT/tamper-retry-sgt-tamper-retry"
make_retry_config tamper-retry app "$TEST_ROOT/tamper-retry"
printf '%s\n' "$TEST_ROOT/tamper-retry-sgt-tamper-retry" > "$tamper_state/worktree"
printf 'git\n' > "$tamper_state/wt_type"
printf 'done\n' > "$tamper_state/status"
printf 'result\n' > "$tamper_state/result"
printf 'done\n' > "$TEST_ROOT/tamper-retry-sgt-tamper-retry/.sergeant-status"
printf 'result\n' > "$TEST_ROOT/tamper-retry-sgt-tamper-retry/.sergeant-result"
# Run first-pass cleanup to create correct v4 cleanup-owner, then tamper repo identity.
run_stable_identity_first_pass tamper-retry "$TEST_ROOT/tamper-removals"
[[ -f "$tamper_state/cleanup-owner" && -f "$tamper_state/cleanup-phase" ]] || {
  printf 'first-pass cleanup did not create cleanup-owner/cleanup-phase\n' >&2; exit 1
}
tamper_repo_identity "$tamper_state" wrong-identity-hash
set +e
SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" tamper-retry \
  > "$TEST_ROOT/tamper-retry.log" 2>&1
tamper_status=$?
set -e
[[ "$tamper_status" -ne 0 ]] || {
  printf 'cleanup accepted tampered owner identity\n' >&2; exit 1
}
grep -E 'Retry owner repo identity changed|Cannot identify retry owner repo|Retry worker worktree identity changed|Retry persisted terminal evidence' \
  "$TEST_ROOT/tamper-retry.log" >/dev/null || {
  printf 'unexpected tamper error: %s\n' "$(cat "$TEST_ROOT/tamper-retry.log")" >&2; exit 1
}
[[ -d "$TEST_ROOT/tamper-retry-sgt-tamper-retry" ]]
[[ -d "$TEST_ROOT/fleet/tamper-retry" ]]

printf 'sgt-cleanup stable identity: tampered retry rejected\n'

# Slice 2: valid first-pass cleanup with real repo succeeds.

mkdir -p "$TEST_ROOT/fleet/valid-retry"
init_retry_repo "$TEST_ROOT/valid-retry"
git -C "$TEST_ROOT/valid-retry" worktree add -q -b valid-branch \
  "$TEST_ROOT/valid-retry-sgt-valid-retry"
make_retry_config valid-retry app "$TEST_ROOT/valid-retry"
mkdir -p "$TEST_ROOT/fleet/valid-retry/app"
printf '%s\n' "$TEST_ROOT/valid-retry-sgt-valid-retry" \
  > "$TEST_ROOT/fleet/valid-retry/app/worktree"
printf 'git\n' > "$TEST_ROOT/fleet/valid-retry/app/wt_type"
printf 'done\n' > "$TEST_ROOT/fleet/valid-retry/app/status"
printf 'result\n' > "$TEST_ROOT/fleet/valid-retry/app/result"
printf 'done\n' > "$TEST_ROOT/valid-retry-sgt-valid-retry/.sergeant-status"
printf 'result\n' > "$TEST_ROOT/valid-retry-sgt-valid-retry/.sergeant-result"
SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" valid-retry >/dev/null
[[ ! -e "$TEST_ROOT/valid-retry-sgt-valid-retry" ]]
[[ ! -e "$TEST_ROOT/fleet/valid-retry" ]]

printf 'sgt-cleanup stable identity: valid first-pass cleanup ok\n'

# Slice 3: same-origin clone replacement (absent-worktree path) is rejected.
# The new clone has no sentinel file → identity differs → rejected.

clone_state="$TEST_ROOT/fleet/clone-retry/app"
mkdir -p "$TEST_ROOT/fleet/clone-retry"
init_retry_repo "$TEST_ROOT/clone-retry"
make_retry_config clone-retry app "$TEST_ROOT/clone-retry"
mkdir -p "$clone_state"
# Create a git worktree as the "worker" (just for the sentinel to be created).
git -C "$TEST_ROOT/clone-retry" worktree add -q -b clone-worker \
  "$TEST_ROOT/clone-retry-sgt-clone-retry"
printf '%s\n' "$TEST_ROOT/clone-retry-sgt-clone-retry" > "$clone_state/worktree"
printf 'git\n' > "$clone_state/wt_type"
printf 'done\n' > "$clone_state/status"
printf 'result\n' > "$clone_state/result"
printf 'done\n' > "$TEST_ROOT/clone-retry-sgt-clone-retry/.sergeant-status"
printf 'result\n' > "$TEST_ROOT/clone-retry-sgt-clone-retry/.sergeant-result"
# First-pass: creates correct v4 cleanup-owner, fails at worktree remove.
run_stable_identity_first_pass clone-retry "$TEST_ROOT/clone-removals"
[[ -f "$clone_state/cleanup-owner" ]] || {
  printf 'first-pass did not create cleanup-owner for clone-retry\n' >&2; exit 1
}
# Simulate "absent worktree" retry by removing the worktree directory.
git -C "$TEST_ROOT/clone-retry" worktree remove "$TEST_ROOT/clone-retry-sgt-clone-retry" 2>/dev/null || \
  rm -rf "$TEST_ROOT/clone-retry-sgt-clone-retry"
# Now replace the repo with a fresh clone (no sentinel file).
rm -rf "$TEST_ROOT/clone-retry"
init_retry_repo "$TEST_ROOT/clone-retry"
set +e
SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" clone-retry \
  > "$TEST_ROOT/clone-retry.log" 2>&1
clone_status=$?
set -e
[[ "$clone_status" -ne 0 ]] || {
  printf 'cleanup accepted same-origin clone replacement\n' >&2; exit 1
}
grep -E 'Retry owner repo identity changed|Cannot identify retry owner repo' \
  "$TEST_ROOT/clone-retry.log" >/dev/null || {
  printf 'unexpected clone error: %s\n' "$(cat "$TEST_ROOT/clone-retry.log")" >&2; exit 1
}
[[ -d "$TEST_ROOT/fleet/clone-retry" ]]

printf 'sgt-cleanup stable identity: same-origin clone replacement rejected\n'

# Slice 4: HEAD/ref changes do NOT invalidate a valid retry (stable identity).

head_change_state="$TEST_ROOT/fleet/head-change/app"
mkdir -p "$TEST_ROOT/fleet/head-change"
init_retry_repo "$TEST_ROOT/head-change"
git -C "$TEST_ROOT/head-change" worktree add -q -b head-branch \
  "$TEST_ROOT/head-change-sgt-head-change"
make_retry_config head-change app "$TEST_ROOT/head-change"
mkdir -p "$head_change_state"
printf '%s\n' "$TEST_ROOT/head-change-sgt-head-change" > "$head_change_state/worktree"
printf 'git\n' > "$head_change_state/wt_type"
printf 'done\n' > "$head_change_state/status"
printf 'result\n' > "$head_change_state/result"
printf 'done\n' > "$TEST_ROOT/head-change-sgt-head-change/.sergeant-status"
printf 'result\n' > "$TEST_ROOT/head-change-sgt-head-change/.sergeant-result"
mkdir -p "$head_change_state/terminal-evidence"
cp "$TEST_ROOT/head-change-sgt-head-change/.sergeant-status" \
  "$head_change_state/terminal-evidence/.sergeant-status"
cp "$TEST_ROOT/head-change-sgt-head-change/.sergeant-result" \
  "$head_change_state/terminal-evidence/.sergeant-result"
original_head_identity="$(_capture_identity "$TEST_ROOT/head-change" create)"
evidence_identity="$(_capture_evidence_identity "$head_change_state/terminal-evidence")"
printf '4\nhead-change\n%s\n%s\ngit\n%s\nabsent\n%s\n\n' \
  "$TEST_ROOT/head-change" \
  "$TEST_ROOT/head-change-sgt-head-change" \
  "$original_head_identity" \
  "$evidence_identity" \
  > "$head_change_state/cleanup-owner"
printf 'removed\n%s\ngit\n%s\n' \
  "$TEST_ROOT/head-change-sgt-head-change" \
  "$TEST_ROOT/head-change" \
  > "$head_change_state/cleanup-phase"
git -C "$TEST_ROOT/head-change" worktree remove --force "$TEST_ROOT/head-change-sgt-head-change"
printf 'new content\n' >> "$TEST_ROOT/head-change/README.md"
git -C "$TEST_ROOT/head-change" add README.md
git -C "$TEST_ROOT/head-change" commit -qm 'new commit'
git -C "$TEST_ROOT/head-change" tag new-ref HEAD
SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" head-change >/dev/null || {
  printf 'cleanup rejected valid retry after HEAD/ref change\n' >&2; exit 1
}
[[ ! -e "$TEST_ROOT/fleet/head-change" ]]

printf 'sgt-cleanup stable identity: HEAD/ref change does not invalidate retry\n'

# Slice 5: in-place remote URL change does NOT invalidate a retry (remote is not
# part of stable owner identity — only common-dir inode and instance token are used).

remote_change_state="$TEST_ROOT/fleet/remote-change/app"
mkdir -p "$TEST_ROOT/fleet/remote-change"
init_retry_repo "$TEST_ROOT/remote-change"
git -C "$TEST_ROOT/remote-change" remote add origin https://example.com/original.git
git -C "$TEST_ROOT/remote-change" worktree add -q -b remote-branch \
  "$TEST_ROOT/remote-change-sgt-remote-change"
make_retry_config remote-change app "$TEST_ROOT/remote-change"
mkdir -p "$remote_change_state"
printf '%s\n' "$TEST_ROOT/remote-change-sgt-remote-change" \
  > "$remote_change_state/worktree"
printf 'git\n' > "$remote_change_state/wt_type"
printf 'done\n' > "$remote_change_state/status"
printf 'result\n' > "$remote_change_state/result"
printf 'done\n' > "$TEST_ROOT/remote-change-sgt-remote-change/.sergeant-status"
printf 'result\n' > "$TEST_ROOT/remote-change-sgt-remote-change/.sergeant-result"
# First-pass: creates correct v4 cleanup-owner, fails at worktree remove.
run_stable_identity_first_pass remote-change "$TEST_ROOT/remote-removals"
[[ -f "$remote_change_state/cleanup-owner" ]] || {
  printf 'first-pass did not create cleanup-owner for remote-change\n' >&2; exit 1
}
git -C "$TEST_ROOT/remote-change" remote set-url origin https://example.com/replaced.git
SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" remote-change >/dev/null || {
  printf 'cleanup rejected retry after remote URL change (should be allowed)\n' >&2; exit 1
}
[[ ! -e "$TEST_ROOT/fleet/remote-change" ]] || {
  printf 'fleet state not removed after remote-change cleanup\n' >&2; exit 1
}

printf 'sgt-cleanup stable identity: in-place remote URL change does not invalidate retry\n'

# Slice 6: root-commit-changing reset (orphan branch) is rejected.

root_change_state="$TEST_ROOT/fleet/root-change/app"
mkdir -p "$TEST_ROOT/fleet/root-change"
init_retry_repo "$TEST_ROOT/root-change"
git -C "$TEST_ROOT/root-change" worktree add -q -b root-branch \
  "$TEST_ROOT/root-change-sgt-root-change"
make_retry_config root-change app "$TEST_ROOT/root-change"
mkdir -p "$root_change_state"
printf '%s\n' "$TEST_ROOT/root-change-sgt-root-change" > "$root_change_state/worktree"
printf 'git\n' > "$root_change_state/wt_type"
printf 'done\n' > "$root_change_state/status"
printf 'result\n' > "$root_change_state/result"
printf 'done\n' > "$TEST_ROOT/root-change-sgt-root-change/.sergeant-status"
printf 'result\n' > "$TEST_ROOT/root-change-sgt-root-change/.sergeant-result"
# First-pass: creates correct v4 cleanup-owner, fails at worktree remove.
run_stable_identity_first_pass root-change "$TEST_ROOT/root-removals"
[[ -f "$root_change_state/cleanup-owner" ]] || {
  printf 'first-pass did not create cleanup-owner for root-change\n' >&2; exit 1
}
git -C "$TEST_ROOT/root-change" checkout --orphan orphan-root -q
git -C "$TEST_ROOT/root-change" rm -rf . -q
printf 'orphan root\n' > "$TEST_ROOT/root-change/orphan.md"
git -C "$TEST_ROOT/root-change" add orphan.md
git -C "$TEST_ROOT/root-change" commit -qm 'orphan root'
SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" root-change >/dev/null || {
  printf 'cleanup rejected retry after root-commit change (should be allowed)\n' >&2; exit 1
}
[[ ! -e "$TEST_ROOT/fleet/root-change" ]] || {
  printf 'fleet state not removed after root-change cleanup\n' >&2; exit 1
}

printf 'sgt-cleanup stable identity: root-commit-changing reset does not invalidate retry\n'

# Slice 7: configured linked worktree (repo has .git as a file) succeeds.

mkdir -p "$TEST_ROOT/fleet/stable-linked/app"
init_retry_repo "$TEST_ROOT/stable-linked-main"
git -C "$TEST_ROOT/stable-linked-main" worktree add -q -b stable-linked-configured \
  "$TEST_ROOT/stable-linked"
[[ -f "$TEST_ROOT/stable-linked/.git" ]] || {
  printf 'Fixture error: stable-linked .git is not a file\n' >&2; exit 1
}
git -C "$TEST_ROOT/stable-linked" worktree add -q -b stable-linked-worker \
  "$TEST_ROOT/stable-linked-sgt-stable-linked"
make_retry_config stable-linked app "$TEST_ROOT/stable-linked"
printf '%s\n' "$TEST_ROOT/stable-linked-sgt-stable-linked" \
  > "$TEST_ROOT/fleet/stable-linked/app/worktree"
printf 'git\n' > "$TEST_ROOT/fleet/stable-linked/app/wt_type"
printf 'done\n' > "$TEST_ROOT/fleet/stable-linked/app/status"
printf 'result\n' > "$TEST_ROOT/fleet/stable-linked/app/result"
printf 'done\n' > "$TEST_ROOT/stable-linked-sgt-stable-linked/.sergeant-status"
printf 'result\n' > "$TEST_ROOT/stable-linked-sgt-stable-linked/.sergeant-result"
SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" stable-linked >/dev/null || {
  printf 'cleanup failed for linked-worktree configured repo\n' >&2; exit 1
}
[[ ! -e "$TEST_ROOT/stable-linked-sgt-stable-linked" ]]
[[ ! -e "$TEST_ROOT/fleet/stable-linked" ]]

printf 'sgt-cleanup stable identity: linked-worktree configured repo ok\n'

# Positive-path partial-removal retry: a worktree directory was removed but the
# git command failed after that (partial removal).  After pruning the git registry,
# cleanup must reconcile the absence and remove fleet state.
mkdir -p "$TEST_ROOT/fleet/partial-retry-complete/app"
init_test_repo "$TEST_ROOT/partial-retry-complete"
git -C "$TEST_ROOT/partial-retry-complete" worktree add -q -b partial-retry-worker \
  "$TEST_ROOT/partial-retry-complete-sgt-partial-retry-complete"
record_retry_owner partial-retry-complete app "$TEST_ROOT/partial-retry-complete"
printf '%s\n' "$TEST_ROOT/partial-retry-complete-sgt-partial-retry-complete" > \
  "$TEST_ROOT/fleet/partial-retry-complete/app/worktree"
printf 'done\n' > "$TEST_ROOT/fleet/partial-retry-complete/app/status"
printf 'result\n' > "$TEST_ROOT/fleet/partial-retry-complete/app/result"
printf 'done\n' > \
  "$TEST_ROOT/partial-retry-complete-sgt-partial-retry-complete/.sergeant-status"
printf 'result\n' > \
  "$TEST_ROOT/partial-retry-complete-sgt-partial-retry-complete/.sergeant-result"
# Save the current fake-bin/git and create a partial-removal variant
if [[ -f "$TEST_ROOT/fake-bin/git" ]]; then
  cp -p "$TEST_ROOT/fake-bin/git" "$TEST_ROOT/fake-bin/git.saved"
else
  printf '#!/usr/bin/env bash\n"$REAL_GIT" "$@"\n' > "$TEST_ROOT/fake-bin/git.saved"
  chmod +x "$TEST_ROOT/fake-bin/git.saved"
fi
cat > "$TEST_ROOT/fake-bin/git" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" rev-list "*|*" for-each-ref "*|*" config --get remote.origin.url "*|*" status --porcelain=v1 "*|*" diff "*|*" ls-files "*|*" hash-object "*) "$REAL_GIT" "$@" ;;
  *" rev-parse --is-inside-work-tree "*) printf 'true\n' ;;
  *" rev-parse "*) "$REAL_GIT" "$@" ;;
  *" status "*) ;;
  *" check-ref-format "*|*" worktree list --porcelain -z "*) "$REAL_GIT" "$@" ;;
  *" worktree remove "*)
    rm -rf "${!#}"
    exit 1
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/git"
if PATH="$TEST_ROOT/fake-bin:$PATH" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" partial-retry-complete >/dev/null 2>&1; then
  printf 'partial-retry-complete initial cleanup unexpectedly succeeded\n' >&2; exit 1
fi
[[ ! -e "$TEST_ROOT/partial-retry-complete-sgt-partial-retry-complete" ]]
[[ "$(sed -n '1p' "$TEST_ROOT/fleet/partial-retry-complete/app/cleanup-phase")" == \
  "partial-removal" ]] || {
  printf 'partial-removal phase not recorded after failed worktree removal\n' >&2; exit 1
}
# Prune git registry to prove removal completed, then retry → must reconcile
"$REAL_GIT" -C "$TEST_ROOT/partial-retry-complete" worktree prune --expire now
SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" partial-retry-complete >/dev/null || {
  printf 'partial-retry-complete reconcile failed\n' >&2; exit 1
}
[[ ! -e "$TEST_ROOT/fleet/partial-retry-complete" ]] || {
  printf 'fleet state not removed after partial-removal reconcile\n' >&2; exit 1
}
mv "$TEST_ROOT/fake-bin/git.saved" "$TEST_ROOT/fake-bin/git"

# dirty-owner-retry: verify that unstaged changes to the configured owner repo
# invalidate a retry. The new _repo_identity includes worktree state
# (_repo_worktree_identity runs git diff HEAD), so content changes change the
# stored identity hash. A retry must be rejected when the owner's state differs.
rm -rf "$TEST_ROOT/dirty-owner-retry-sgt-dirty-owner-retry"
mkdir -p "$TEST_ROOT/fleet/dirty-owner-retry/app" \
  "$TEST_ROOT/fake-bin"
init_test_repo "$TEST_ROOT/dirty-owner-retry"
git -C "$TEST_ROOT/dirty-owner-retry" worktree add -q -b dirty-owner-retry-worker \
  "$TEST_ROOT/dirty-owner-retry-sgt-dirty-owner-retry"
record_retry_owner dirty-owner-retry app "$TEST_ROOT/dirty-owner-retry"
printf '%s\n' "$TEST_ROOT/dirty-owner-retry-sgt-dirty-owner-retry" > \
  "$TEST_ROOT/fleet/dirty-owner-retry/app/worktree"
printf 'done\n' > "$TEST_ROOT/fleet/dirty-owner-retry/app/status"
printf 'result\n' > "$TEST_ROOT/fleet/dirty-owner-retry/app/result"
printf 'done\n' > "$TEST_ROOT/dirty-owner-retry-sgt-dirty-owner-retry/.sergeant-status"
printf 'result\n' > "$TEST_ROOT/dirty-owner-retry-sgt-dirty-owner-retry/.sergeant-result"
cat > "$TEST_ROOT/fake-bin/git" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" worktree remove "*) printf '%s\n' "${!#}" >> "$FAKE_GIT_LOG"; exit 1 ;;
esac
"$REAL_GIT" "$@"
EOF
chmod +x "$TEST_ROOT/fake-bin/git"
# First cleanup: fake git fails — records cleanup-phase=removing + cleanup-owner
if PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_GIT_LOG="$TEST_ROOT/dirty-owner-retry-removals" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" dirty-owner-retry >/dev/null 2>&1; then
  printf 'cleanup succeeded on fake-git failure (unexpected)\n' >&2
  exit 1
fi
[[ -f "$TEST_ROOT/fleet/dirty-owner-retry/app/cleanup-owner" ]] || {
  printf 'cleanup-owner not recorded after first failed attempt\n' >&2
  exit 1
}
# Modify the owner repo's working tree — identity must now differ
printf 'dirty content added after owner record\n' >> "$TEST_ROOT/dirty-owner-retry/README.md"
# Retry: must be rejected because identity changed
if PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_GIT_LOG="$TEST_ROOT/dirty-owner-retry-removals" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" dirty-owner-retry >/dev/null 2>&1; then
  printf 'cleanup accepted dirty-owner retry with changed identity (unexpected)\n' >&2
  exit 1
fi
[[ -e "$TEST_ROOT/fleet/dirty-owner-retry" ]] || {
  printf 'fleet state unexpectedly removed after rejected retry\n' >&2
  exit 1
}
rm "$TEST_ROOT/fake-bin/git"
printf 'sgt-cleanup dirty-owner-retry: changed identity correctly rejected\n'

# ── Issue #21: remove dead remain-on-exit worker panes ───────────────────────
# When a worker pane has pane_dead=1 (tmux remain-on-exit), cleanup must call
# kill-pane to remove the zombie pane, not just skip it silently.

roi_state="$TEST_ROOT/fleet/roi-task/app"
roi_worktree="$TEST_ROOT/roi-worktree"
mkdir -p "$roi_state"
init_test_repo "$TEST_ROOT/roi-source"
git -C "$TEST_ROOT/roi-source" worktree add -q -b roi-branch "$roi_worktree"

cat > "$TEST_ROOT/config/roi-task.yaml" <<EOF
name: roi-task
repos:
  - name: app
    path: $TEST_ROOT/roi-source
EOF
printf 'Project: roi-task\nBrief: remain-on-exit test\nBranch: roi-branch\nRepos: app\n' \
  > "$TEST_ROOT/fleet/roi-task/brief.md"
printf '%s\n' "$roi_worktree" > "$roi_state/worktree"
cat "$roi_worktree/.git" > "$roi_state/worktree_git_pointer"
_wt_gd="$(sed 's/^gitdir: //' "$roi_worktree/.git")"
printf '%s\n' "$(cd "$_wt_gd" && pwd -P)" > "$roi_state/worktree_git_dir"
printf '%s\n' "$(git -C "$roi_worktree" rev-parse HEAD)" > "$roi_state/validation_head"
printf 'done\n' > "$roi_state/status"
printf 'done\n' > "$roi_worktree/.sergeant-status"
printf 'result\n' > "$roi_state/result"
printf 'result\n' > "$roi_worktree/.sergeant-result"
printf 'git\n' > "$roi_state/wt_type"
# Recorded pane — pane_dead=1 (remain-on-exit dead pane)
roi_dead_pane="%roi99"
printf '%s\n' "$roi_dead_pane" > "$roi_state/pane"
printf '%s\n' "1|${roi_dead_pane}|9999|2025-01-01T00:00:00|remain-on-exit-cmd" > "$roi_state/pane_identity"
chmod 600 "$roi_state/pane_identity"
printf 'sgt\n' > "$roi_state/tmux_session"
printf 'roi-task/app\n' > "$roi_state/window_name"

roi_tmux_log="$TEST_ROOT/roi-tmux.log"
cat > "$TEST_ROOT/fake-bin/tmux-roi" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ROI_TMUX_LOG"
case "$1" in
  display-message)
    # Pane is dead (remain-on-exit): pane_dead=1
    printf '1|%roi99|9999|2025-01-01T00:00:00|remain-on-exit-cmd\n'
    ;;
  kill-pane|new-window|send-keys|rename-window) exit 0 ;;
  has-session) exit 0 ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/tmux-roi"

# Symlink as 'tmux' for this test
ln -sf "$TEST_ROOT/fake-bin/tmux-roi" "$TEST_ROOT/fake-bin/tmux-roi-link"

ROI_TMUX_LOG="$roi_tmux_log" \
  HOME="$TEST_ROOT/home" PATH="$TEST_ROOT/fake-bin:$PATH" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  TMUX_SESSION="sgt" \
  bash -c '
    PATH="'"$TEST_ROOT/fake-bin"':$PATH"
    # Override tmux to tmux-roi-link for this subshell
    ln -sf "'"$TEST_ROOT/fake-bin/tmux-roi"'" "'"$TEST_ROOT/fake-bin/tmux"'" 2>/dev/null || true
    ROI_TMUX_LOG="'"$roi_tmux_log"'" \
    HOME="'"$TEST_ROOT/home"'" \
    SERGEANT_FLEET="'"$TEST_ROOT/fleet"'" SGT_WIKI_DISABLED=1 \
    "'"$ROOT_DIR/bin/sgt-cleanup"'" roi-task >/dev/null 2>&1
  ' || true  # status may vary; we check the log

grep -qF 'kill-pane' "$roi_tmux_log" || {
  printf 'FAIL issue#21: kill-pane was not called on dead remain-on-exit pane\n' >&2
  printf 'tmux log:\n%s\n' "$(cat "$roi_tmux_log")" >&2
  exit 1
}
grep -qF '%roi99' "$roi_tmux_log" || {
  printf 'FAIL issue#21: kill-pane was not called on the correct dead pane %%roi99\n' >&2
  exit 1
}
printf 'sgt-cleanup remain-on-exit dead pane killed: ok\n'

# ── Issue #23: at most one CWD lsof scan per worktree per cleanup run ─────────
# sgt-cleanup was calling _worktree_cwd_pids (which runs lsof) twice for the
# same worktree: once at the end of _stop_local_worker and again in the main
# loop. Count lsof invocations — must be ≤ 2 total for a single-repo task
# (one for main worktree, one for validation worktree if present).

scan_state="$TEST_ROOT/fleet/scan-task/app"
scan_worktree="$TEST_ROOT/scan-worktree"
mkdir -p "$scan_state"
init_test_repo "$TEST_ROOT/scan-source"
git -C "$TEST_ROOT/scan-source" worktree add -q -b scan-branch "$scan_worktree"

cat > "$TEST_ROOT/config/scan-task.yaml" <<EOF
name: scan-task
repos:
  - name: app
    path: $TEST_ROOT/scan-source
EOF
printf 'Project: scan-task\nBrief: cwd scan test\nBranch: scan-branch\nRepos: app\n' \
  > "$TEST_ROOT/fleet/scan-task/brief.md"
printf '%s\n' "$scan_worktree" > "$scan_state/worktree"
cat "$scan_worktree/.git" > "$scan_state/worktree_git_pointer"
_scan_gd="$(sed 's/^gitdir: //' "$scan_worktree/.git")"
printf '%s\n' "$(cd "$_scan_gd" && pwd -P)" > "$scan_state/worktree_git_dir"
printf 'done\n' > "$scan_state/status"
printf 'done\n' > "$scan_worktree/.sergeant-status"
printf 'result\n' > "$scan_state/result"
printf 'result\n' > "$scan_worktree/.sergeant-result"
printf 'git\n' > "$scan_state/wt_type"
# No live pane — worker already gone
printf 'sgt\n' > "$scan_state/tmux_session"
printf 'scan-task/app\n' > "$scan_state/window_name"

lsof_count_file="$TEST_ROOT/lsof_count"
printf '0\n' > "$lsof_count_file"
cat > "$TEST_ROOT/fake-bin/lsof-counting" << 'EOF'
#!/usr/bin/env bash
count=$(cat "$LSOF_COUNT_FILE")
printf '%d\n' $((count + 1)) > "$LSOF_COUNT_FILE"
# Return empty — no processes using the worktree as cwd
exit 0
EOF
chmod +x "$TEST_ROOT/fake-bin/lsof-counting"
ln -sf "$TEST_ROOT/fake-bin/lsof-counting" "$TEST_ROOT/fake-bin/lsof"

LSOF_COUNT_FILE="$lsof_count_file" \
  HOME="$TEST_ROOT/home" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" scan-task >/dev/null 2>&1 || true

scan_count="$(cat "$lsof_count_file")"
[[ "$scan_count" -le 2 ]] || {
  printf 'FAIL issue#23: lsof called %d times for single-repo cleanup; expected ≤ 2\n' \
    "$scan_count" >&2
  exit 1
}
printf 'sgt-cleanup CWD scan count (%d) within limit: ok\n' "$scan_count"
rm -f "$TEST_ROOT/fake-bin/lsof"

# ── Issue #95: orphaned workers with a closed td task ─────────────────────────
# Fake td binary: returns {"status":"<TD_FAKE_STATUS>"} for show --format json.
cat > "$TEST_ROOT/fake-bin/td" << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "show" && "$2" == "--format" && "$3" == "json" ]]; then
  printf '{"status":"%s","id":"%s"}\n' "${TD_FAKE_STATUS:-closed}" "$4"
  exit 0
fi
exit 1
EOF
chmod +x "$TEST_ROOT/fake-bin/td"

# Test A: orphaned + absent worktree + closed td → cleanup must succeed
mkdir -p "$TEST_ROOT/fleet/orphaned-absent-closed/app"
printf 'orphaned\n' > "$TEST_ROOT/fleet/orphaned-absent-closed/app/status"
printf '%s\n' "$TEST_ROOT/orphaned-absent-gone" \
  > "$TEST_ROOT/fleet/orphaned-absent-closed/app/worktree"
printf 'td-orphaned-fake\n' \
  > "$TEST_ROOT/fleet/orphaned-absent-closed/app/td_task"
set +e
_oac_out="$(PATH="$TEST_ROOT/fake-bin:$PATH" TD_FAKE_STATUS=closed \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" orphaned-absent-closed 2>&1)"
_oac_status=$?
set -e
[[ "$_oac_status" -eq 0 ]] || {
  printf 'FAIL issue#95 test-A: orphaned+absent+closed-td was rejected:\n%s\n' \
    "$_oac_out" >&2
  exit 1
}
[[ ! -d "$TEST_ROOT/fleet/orphaned-absent-closed" ]] || {
  printf 'FAIL issue#95 test-A: fleet state not removed after orphaned+absent+closed-td cleanup\n' >&2
  exit 1
}
printf 'sgt-cleanup orphaned+absent+closed-td accepted: ok\n'

# Test B: orphaned + present worktree + closed td → cleanup must succeed
init_test_repo "$TEST_ROOT/orphaned-present-main"
git -C "$TEST_ROOT/orphaned-present-main" worktree add -q -b orphaned-closed-worker \
  "$TEST_ROOT/orphaned-present-main-sgt-orphaned-present-closed"
mkdir -p "$TEST_ROOT/fleet/orphaned-present-closed/app"
record_retry_owner orphaned-present-closed app "$TEST_ROOT/orphaned-present-main"
printf 'orphaned\n' > "$TEST_ROOT/fleet/orphaned-present-closed/app/status"
printf '%s\n' "$TEST_ROOT/orphaned-present-main-sgt-orphaned-present-closed" \
  > "$TEST_ROOT/fleet/orphaned-present-closed/app/worktree"
printf 'td-orphaned-fake\n' \
  > "$TEST_ROOT/fleet/orphaned-present-closed/app/td_task"
printf 'git\n' > "$TEST_ROOT/fleet/orphaned-present-closed/app/wt_type"
printf 'orphaned\n' \
  > "$TEST_ROOT/orphaned-present-main-sgt-orphaned-present-closed/.sergeant-status"
set +e
_opc_out="$(PATH="$TEST_ROOT/fake-bin:$PATH" TD_FAKE_STATUS=closed \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" orphaned-present-closed 2>&1)"
_opc_status=$?
set -e
[[ "$_opc_status" -eq 0 ]] || {
  printf 'FAIL issue#95 test-B: orphaned+present+closed-td was rejected:\n%s\n' \
    "$_opc_out" >&2
  exit 1
}
[[ ! -e "$TEST_ROOT/orphaned-present-main-sgt-orphaned-present-closed" ]] || {
  printf 'FAIL issue#95 test-B: worktree not removed after orphaned+present+closed-td cleanup\n' >&2
  exit 1
}
[[ ! -d "$TEST_ROOT/fleet/orphaned-present-closed" ]] || {
  printf 'FAIL issue#95 test-B: fleet state not removed after orphaned+present+closed-td cleanup\n' >&2
  exit 1
}
printf 'sgt-cleanup orphaned+present+closed-td accepted: ok\n'

# Test B2: orphaned + present worktree + closed td + uncommitted changes →
# must be rejected by _require_clean_worktrees (the "no uncommitted changes"
# guard required by the spec is enforced by this existing check regardless
# of whether the status is orphaned or done).
init_test_repo "$TEST_ROOT/orphaned-dirty-main"
git -C "$TEST_ROOT/orphaned-dirty-main" worktree add -q -b orphaned-dirty-worker \
  "$TEST_ROOT/orphaned-dirty-main-sgt-orphaned-dirty-closed"
mkdir -p "$TEST_ROOT/fleet/orphaned-dirty-closed/app"
record_retry_owner orphaned-dirty-closed app "$TEST_ROOT/orphaned-dirty-main"
printf 'orphaned\n' > "$TEST_ROOT/fleet/orphaned-dirty-closed/app/status"
printf '%s\n' "$TEST_ROOT/orphaned-dirty-main-sgt-orphaned-dirty-closed" \
  > "$TEST_ROOT/fleet/orphaned-dirty-closed/app/worktree"
printf 'td-orphaned-fake\n' \
  > "$TEST_ROOT/fleet/orphaned-dirty-closed/app/td_task"
printf 'git\n' > "$TEST_ROOT/fleet/orphaned-dirty-closed/app/wt_type"
printf 'orphaned\n' \
  > "$TEST_ROOT/orphaned-dirty-main-sgt-orphaned-dirty-closed/.sergeant-status"
# Add an uncommitted tracked change to the worktree
printf 'dirty\n' \
  > "$TEST_ROOT/orphaned-dirty-main-sgt-orphaned-dirty-closed/dirty-file.txt"
set +e
_ob2_out="$(PATH="$TEST_ROOT/fake-bin:$PATH" TD_FAKE_STATUS=closed \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" orphaned-dirty-closed 2>&1)"
_ob2_status=$?
set -e
[[ "$_ob2_status" -ne 0 ]] || {
  printf 'FAIL issue#95 test-B2: cleanup accepted orphaned with uncommitted changes (should reject)\n' >&2
  exit 1
}
[[ "$_ob2_out" == *"uncommitted changes"* ]] || {
  printf 'FAIL issue#95 test-B2: unexpected rejection message: %s\n' "$_ob2_out" >&2
  exit 1
}
[[ -d "$TEST_ROOT/orphaned-dirty-main-sgt-orphaned-dirty-closed" ]] || {
  printf 'FAIL issue#95 test-B2: worktree removed despite uncommitted changes\n' >&2
  exit 1
}
printf 'sgt-cleanup orphaned+present+uncommitted-changes rejected: ok\n'

# Test C: orphaned + absent worktree + open td → must still be rejected
mkdir -p "$TEST_ROOT/fleet/orphaned-absent-open/app"
printf 'orphaned\n' > "$TEST_ROOT/fleet/orphaned-absent-open/app/status"
printf '%s\n' "$TEST_ROOT/orphaned-open-gone" \
  > "$TEST_ROOT/fleet/orphaned-absent-open/app/worktree"
printf 'td-open-fake\n' \
  > "$TEST_ROOT/fleet/orphaned-absent-open/app/td_task"
set +e
_oao_out="$(PATH="$TEST_ROOT/fake-bin:$PATH" TD_FAKE_STATUS=in_progress \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" orphaned-absent-open 2>&1)"
_oao_status=$?
set -e
[[ "$_oao_status" -ne 0 ]] || {
  printf 'FAIL issue#95 test-C: cleanup accepted orphaned with open td (should reject)\n' >&2
  exit 1
}
[[ "$_oao_out" == *"not terminal: orphaned"* ]] || {
  printf 'FAIL issue#95 test-C: unexpected rejection message: %s\n' "$_oao_out" >&2
  exit 1
}
[[ -d "$TEST_ROOT/fleet/orphaned-absent-open" ]] || {
  printf 'FAIL issue#95 test-C: fleet state removed despite rejection\n' >&2
  exit 1
}
printf 'sgt-cleanup orphaned+absent+open-td rejected: ok\n'

# Test D: orphaned + absent worktree + no td_task → must still be rejected
mkdir -p "$TEST_ROOT/fleet/orphaned-no-td/app"
printf 'orphaned\n' > "$TEST_ROOT/fleet/orphaned-no-td/app/status"
printf '%s\n' "$TEST_ROOT/orphaned-no-td-gone" \
  > "$TEST_ROOT/fleet/orphaned-no-td/app/worktree"
# intentionally no td_task file
set +e
_ont_out="$(PATH="$TEST_ROOT/fake-bin:$PATH" TD_FAKE_STATUS=closed \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" orphaned-no-td 2>&1)"
_ont_status=$?
set -e
[[ "$_ont_status" -ne 0 ]] || {
  printf 'FAIL issue#95 test-D: cleanup accepted orphaned with no td_task (should reject)\n' >&2
  exit 1
}
[[ "$_ont_out" == *"not terminal: orphaned"* ]] || {
  printf 'FAIL issue#95 test-D: unexpected rejection message: %s\n' "$_ont_out" >&2
  exit 1
}
printf 'sgt-cleanup orphaned+absent+no-td rejected: ok\n'

rm -f "$TEST_ROOT/fake-bin/td"
printf 'sgt-cleanup: all tests passed\n'
