#!/usr/bin/env bash
# Tests for interrupted fallback execution reported as never-started despite committed work (#94).
# Regression suite for three code paths:
#   1. _reconcile_incomplete_dispatch (sgt-watch) surfaces committed work instead of
#      "never acquired a worktree or owned live pane" when the worktree has commits above
#      the recorded initial_sha.
#   2. sgt-dispatch stores initial_sha after worktree creation.
#   3. sgt-dispatch blocks re-dispatch to a branch that already has commits above the
#      remote default branch (or initial_sha base).
#   4. sgt-interactive-worker orphan diagnostic includes committed-work summary when
#      commits exist above initial_sha.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
TMUX_SESSION="sgt-interrupted-fallback-test-$$"
trap 'tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true; rm -rf "$TEST_ROOT"' EXIT

fake_bin="$TEST_ROOT/bin"
mkdir -p "$fake_bin"

# ── Helpers ────────────────────────────────────────────────────────────────────

_make_git_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@test.invalid"
  git -C "$dir" config user.name "Test"
  git -C "$dir" commit -q --allow-empty -m "initial commit"
}

_add_commit() {
  local dir="$1"
  local msg="$2"
  git -C "$dir" commit -q --allow-empty -m "$msg"
}

# ── Fake tmux for watch tests (no live panes needed) ──────────────────────────

cat > "$fake_bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  display-message) exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$fake_bin/tmux"

# ═══════════════════════════════════════════════════════════════════════════════
# 1. sgt-watch _reconcile_incomplete_dispatch: no committed work (existing case)
#    Regression guard: old behaviour preserved when no commits above initial_sha.
# ═══════════════════════════════════════════════════════════════════════════════

fleet1="$TEST_ROOT/fleet1"
no_work_repo="$fleet1/task-no-work/app"
no_work_wt="$TEST_ROOT/no-work-wt"
mkdir -p "$no_work_repo"
_make_git_repo "$no_work_wt"

initial_sha="$(git -C "$no_work_wt" rev-parse HEAD)"
printf 'dispatched\n' > "$no_work_repo/status"
printf '%s\n' "$no_work_wt" > "$no_work_repo/worktree"
printf '%s\n' "$initial_sha" > "$no_work_repo/initial_sha"
printf '1\n' > "$no_work_repo/dispatch_started"

PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet1" \
  "$ROOT/bin/sgt-watch" --sync-all >/dev/null

[[ "$(cat "$no_work_repo/status")" == 'failed: dispatch incomplete: no worktree or owned live pane' ]] || {
  printf 'FAIL test 1: expected "failed: dispatch incomplete: no worktree or owned live pane", got "%s"\n' \
    "$(cat "$no_work_repo/status")" >&2
  exit 1
}
grep -Fq 'dispatch never acquired a worktree or owned live pane' "$no_work_repo/diagnostic" || {
  printf 'FAIL test 1: expected "never acquired" in diagnostic, got: %s\n' \
    "$(cat "$no_work_repo/diagnostic")" >&2
  exit 1
}
printf 'sgt-watch reconcile no-committed-work: ok\n'

# ═══════════════════════════════════════════════════════════════════════════════
# 2. sgt-watch _reconcile_incomplete_dispatch: committed work above initial_sha
#    When the worktree has commits above initial_sha, the diagnostic must surface
#    them and the status must be distinct from "no worktree or owned live pane".
# ═══════════════════════════════════════════════════════════════════════════════

fleet2="$TEST_ROOT/fleet2"
committed_repo="$fleet2/task-committed/app"
committed_wt="$TEST_ROOT/committed-wt"
mkdir -p "$committed_repo"
_make_git_repo "$committed_wt"

initial_sha="$(git -C "$committed_wt" rev-parse HEAD)"
_add_commit "$committed_wt" "feat: implement fix for #94"

printf 'dispatched\n' > "$committed_repo/status"
printf '%s\n' "$committed_wt" > "$committed_repo/worktree"
printf '%s\n' "$initial_sha" > "$committed_repo/initial_sha"
printf '1\n' > "$committed_repo/dispatch_started"

PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet2" \
  "$ROOT/bin/sgt-watch" --sync-all >/dev/null

status_got="$(cat "$committed_repo/status")"
[[ "$status_got" == 'failed: dispatch incomplete: no worktree or owned live pane' ]] && {
  printf 'FAIL test 2: status must NOT be "no worktree or owned live pane" when committed work exists (got: %s)\n' \
    "$status_got" >&2
  exit 1
}
[[ "$status_got" == failed:* ]] || {
  printf 'FAIL test 2: expected a failed: status, got "%s"\n' "$status_got" >&2
  exit 1
}
grep -Fq 'feat: implement fix for #94' "$committed_repo/diagnostic" || {
  printf 'FAIL test 2: expected commit message in diagnostic, got:\n%s\n' \
    "$(cat "$committed_repo/diagnostic")" >&2
  exit 1
}
grep -Fq 'reconcile' "$committed_repo/diagnostic" || {
  printf 'FAIL test 2: expected "reconcile" in diagnostic, got:\n%s\n' \
    "$(cat "$committed_repo/diagnostic")" >&2
  exit 1
}
printf 'sgt-watch reconcile committed-work-surface: ok\n'

# ═══════════════════════════════════════════════════════════════════════════════
# 3. sgt-watch _reconcile_incomplete_dispatch: committed work, no initial_sha
#    Fallback when initial_sha is absent: still surfaces work when the branch
#    has commits not on any remote.
# ═══════════════════════════════════════════════════════════════════════════════

fleet3="$TEST_ROOT/fleet3"
no_sha_repo="$fleet3/task-no-sha/app"
origin_bare="$TEST_ROOT/origin-bare.git"
no_sha_wt="$TEST_ROOT/no-sha-wt"
mkdir -p "$no_sha_repo"

git init -q --bare "$origin_bare"
git clone -q "$origin_bare" "$no_sha_wt" 2>/dev/null
git -C "$no_sha_wt" config user.email "test@test.invalid"
git -C "$no_sha_wt" config user.name "Test"
git -C "$no_sha_wt" commit -q --allow-empty -m "origin base"
git -C "$no_sha_wt" push -q origin HEAD 2>/dev/null
git -C "$no_sha_wt" commit -q --allow-empty -m "feat: work not pushed to origin"

printf 'dispatched\n' > "$no_sha_repo/status"
printf '%s\n' "$no_sha_wt" > "$no_sha_repo/worktree"
# No initial_sha file — backward-compat fallback path
printf '1\n' > "$no_sha_repo/dispatch_started"

PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet3" \
  "$ROOT/bin/sgt-watch" --sync-all >/dev/null

status_got="$(cat "$no_sha_repo/status")"
[[ "$status_got" == 'failed: dispatch incomplete: no worktree or owned live pane' ]] && {
  printf 'FAIL test 3: status must NOT be "no worktree or owned live pane" when unpushed commits exist (got: %s)\n' \
    "$status_got" >&2
  exit 1
}
[[ "$status_got" == failed:* ]] || {
  printf 'FAIL test 3: expected a failed: status, got "%s"\n' "$status_got" >&2
  exit 1
}
grep -Fq 'feat: work not pushed to origin' "$no_sha_repo/diagnostic" || {
  printf 'FAIL test 3: expected commit message in diagnostic, got:\n%s\n' \
    "$(cat "$no_sha_repo/diagnostic")" >&2
  exit 1
}
printf 'sgt-watch reconcile committed-work-no-initial-sha: ok\n'

# ═══════════════════════════════════════════════════════════════════════════════
# 4 + 5. sgt-dispatch: stores initial_sha AND blocks re-dispatch when branch
#        has prior commits above the default remote branch.
#
#        Setup mirrors sgt-dispatch-worker-test.sh: full fake bin suite,
#        pre-committed feature branch, coordinator pane identity stub.
# ═══════════════════════════════════════════════════════════════════════════════

dispatch_repo="$TEST_ROOT/dispatch-repo"
dispatch_fleet="$TEST_ROOT/dispatch-fleet"
dispatch_config="$TEST_ROOT/dispatch-config"
mkdir -p "$dispatch_config"

# Create repo with remote and a pre-existing branch that has commits
dispatch_origin="$TEST_ROOT/dispatch-origin.git"
git init -q --bare "$dispatch_origin"
git clone -q "$dispatch_origin" "$dispatch_repo" 2>/dev/null
git -C "$dispatch_repo" config user.email "test@test.invalid"
git -C "$dispatch_repo" config user.name "Test"
git -C "$dispatch_repo" commit -q --allow-empty -m "base commit on main"
git -C "$dispatch_repo" push -q origin HEAD 2>/dev/null

# Simulate prior worker: create the feature branch with a commit.
# The brief "TDD test dispatch" → branch slug "tdd-test-dispatch" → "feat/tdd-test-dispatch"
# Capture the default branch name BEFORE switching so we can return to it.
_dispatch_default_branch="$(git -C "$dispatch_repo" symbolic-ref --short HEAD)"
git -C "$dispatch_repo" checkout -q -b feat/tdd-test-dispatch
git -C "$dispatch_repo" commit -q --allow-empty -m "feat: prior worker committed this (orphaned run)"
git -C "$dispatch_repo" checkout -q "$_dispatch_default_branch"

cat > "$dispatch_config/test.yaml" <<EOF
name: test
repos:
  - name: app
    path: $dispatch_repo
EOF

# Fake yq that parses our test.yaml structure
cat > "$fake_bin/yq" <<EOF
#!/usr/bin/env bash
case "\$*" in
  ".repos | length"*) printf '1\n' ;;
  ".repos[0].name"*) printf 'app\n' ;;
  ".repos[0].path"*) printf '$dispatch_repo\n' ;;
  ".repos[0].role // \"\""*) printf '\n' ;;
  ".repos[0].group // \"\""*) printf '\n' ;;
  ".repos[0].identity // \"\""*) printf '\n' ;;
  ".repos[0].agent_instructions // \"\""*) printf '\n' ;;
  ".defaults.agent_instructions // \"\""*) printf '\n' ;;
  ".identity // \"\""*) printf '\n' ;;
  *) printf '\n' ;;
esac
EOF
chmod +x "$fake_bin/yq"

# Fake td with the minimum interface sgt-dispatch + sgt-td-create need
cat > "$fake_bin/td" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Strip --work-dir and --json to simplify arg parsing
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-dir|-w) shift 2 ;;
    --json) shift ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]:-}"
case "${1:-}" in
  --version)    printf 'td version v0.1.0\n' ;;
  --help)       printf 'td\n' ;;
  list)         printf '[]\n' ;;
  create)
    if [[ "${2:-}" == "--help" ]]; then
      printf '%s\n' '--description --json --work-dir'
    else
      printf '{"id":"td-interrupted-test-1"}\n'
    fi
    ;;
  delete)       printf '{"id":"td-interrupted-test-1","deleted":true}\n' ;;
  *)            exit 0 ;;
esac
EOF
chmod +x "$fake_bin/td"

# Fake opencode
cat > "$fake_bin/opencode" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$fake_bin/opencode"

# Fake tmux: returns valid coordinator and worker pane identities,
# and auto-delivers notifications so _sgt_wait_worker_notification succeeds.
cat > "$fake_bin/tmux" <<EOF
#!/usr/bin/env bash
[[ "\${1:-}" == "display-message" ]] || printf '%s\n' "\$*" >> "\${TMUX_LOG:-/dev/null}"
case "\$1" in
  has-session) exit 0 ;;
  new-session) exit 0 ;;
  display-message)
    # Auto-deliver pending notifications on every identity check
    for repo_state in "$dispatch_fleet"/*/*; do
      [[ -d "\$repo_state" ]] || continue
      [[ -f "\$repo_state/notification_id" && -f "\$repo_state/notification_target" ]] || continue
      nonce="\$(cat "\$repo_state/notification_target" 2>/dev/null || true)"
      notification_id="\$(cat "\$repo_state/notification_id" 2>/dev/null || true)"
      [[ "\$nonce" =~ ^[a-f0-9]{32}$ && -n "\$notification_id" ]] || continue
      target_dir="\$repo_state/notifications/\$notification_id/targets/\$nonce"
      [[ -d "\$target_dir" ]] || continue
      token="\$notification_id|\$nonce"
      [[ -f "\$target_dir/accepted" ]] || printf '%s\n' "\$token" > "\$target_dir/accepted"
      [[ -f "\$target_dir/delivered" ]] || printf '%s\n' "\$token" > "\$target_dir/delivered"
    done
    # Return appropriate pane identity
    if [[ "\$*" == *'-t %11'* ]]; then
      printf '0|%%11|1111|111111|coordinator-command\n'
    else
      printf '0|%%42|4242|123456|fixture-worker-command\n'
    fi
    ;;
  new-window)
    printf '%%42\n'
    ;;
  send-keys) ;;
  kill-pane) ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$fake_bin/tmux"

export TMUX=fixture TMUX_PANE=%11

# ── Test 5: sgt-dispatch fails when branch has committed prior work ──────────
dispatch_err="$TEST_ROOT/dispatch5.err"
PATH="$fake_bin:$PATH" \
  SERGEANT_CONFIG="$dispatch_config" \
  SERGEANT_FLEET="$dispatch_fleet" \
  SGT_WIKI_DISABLED=1 \
  TMUX_LOG="$TEST_ROOT/dispatch5.tmux.log" \
  "$ROOT/bin/sgt-dispatch" test "TDD test dispatch" \
  --repos app --agent opencode 2>"$dispatch_err" && {
  printf 'FAIL test 5: sgt-dispatch should have failed when branch has prior commits\n' >&2
  cat "$dispatch_err" >&2
  exit 1
} || true

grep -Eiq 'reconcile|committed|prior|already' "$dispatch_err" || {
  printf 'FAIL test 5: error message must mention reconciliation of prior commits, got:\n%s\n' \
    "$(cat "$dispatch_err")" >&2
  exit 1
}
printf 'sgt-dispatch blocks re-dispatch with prior commits: ok\n'

# ── Test 4: sgt-dispatch writes initial_sha for a fresh branch ───────────────
# Create a clean repo (no pre-existing feature branch) and verify initial_sha
# is written to the fleet state after a successful dispatch.
fresh_repo="$TEST_ROOT/fresh-repo"
fresh_origin="$TEST_ROOT/fresh-origin.git"
fresh_fleet="$TEST_ROOT/fresh-fleet"
fresh_config="$TEST_ROOT/fresh-config"
mkdir -p "$fresh_config"

git init -q --bare "$fresh_origin"
git clone -q "$fresh_origin" "$fresh_repo" 2>/dev/null
git -C "$fresh_repo" config user.email "test@test.invalid"
git -C "$fresh_repo" config user.name "Test"
git -C "$fresh_repo" commit -q --allow-empty -m "initial commit"
git -C "$fresh_repo" push -q origin HEAD 2>/dev/null

cat > "$fresh_config/test.yaml" <<EOF
name: test
repos:
  - name: app
    path: $fresh_repo
EOF

cat > "$fake_bin/yq" <<EOF
#!/usr/bin/env bash
case "\$*" in
  ".repos | length"*) printf '1\n' ;;
  ".repos[0].name"*) printf 'app\n' ;;
  ".repos[0].path"*) printf '$fresh_repo\n' ;;
  ".repos[0].role // \"\""*) printf '\n' ;;
  ".repos[0].group // \"\""*) printf '\n' ;;
  ".repos[0].identity // \"\""*) printf '\n' ;;
  ".repos[0].agent_instructions // \"\""*) printf '\n' ;;
  ".defaults.agent_instructions // \"\""*) printf '\n' ;;
  ".identity // \"\""*) printf '\n' ;;
  *) printf '\n' ;;
esac
EOF
chmod +x "$fake_bin/yq"

# Update tmux to deliver to fresh_fleet
cat > "$fake_bin/tmux" <<EOF
#!/usr/bin/env bash
[[ "\${1:-}" == "display-message" ]] || printf '%s\n' "\$*" >> "\${TMUX_LOG:-/dev/null}"
case "\$1" in
  has-session) exit 0 ;;
  new-session) exit 0 ;;
  display-message)
    for repo_state in "$fresh_fleet"/*/*; do
      [[ -d "\$repo_state" ]] || continue
      [[ -f "\$repo_state/notification_id" && -f "\$repo_state/notification_target" ]] || continue
      nonce="\$(cat "\$repo_state/notification_target" 2>/dev/null || true)"
      notification_id="\$(cat "\$repo_state/notification_id" 2>/dev/null || true)"
      [[ "\$nonce" =~ ^[a-f0-9]{32}$ && -n "\$notification_id" ]] || continue
      target_dir="\$repo_state/notifications/\$notification_id/targets/\$nonce"
      [[ -d "\$target_dir" ]] || continue
      token="\$notification_id|\$nonce"
      [[ -f "\$target_dir/accepted" ]] || printf '%s\n' "\$token" > "\$target_dir/accepted"
      [[ -f "\$target_dir/delivered" ]] || printf '%s\n' "\$token" > "\$target_dir/delivered"
    done
    if [[ "\$*" == *'-t %11'* ]]; then
      printf '0|%%11|1111|111111|coordinator-command\n'
    else
      printf '0|%%42|4242|123456|fixture-worker-command\n'
    fi
    ;;
  new-window) printf '%%42\n' ;;
  send-keys) ;;
  kill-pane) ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$fake_bin/tmux"

PATH="$fake_bin:$PATH" \
  SERGEANT_CONFIG="$fresh_config" \
  SERGEANT_FLEET="$fresh_fleet" \
  SGT_WIKI_DISABLED=1 \
  TMUX_LOG="$TEST_ROOT/fresh.tmux.log" \
  "$ROOT/bin/sgt-dispatch" test "Fresh branch dispatch" \
  --repos app --agent opencode >/dev/null 2>&1

# initial_sha must be written to the fleet repo state
fresh_state="$(printf '%s\n' "$fresh_fleet"/fresh-branch-dispatch-*/app)"
[[ -s "$fresh_state/initial_sha" ]] || {
  printf 'FAIL test 4: initial_sha not written to fleet state after dispatch\n' >&2
  ls "$fresh_state/" >&2 || true
  exit 1
}
# initial_sha must be a valid git SHA
initial_sha_written="$(cat "$fresh_state/initial_sha")"
[[ "$initial_sha_written" =~ ^[0-9a-f]{40}$ ]] || {
  printf 'FAIL test 4: initial_sha is not a valid SHA: %s\n' "$initial_sha_written" >&2
  exit 1
}
printf 'sgt-dispatch stores initial_sha after worktree creation: ok\n'

# ═══════════════════════════════════════════════════════════════════════════════
# 6. sgt-interactive-worker orphan diagnostic surfaces committed work
#    When the worker is orphaned and commits exist above initial_sha, the
#    diagnostic must include the commit summary and "reconcile" guidance.
# ═══════════════════════════════════════════════════════════════════════════════

worker_state="$TEST_ROOT/worker-state"
worker_wt="$TEST_ROOT/worker-wt"
mkdir -p "$worker_state"
_make_git_repo "$worker_wt"
initial_sha_worker="$(git -C "$worker_wt" rev-parse HEAD)"
_add_commit "$worker_wt" "feat: worker committed work before crash"

printf '%s\n' "$initial_sha_worker" > "$worker_state/initial_sha"

# Fake opencode that exits non-zero (simulating "Tool execution aborted")
cat > "$fake_bin/opencode" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$fake_bin/opencode"

tmux new-session -d -s "$TMUX_SESSION" 2>/dev/null || true
tmux new-window -d -t "$TMUX_SESSION:" -n worker-committed-orphan \
  "env PATH='$fake_bin:$PATH' \
  '$ROOT/bin/sgt-interactive-worker' '$worker_state' \
  '$worker_wt' '$fake_bin/opencode'"

for _ in $(seq 1 100); do
  [[ -f "$worker_state/diagnostic" ]] && break
  sleep 0.05
done

[[ -f "$worker_state/diagnostic" ]] || {
  printf 'FAIL test 6: worker diagnostic not written\n' >&2
  exit 1
}
[[ "$(cat "$worker_state/status")" == "orphaned" ]] || {
  printf 'FAIL test 6: expected orphaned status, got %s\n' "$(cat "$worker_state/status")" >&2
  exit 1
}
grep -Fq 'feat: worker committed work before crash' "$worker_state/diagnostic" || {
  printf 'FAIL test 6: expected commit message in orphan diagnostic, got:\n%s\n' \
    "$(cat "$worker_state/diagnostic")" >&2
  exit 1
}
grep -Fq 'reconcile' "$worker_state/diagnostic" || {
  printf 'FAIL test 6: expected "reconcile" guidance in orphan diagnostic, got:\n%s\n' \
    "$(cat "$worker_state/diagnostic")" >&2
  exit 1
}
printf 'sgt-interactive-worker orphan surfaces committed work: ok\n'

# ═══════════════════════════════════════════════════════════════════════════════
# 7. sgt-interactive-worker orphan diagnostic: no commits above initial_sha
#    Regression guard: diagnostic must NOT mention committed work when clean.
# ═══════════════════════════════════════════════════════════════════════════════

worker_clean_state="$TEST_ROOT/worker-clean-state"
worker_clean_wt="$TEST_ROOT/worker-clean-wt"
mkdir -p "$worker_clean_state"
_make_git_repo "$worker_clean_wt"
clean_initial_sha="$(git -C "$worker_clean_wt" rev-parse HEAD)"
printf '%s\n' "$clean_initial_sha" > "$worker_clean_state/initial_sha"

tmux new-window -d -t "$TMUX_SESSION:" -n worker-clean-orphan \
  "env PATH='$fake_bin:$PATH' \
  '$ROOT/bin/sgt-interactive-worker' '$worker_clean_state' \
  '$worker_clean_wt' '$fake_bin/opencode'"

for _ in $(seq 1 100); do
  [[ -f "$worker_clean_state/diagnostic" ]] && break
  sleep 0.05
done

[[ -f "$worker_clean_state/diagnostic" ]] || {
  printf 'FAIL test 7: clean-orphan worker diagnostic not written\n' >&2
  exit 1
}
[[ "$(cat "$worker_clean_state/status")" == "orphaned" ]] || {
  printf 'FAIL test 7: expected orphaned status, got %s\n' \
    "$(cat "$worker_clean_state/status")" >&2
  exit 1
}
grep -q 'committed-work-present\|reconcile before re-dispatch' "$worker_clean_state/diagnostic" && {
  printf 'FAIL test 7: clean-orphan diagnostic must not mention committed work:\n%s\n' \
    "$(cat "$worker_clean_state/diagnostic")" >&2
  exit 1
} || true
printf 'sgt-interactive-worker clean-orphan no spurious committed-work: ok\n'

printf '\nsgt-interrupted-fallback: all tests passed\n'
