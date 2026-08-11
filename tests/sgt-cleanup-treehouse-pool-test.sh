#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
REAL_GIT="$(command -v git)"
export REAL_GIT

cleanup_fixture() {
  rm -rf "$TEST_ROOT"
}
trap cleanup_fixture EXIT

init_repo() {
  local repo_root="$1"

  mkdir -p "$repo_root"
  git -C "$repo_root" init -q
  git -C "$repo_root" config user.name Test
  git -C "$repo_root" config user.email test@example.invalid
  printf 'fixture\n' > "$repo_root/README.md"
  git -C "$repo_root" add README.md
  git -C "$repo_root" commit -qm fixture
}

record_task() {
  local task_id="$1" repo_root="$2" worktree="$3" wt_type="$4"
  local state="$TEST_ROOT/fleet/$task_id/app"

  mkdir -p "$state" "$TEST_ROOT/config"
  cat > "$TEST_ROOT/config/$task_id.yaml" <<EOF
name: $task_id
repos:
  - name: app
    path: $repo_root
EOF
  printf 'Project: %s\n' "$task_id" > "$TEST_ROOT/fleet/$task_id/brief.md"
  printf '%s\n' "$worktree" > "$state/worktree"
  printf '%s\n' "$wt_type" > "$state/wt_type"
  if [[ "$wt_type" == treehouse ]]; then
    printf 'sgt-%s-app\n' "$task_id" > "$state/wt_holder"
    printf 'lease-%s\n' "$task_id" > "$state/wt_lease_id"
  fi
  printf 'done\n' > "$state/status"
  printf 'result\n' > "$state/result"
  printf 'done\n' > "$worktree/.sergeant-status"
  printf 'result\n' > "$worktree/.sergeant-result"
}

mkdir -p "$TEST_ROOT/fleet" "$TEST_ROOT/fake-bin" "$TEST_ROOT/home"

init_repo "$TEST_ROOT/treehouse-main"
git -C "$TEST_ROOT/treehouse-main" worktree add -q -b treehouse-worker \
  "$TEST_ROOT/treehouse-pool-checkout"
record_task treehouse-pool "$TEST_ROOT/treehouse-main" \
  "$TEST_ROOT/treehouse-pool-checkout" treehouse

cat > "$TEST_ROOT/fake-bin/treehouse" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == status && "$2" == --json ]]; then
  case "${FAKE_TREEHOUSE_STATUS_MODE:-valid}" in
    empty) printf '[]\n'; exit 0 ;;
    malformed) printf '{bad-json\n'; exit 0 ;;
    constant)
      printf '[{"path":"%s","lease_id":"%s","lease_holder":"%s","processes":NaN}]\n' \
        "$FAKE_TREEHOUSE_PATH" "$FAKE_TREEHOUSE_LEASE_ID" "$FAKE_TREEHOUSE_HOLDER"
      exit 0
      ;;
    invalid_utf8) printf '\377'; exit 0 ;;
    control)
      printf '[{"path":"%s","lease_id":"lease\\u001fbad","lease_holder":"%s"}]\n' \
        "$FAKE_TREEHOUSE_PATH" "$FAKE_TREEHOUSE_HOLDER"
      exit 0
      ;;
    duplicate_field)
      printf '[{"path":"%s","lease_id":"one","lease_id":"%s","lease_holder":"%s"}]\n' \
        "$FAKE_TREEHOUSE_PATH" "$FAKE_TREEHOUSE_LEASE_ID" "$FAKE_TREEHOUSE_HOLDER"
      exit 0
      ;;
    noncanonical)
      printf '[{"path":"%s/../%s","lease_id":"%s","lease_holder":"%s"}]\n' \
        "$FAKE_TREEHOUSE_PATH" "$(basename "$FAKE_TREEHOUSE_PATH")" \
        "$FAKE_TREEHOUSE_LEASE_ID" "$FAKE_TREEHOUSE_HOLDER"
      exit 0
      ;;
    duplicate)
      printf '[{"path":"%s","lease_id":"%s","lease_holder":"%s"},{"path":"%s","lease_id":"%s","lease_holder":"%s"}]\n' \
        "$FAKE_TREEHOUSE_PATH" "$FAKE_TREEHOUSE_LEASE_ID" "$FAKE_TREEHOUSE_HOLDER" \
        "$FAKE_TREEHOUSE_PATH" "$FAKE_TREEHOUSE_LEASE_ID" "$FAKE_TREEHOUSE_HOLDER"
      exit 0
      ;;
  esac
  if [[ -e "$FAKE_TREEHOUSE_ACTIVE" ]]; then
    printf '[{"path":"%s","lease_id":"%s","lease_holder":"%s"}]\n' \
      "$FAKE_TREEHOUSE_PATH" "$FAKE_TREEHOUSE_LEASE_ID" "$FAKE_TREEHOUSE_HOLDER"
  else
    printf '[{"path":"%s","lease_id":"","lease_holder":""}]\n' \
      "$FAKE_TREEHOUSE_PATH"
  fi
  exit 0
fi
if [[ "$1" != return || "$2" != --force || "$3" != --if-lease-id || \
  "$4" != "$FAKE_TREEHOUSE_LEASE_ID" || "$5" != --if-lease-holder || \
  "$6" != "$FAKE_TREEHOUSE_HOLDER" || "$7" != "$FAKE_TREEHOUSE_PATH" ]]; then
  printf 'unsafe return argv: %s\n' "$*" >&2
  exit 64
fi
printf '%s|%s\n' "$PWD" "$*" >> "$FAKE_TREEHOUSE_LOG"
[[ -e "$FAKE_TREEHOUSE_ACTIVE" ]] || exit 42
[[ "${FAKE_TREEHOUSE_RETURN_FAIL:-0}" != 1 ]] || exit 43
rm "$FAKE_TREEHOUSE_ACTIVE"
printf 'Worktree returned to pool.\n'
EOF
chmod +x "$TEST_ROOT/fake-bin/treehouse"
touch "$TEST_ROOT/treehouse-active"

set +e
treehouse_output="$(
  HOME="$TEST_ROOT/home" PATH="$TEST_ROOT/fake-bin:$PATH" \
    FAKE_TREEHOUSE_LOG="$TEST_ROOT/treehouse-return.log" \
    FAKE_TREEHOUSE_ACTIVE="$TEST_ROOT/treehouse-active" \
    FAKE_TREEHOUSE_PATH="$TEST_ROOT/treehouse-pool-checkout" \
    FAKE_TREEHOUSE_LEASE_ID=lease-treehouse-pool \
    FAKE_TREEHOUSE_HOLDER=sgt-treehouse-pool-app \
    SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
    SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-cleanup" treehouse-pool app 2>&1
)"
treehouse_status=$?
set -e
if [[ "$treehouse_status" -ne 0 ]]; then
  printf 'Treehouse pool cleanup failed:\n%s\n' "$treehouse_output" >&2
  exit 1
fi
[[ "$treehouse_output" == *"Worktree returned to pool."* ]]
[[ -d "$TEST_ROOT/treehouse-pool-checkout" ]]
[[ -d "$TEST_ROOT/fleet/treehouse-pool" ]]
[[ "$(sed -n '1p' "$TEST_ROOT/fleet/treehouse-pool/app/cleanup-phase")" == returned ]]
[[ "$(wc -l < "$TEST_ROOT/treehouse-return.log")" -eq 1 ]]
printf 'reused by a later lease\n' > "$TEST_ROOT/treehouse-pool-checkout/README.md"
printf 'later-worker\n' > "$TEST_ROOT/treehouse-pool-checkout/.sergeant-status"

HOME="$TEST_ROOT/home" PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_TREEHOUSE_LOG="$TEST_ROOT/treehouse-return.log" \
  FAKE_TREEHOUSE_ACTIVE="$TEST_ROOT/treehouse-active" \
  FAKE_TREEHOUSE_PATH="$TEST_ROOT/treehouse-pool-checkout" \
  FAKE_TREEHOUSE_LEASE_ID=lease-treehouse-pool \
  FAKE_TREEHOUSE_HOLDER=sgt-treehouse-pool-app \
  SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
  SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" treehouse-pool app >/dev/null
[[ "$(wc -l < "$TEST_ROOT/treehouse-return.log")" -eq 1 ]]

HOME="$TEST_ROOT/home" PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_TREEHOUSE_LOG="$TEST_ROOT/treehouse-return.log" \
  FAKE_TREEHOUSE_ACTIVE="$TEST_ROOT/treehouse-active" \
  FAKE_TREEHOUSE_PATH="$TEST_ROOT/treehouse-pool-checkout" \
  FAKE_TREEHOUSE_LEASE_ID=lease-treehouse-pool \
  FAKE_TREEHOUSE_HOLDER=sgt-treehouse-pool-app \
  SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
  SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" treehouse-pool >/dev/null
[[ ! -e "$TEST_ROOT/fleet/treehouse-pool" ]]
printf 'sgt-cleanup accepts a successful Treehouse pool return: ok\n'

init_repo "$TEST_ROOT/unowned-treehouse-main"
git -C "$TEST_ROOT/unowned-treehouse-main" worktree add -q \
  -b unowned-treehouse-worker "$TEST_ROOT/unowned-treehouse-pool-checkout"
record_task unowned-treehouse "$TEST_ROOT/unowned-treehouse-main" \
  "$TEST_ROOT/unowned-treehouse-pool-checkout" treehouse
printf 'another-holder\n' > \
  "$TEST_ROOT/fleet/unowned-treehouse/app/wt_holder"

set +e
unowned_output="$(
  HOME="$TEST_ROOT/home" PATH="$TEST_ROOT/fake-bin:$PATH" \
    FAKE_TREEHOUSE_LOG="$TEST_ROOT/treehouse-return.log" \
    FAKE_TREEHOUSE_ACTIVE="$TEST_ROOT/unowned-treehouse-active" \
    FAKE_TREEHOUSE_PATH="$TEST_ROOT/unowned-treehouse-pool-checkout" \
    FAKE_TREEHOUSE_LEASE_ID=lease-unowned-treehouse \
    FAKE_TREEHOUSE_HOLDER=sgt-unowned-treehouse-app \
    SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
    SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-cleanup" unowned-treehouse 2>&1
)"
unowned_status=$?
set -e
[[ "$unowned_status" -ne 0 ]]
[[ "$unowned_output" == *"Treehouse lease identity does not match its fleet owner"* ]]
[[ "$(wc -l < "$TEST_ROOT/treehouse-return.log")" -eq 1 ]]
[[ -d "$TEST_ROOT/unowned-treehouse-pool-checkout" ]]
[[ -d "$TEST_ROOT/fleet/unowned-treehouse" ]]
[[ -f "$TEST_ROOT/unowned-treehouse-pool-checkout/.sergeant-status" ]]
printf 'sgt-cleanup rejects an unverified Treehouse holder before return: ok\n'

init_repo "$TEST_ROOT/mismatch-main"
git -C "$TEST_ROOT/mismatch-main" worktree add -q -b mismatch-worker \
  "$TEST_ROOT/mismatch-pool-checkout"
record_task lease-mismatch "$TEST_ROOT/mismatch-main" \
  "$TEST_ROOT/mismatch-pool-checkout" treehouse
printf 'captured-wrong-lease\n' > "$TEST_ROOT/fleet/lease-mismatch/app/wt_lease_id"
touch "$TEST_ROOT/mismatch-active"
return_count="$(wc -l < "$TEST_ROOT/treehouse-return.log")"
set +e
mismatch_output="$(
  HOME="$TEST_ROOT/home" PATH="$TEST_ROOT/fake-bin:$PATH" \
    FAKE_TREEHOUSE_LOG="$TEST_ROOT/treehouse-return.log" \
    FAKE_TREEHOUSE_ACTIVE="$TEST_ROOT/mismatch-active" \
    FAKE_TREEHOUSE_PATH="$TEST_ROOT/mismatch-pool-checkout" \
    FAKE_TREEHOUSE_LEASE_ID=actual-live-lease \
    FAKE_TREEHOUSE_HOLDER=sgt-lease-mismatch-app \
    SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
    SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-cleanup" lease-mismatch app 2>&1
)"
mismatch_status=$?
set -e
[[ "$mismatch_status" -ne 0 ]]
[[ "$mismatch_output" == *"lease identity does not match captured acquisition"* ]]
[[ "$(wc -l < "$TEST_ROOT/treehouse-return.log")" -eq "$return_count" ]]
[[ -e "$TEST_ROOT/mismatch-active" && -d "$TEST_ROOT/fleet/lease-mismatch" ]]
printf 'sgt-cleanup rejects a changed Treehouse lease identity: ok\n'

for status_mode in empty malformed constant invalid_utf8 control duplicate_field duplicate \
  noncanonical; do
  init_repo "$TEST_ROOT/status-$status_mode-main"
  git -C "$TEST_ROOT/status-$status_mode-main" worktree add -q \
    -b "status-$status_mode-worker" "$TEST_ROOT/status-$status_mode-checkout"
  record_task "status-$status_mode" "$TEST_ROOT/status-$status_mode-main" \
    "$TEST_ROOT/status-$status_mode-checkout" treehouse
  touch "$TEST_ROOT/status-$status_mode-active"
  return_count="$(wc -l < "$TEST_ROOT/treehouse-return.log")"
  set +e
  HOME="$TEST_ROOT/home" PATH="$TEST_ROOT/fake-bin:$PATH" \
    FAKE_TREEHOUSE_LOG="$TEST_ROOT/treehouse-return.log" \
    FAKE_TREEHOUSE_ACTIVE="$TEST_ROOT/status-$status_mode-active" \
    FAKE_TREEHOUSE_PATH="$TEST_ROOT/status-$status_mode-checkout" \
    FAKE_TREEHOUSE_LEASE_ID="lease-status-$status_mode" \
    FAKE_TREEHOUSE_HOLDER="sgt-status-$status_mode-app" \
    FAKE_TREEHOUSE_STATUS_MODE="$status_mode" \
    SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
    SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-cleanup" "status-$status_mode" app >/dev/null 2>&1
  status_probe_status=$?
  set -e
  [[ "$status_probe_status" -ne 0 ]]
  [[ "$(wc -l < "$TEST_ROOT/treehouse-return.log")" -eq "$return_count" ]]
  [[ -d "$TEST_ROOT/fleet/status-$status_mode" ]]
done
printf 'sgt-cleanup rejects ambiguous Treehouse status evidence: ok\n'

init_repo "$TEST_ROOT/wrong-path-main"
git -C "$TEST_ROOT/wrong-path-main" worktree add -q -b wrong-path-worker \
  "$TEST_ROOT/wrong-path-pool-checkout"
record_task wrong-path "$TEST_ROOT/wrong-path-main" \
  "$TEST_ROOT/wrong-path-pool-checkout" treehouse
init_repo "$TEST_ROOT/different-main"
record_task wrong-path "$TEST_ROOT/different-main" \
  "$TEST_ROOT/wrong-path-pool-checkout" treehouse
set +e
wrong_path_output="$(
  HOME="$TEST_ROOT/home" PATH="$TEST_ROOT/fake-bin:$PATH" \
    SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
    SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-cleanup" wrong-path app 2>&1
)"
wrong_path_status=$?
set -e
[[ "$wrong_path_status" -ne 0 ]]
[[ "$wrong_path_output" == *"does not belong to configured cleanup owner"* ]]
[[ -d "$TEST_ROOT/fleet/wrong-path" ]]
printf 'sgt-cleanup rejects a Treehouse path from another repository: ok\n'

init_repo "$TEST_ROOT/return-failure-main"
git -C "$TEST_ROOT/return-failure-main" worktree add -q -b return-failure-worker \
  "$TEST_ROOT/return-failure-pool-checkout"
record_task return-failure "$TEST_ROOT/return-failure-main" \
  "$TEST_ROOT/return-failure-pool-checkout" treehouse
touch "$TEST_ROOT/return-failure-active"
set +e
return_failure_output="$(
  HOME="$TEST_ROOT/home" PATH="$TEST_ROOT/fake-bin:$PATH" \
    FAKE_TREEHOUSE_LOG="$TEST_ROOT/treehouse-return.log" \
    FAKE_TREEHOUSE_ACTIVE="$TEST_ROOT/return-failure-active" \
    FAKE_TREEHOUSE_PATH="$TEST_ROOT/return-failure-pool-checkout" \
    FAKE_TREEHOUSE_LEASE_ID=lease-return-failure \
    FAKE_TREEHOUSE_HOLDER=sgt-return-failure-app \
    FAKE_TREEHOUSE_RETURN_FAIL=1 \
    SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
    SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-cleanup" return-failure app 2>&1
)"
return_failure_status=$?
set -e
[[ "$return_failure_status" -ne 0 ]]
[[ "$return_failure_output" == *"Conditional treehouse return did not confirm lease release"* ]]
[[ -e "$TEST_ROOT/return-failure-active" ]]
[[ -f "$TEST_ROOT/return-failure-pool-checkout/.sergeant-status" ]]
[[ -d "$TEST_ROOT/fleet/return-failure" ]]
printf 'sgt-cleanup preserves a lease after conditional return failure: ok\n'

init_repo "$TEST_ROOT/interrupted-main"
git -C "$TEST_ROOT/interrupted-main" worktree add -q -b interrupted-worker \
  "$TEST_ROOT/interrupted-pool-checkout"
record_task interrupted-return "$TEST_ROOT/interrupted-main" \
  "$TEST_ROOT/interrupted-pool-checkout" treehouse
touch "$TEST_ROOT/interrupted-active"
set +e
HOME="$TEST_ROOT/home" PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_TREEHOUSE_LOG="$TEST_ROOT/treehouse-return.log" \
  FAKE_TREEHOUSE_ACTIVE="$TEST_ROOT/interrupted-active" \
  FAKE_TREEHOUSE_PATH="$TEST_ROOT/interrupted-pool-checkout" \
  FAKE_TREEHOUSE_LEASE_ID=lease-interrupted-return \
  FAKE_TREEHOUSE_HOLDER=sgt-interrupted-return-app \
  SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
  SGT_WIKI_DISABLED=1 SGT_CLEANUP_FAIL_POINT=phase-publish-returned \
  "$ROOT_DIR/bin/sgt-cleanup" interrupted-return app >/dev/null 2>&1
interrupted_status=$?
set -e
[[ "$interrupted_status" -ne 0 && ! -e "$TEST_ROOT/interrupted-active" ]]
[[ "$(sed -n '1p' "$TEST_ROOT/fleet/interrupted-return/app/cleanup-phase")" == returning ]]
return_count="$(wc -l < "$TEST_ROOT/treehouse-return.log")"
set +e
HOME="$TEST_ROOT/home" PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_TREEHOUSE_LOG="$TEST_ROOT/treehouse-return.log" \
  FAKE_TREEHOUSE_ACTIVE="$TEST_ROOT/interrupted-active" \
  FAKE_TREEHOUSE_PATH="$TEST_ROOT/interrupted-pool-checkout" \
  FAKE_TREEHOUSE_LEASE_ID=lease-interrupted-return \
  FAKE_TREEHOUSE_HOLDER=sgt-interrupted-return-app \
  SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
  SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" interrupted-return app >/dev/null 2>&1
interrupted_retry_status=$?
set -e
[[ "$interrupted_retry_status" -ne 0 ]]
[[ "$(wc -l < "$TEST_ROOT/treehouse-return.log")" -eq $((return_count + 1)) ]]
[[ "$(sed -n '1p' "$TEST_ROOT/fleet/interrupted-return/app/cleanup-phase")" == returning ]]
[[ -d "$TEST_ROOT/fleet/interrupted-return" ]]
printf 'sgt-cleanup retries an ambiguous interrupted conditional return: ok\n'

init_repo "$TEST_ROOT/receipt-crash-main"
git -C "$TEST_ROOT/receipt-crash-main" worktree add -q -b receipt-crash-worker \
  "$TEST_ROOT/receipt-crash-checkout"
record_task receipt-crash "$TEST_ROOT/receipt-crash-main" \
  "$TEST_ROOT/receipt-crash-checkout" treehouse
touch "$TEST_ROOT/receipt-crash-active"
set +e
HOME="$TEST_ROOT/home" PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_TREEHOUSE_LOG="$TEST_ROOT/treehouse-return.log" \
  FAKE_TREEHOUSE_ACTIVE="$TEST_ROOT/receipt-crash-active" \
  FAKE_TREEHOUSE_PATH="$TEST_ROOT/receipt-crash-checkout" \
  FAKE_TREEHOUSE_LEASE_ID=lease-receipt-crash \
  FAKE_TREEHOUSE_HOLDER=sgt-receipt-crash-app \
  SGT_CLEANUP_FAIL_POINT=treehouse-return-before-receipt \
  SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
  SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" receipt-crash app >/dev/null 2>&1
receipt_crash_status=$?
set -e
[[ "$receipt_crash_status" -ne 0 && ! -e "$TEST_ROOT/receipt-crash-active" ]]
python3 - "$TEST_ROOT/fleet/receipt-crash/app/treehouse-return-receipt.json" <<'PY'
import json, sys
receipt = json.load(open(sys.argv[1], encoding="utf-8"))
assert receipt["attempts"][-1]["state"] == "started"
PY
[[ "$(sed -n '1p' "$TEST_ROOT/fleet/receipt-crash/app/cleanup-phase")" == returning ]]
set +e
HOME="$TEST_ROOT/home" PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_TREEHOUSE_LOG="$TEST_ROOT/treehouse-return.log" \
  FAKE_TREEHOUSE_ACTIVE="$TEST_ROOT/receipt-crash-active" \
  FAKE_TREEHOUSE_PATH="$TEST_ROOT/receipt-crash-checkout" \
  FAKE_TREEHOUSE_LEASE_ID=lease-receipt-crash \
  FAKE_TREEHOUSE_HOLDER=sgt-receipt-crash-app \
  SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
  SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" receipt-crash app >/dev/null 2>&1
receipt_retry_status=$?
set -e
[[ "$receipt_retry_status" -ne 0 && -d "$TEST_ROOT/fleet/receipt-crash" ]]
python3 - "$TEST_ROOT/fleet/receipt-crash/app/treehouse-return-receipt.json" <<'PY'
import json
from pathlib import Path
import sys

receipt = json.load(open(sys.argv[1], encoding="utf-8"))
first, second = receipt["attempts"][-2:]
assert first["state"] == "started"
assert second["state"] == "completed" and second["returncode"] == 42
assert first["raw_path"] != second["raw_path"]
assert Path(first["raw_path"]).is_file() and Path(second["raw_path"]).is_file()
PY
printf 'sgt-cleanup preserves ambiguous post-return receipt crashes: ok\n'

init_repo "$TEST_ROOT/git-main"
git -C "$TEST_ROOT/git-main" worktree add -q -b git-worker \
  "$TEST_ROOT/git-worktree"
record_task git-remains "$TEST_ROOT/git-main" "$TEST_ROOT/git-worktree" git

cat > "$TEST_ROOT/fake-bin/git" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" worktree remove "* ]]; then
  exit 0
fi
exec "$REAL_GIT" "$@"
EOF
chmod +x "$TEST_ROOT/fake-bin/git"

set +e
git_output="$(
  HOME="$TEST_ROOT/home" PATH="$TEST_ROOT/fake-bin:$PATH" \
    SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
    SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-cleanup" git-remains 2>&1
)"
git_status=$?
set -e
[[ "$git_status" -ne 0 ]]
[[ "$git_output" == *"Worktree removal reported success but the directory remains"* ]]
[[ -d "$TEST_ROOT/git-worktree" ]]
[[ -d "$TEST_ROOT/fleet/git-remains" ]]
printf 'sgt-cleanup rejects an incomplete ordinary git removal: ok\n'
