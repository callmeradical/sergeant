#!/usr/bin/env bash
# Tests for dispatch admission control (openspec/changes/dispatch-admission-control):
# bin/sgt-dispatch queues instead of spawning a pane when the effective worker
# budget is exceeded, and a queued task is promoted later by replaying the
# original call under its already-allocated --resume-task-id.
#
# Fixture is adapted from tests/sgt-dispatch-coordinator-pane-test.sh, which
# already proves this fake tmux/td/agent combination carries a real
# non-dry-run sgt-dispatch call all the way through worker-pane creation.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/config" "$TEST_ROOT/fleet" "$TEST_ROOT/fake-bin" "$TEST_ROOT/repo"
ln -s "$ROOT_DIR/bin/sgt-review-findings" "$TEST_ROOT/fake-bin/sgt-review-findings"
chmod 700 "$TEST_ROOT/fleet"

pass=0
fail=0
_pass() { printf '  ok: %s\n' "$*"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n' "$*" >&2; fail=$((fail + 1)); }

cat > "$TEST_ROOT/config/test.yaml" <<EOF
name: test
repos:
  - name: app
    path: $TEST_ROOT/repo
EOF

cat > "$TEST_ROOT/fake-bin/tmux" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "display-message" ]] || printf '%s\n' "$*" >> "$TMUX_LOG"

_requested_target() {
  local prev=""
  for arg in "$@"; do
    [[ "$prev" == "-t" ]] && { printf '%s\n' "$arg"; return 0; }
    prev="$arg"
  done
  return 1
}

case "$1" in
  list-sessions) printf 'sgt: 1 windows\n' ;;
  has-session) exit 0 ;;
  list-panes)
    if [[ "$*" == *"sgt-coordinator"* ]]; then
      if [[ -f "$MANAGED_EXISTS_FLAG" ]]; then
        printf '%s\n' "$MANAGED_PANE_ID"
      fi
    fi
    ;;
  display-message)
    target="$(_requested_target "$@" || true)"
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
    if [[ "$*" == *'#{session_name}'* ]]; then
      printf 'sgt:3.0\n'
      exit 0
    fi
    for live in ${LIVE_PANES:-}; do
      if [[ "$target" == "$live" ]]; then
        printf '0|%s|1111|111111|coordinator-command\n' "$target"
        exit 0
      fi
    done
    if [[ "$*" == *"@sgt_coordinator"* ]]; then
      if [[ "$target" == "$MANAGED_PANE_ID" && -f "$MANAGED_MARKER_LOG" ]]; then
        cat "$MANAGED_MARKER_LOG"
      else
        printf '\n'
      fi
      exit 0
    fi
    if [[ "$target" == "$MANAGED_PANE_ID" ]]; then
      printf '0|%s|2222|222222|%s\n' "$target" "$ESCAPED_READER_COMMAND"
      exit 0
    fi
    if [[ "$target" == "%42" ]]; then
      printf '0|%%42|4242|123456|fixture-worker-command\n'
      exit 0
    fi
    printf "can't find pane %s\n" "$target" >&2
    exit 1
    ;;
  new-session) exit 0 ;;
  set-option)
    if [[ "$*" == *"@sgt_coordinator"* ]]; then
      printf '%s\n' "${!#}" > "$MANAGED_MARKER_LOG"
    fi
    ;;
  new-window)
    if [[ "$*" == *'-n sgt-coordinator'* ]]; then
      printf '%s\n' "${!#}" > "$MANAGED_COMMAND_LOG"
      printf '%s\n' "${!#}" >> "$MANAGED_CREATE_LOG"
      touch "$MANAGED_EXISTS_FLAG"
      printf '%s\n' "$MANAGED_PANE_ID"
    else
      printf '%s\n' "$*" >> "$WORKER_WINDOW_LOG"
      printf '%%42\n'
    fi
    ;;
  send-keys) ;;
  kill-pane) ;;
  kill-window)
    rm -f "$MANAGED_EXISTS_FLAG" "$MANAGED_COMMAND_LOG" "$MANAGED_MARKER_LOG"
    ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/tmux"

cat > "$TEST_ROOT/fake-bin/td" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then printf 'td version v0.1.0\n'; exit 0; fi
if [[ "${1:-}" == "create" && "${2:-}" == "--help" ]]; then
  printf '%s\n' '--description --json --work-dir'; exit 0
fi
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-dir|-w) shift 2 ;;
    --json) shift ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"
case "${1:-}" in
  list) printf '[]\n' ;;
  create) printf '{"id":"td-app-1"}\n' ;;
  delete) printf '{"id":"td-app-1","deleted":true}\n' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/td"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_ROOT/fake-bin/opencode"
chmod +x "$TEST_ROOT/fake-bin/opencode"

git -C "$TEST_ROOT/repo" init -q
git -C "$TEST_ROOT/repo" config user.name Test
git -C "$TEST_ROOT/repo" config user.email test@example.invalid
touch "$TEST_ROOT/repo/README.md"
git -C "$TEST_ROOT/repo" add README.md
git -C "$TEST_ROOT/repo" commit -qm fixture

MANAGED_PANE_ID='%77'
MANAGED_COMMAND_LOG="$TEST_ROOT/managed-command"
MANAGED_EXISTS_FLAG="$TEST_ROOT/managed-exists"
MANAGED_CREATE_LOG="$TEST_ROOT/managed-create.log"
MANAGED_MARKER_LOG="$TEST_ROOT/managed-marker"
WORKER_WINDOW_LOG="$TEST_ROOT/worker-window.log"
ESCAPED_READER_COMMAND='"while IFS= read -r sgt_line; do printf \"%s\\n\" \"\$sgt_line\"; done; exec sleep 2147483647"'

_dispatch() {
  local log_name="$1" brief="$2"
  shift 2
  env -u TMUX -u TMUX_PANE \
    PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/$log_name.log" \
    MANAGED_PANE_ID="$MANAGED_PANE_ID" \
    MANAGED_COMMAND_LOG="$MANAGED_COMMAND_LOG" \
    MANAGED_EXISTS_FLAG="$MANAGED_EXISTS_FLAG" \
    MANAGED_CREATE_LOG="$MANAGED_CREATE_LOG" \
    MANAGED_MARKER_LOG="$MANAGED_MARKER_LOG" \
    WORKER_WINDOW_LOG="$WORKER_WINDOW_LOG" \
    ESCAPED_READER_COMMAND="$ESCAPED_READER_COMMAND" \
    SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
    SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-dispatch" test "$brief" --repos app "$@"
}

_fleet_task_dirs() {
  find "$TEST_ROOT/fleet" -mindepth 1 -maxdepth 1 -type d ! -name '.dispatch-queue' \
    -exec basename {} \;
}

# ── 1. Ample budget: a normal dispatch is unaffected by the admission check ──

rm -f "$MANAGED_EXISTS_FLAG" "$MANAGED_COMMAND_LOG" "$MANAGED_CREATE_LOG" \
  "$MANAGED_MARKER_LOG" "$WORKER_WINDOW_LOG"
before_tasks="$(_fleet_task_dirs)"
_dispatch baseline 'Baseline dispatch' >/dev/null
after_tasks="$(_fleet_task_dirs)"
if [[ "$after_tasks" != "$before_tasks" && -s "$WORKER_WINDOW_LOG" ]]; then
  _pass "ample budget: dispatch proceeds normally and creates a worker pane"
else
  _fail "ample budget: expected a new fleet task and a worker pane; before='$before_tasks' after='$after_tasks' worker_log_size=$(wc -c < "$WORKER_WINDOW_LOG" 2>/dev/null || echo 0)"
fi
if [[ ! -d "$TEST_ROOT/fleet/.dispatch-queue" ]] || \
   [[ -z "$(find "$TEST_ROOT/fleet/.dispatch-queue" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then
  _pass "ample budget: nothing was queued"
else
  _fail "ample budget: unexpectedly queued something"
fi

# ── 2. Over budget: dispatch queues instead of spawning a pane ──────────────
# SERGEANT_DISPATCH_MAX_WORKERS=1 with one already-verified-live worker (from
# test 1 above, still recorded in_progress with a live pane_identity) means
# live >= budget for this next call.

rm -f "$MANAGED_EXISTS_FLAG" "$MANAGED_COMMAND_LOG" "$MANAGED_CREATE_LOG" \
  "$MANAGED_MARKER_LOG" "$WORKER_WINDOW_LOG"
before_tasks="$(_fleet_task_dirs)"
queued_output="$(SERGEANT_DISPATCH_MAX_WORKERS=1 _dispatch overbudget 'Overbudget dispatch' 2>&1)"
queued_status=$?
after_tasks="$(_fleet_task_dirs)"
if [[ "$queued_status" -eq 0 ]]; then
  _pass "over budget: dispatch call itself still exits 0 (caller-facing shape unchanged)"
else
  _fail "over budget: dispatch call should exit 0 when queued, got $queued_status: $queued_output"
fi
if [[ "$queued_output" == *queued* ]]; then
  _pass "over budget: dispatch reports the call as queued"
else
  _fail "over budget: expected 'queued' in output, got: $queued_output"
fi
if [[ "$after_tasks" == "$before_tasks" ]]; then
  _pass "over budget: no new fleet task directory was created (never reaches worktree/pane creation)"
else
  _fail "over budget: a fleet task directory was created despite being over budget"
fi
if [[ ! -s "$WORKER_WINDOW_LOG" ]]; then
  _pass "over budget: no worker pane was spawned"
else
  _fail "over budget: a worker pane was spawned despite being over budget"
fi
queued_dir="$(find "$TEST_ROOT/fleet/.dispatch-queue" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)"
if [[ -n "$queued_dir" ]]; then
  _pass "over budget: a durable queue entry was recorded under .dispatch-queue/"
else
  _fail "over budget: no queue entry was recorded"
fi
queued_task_id="$(basename "$queued_dir")"
if [[ "$queued_output" == *"$queued_task_id"* ]]; then
  _pass "over budget: the queued task ID is reported back to the caller"
else
  _fail "over budget: queued task id '$queued_task_id' not present in output: $queued_output"
fi
if [[ "$(cat "$queued_dir/project" 2>/dev/null)" == "test" && \
      "$(cat "$queued_dir/repos" 2>/dev/null)" == "app" ]]; then
  _pass "over budget: the queue entry records project and repos for later promotion"
else
  _fail "over budget: queue entry missing project/repos"
fi

# ── 3. The queued task's status is visible via sgt-watch --list as queued ───

list_output="$(SERGEANT_FLEET="$TEST_ROOT/fleet" "$ROOT_DIR/bin/sgt-watch" --list 2>&1)"
if [[ "$list_output" == *"$queued_task_id"* && "$list_output" == *queued* ]]; then
  _pass "sgt-watch --list: reports the queued task as queued, distinguishable from other buckets"
else
  _fail "sgt-watch --list: expected '$queued_task_id' reported as queued; got:\n$list_output"
fi

# ── 4. Capacity freeing up promotes the queue automatically, end-to-end ─────
# Mark the first (test-1) worker as done, freeing capacity under budget=1, then
# invoke the REAL _sgt_dispatch_queue_promote_ready (not a stub) so it invokes
# the REAL bin/sgt-dispatch with --resume-task-id to admit the queued call.

first_task_id="$(printf '%s\n' "$before_tasks" | head -1)"
if [[ -z "$first_task_id" ]]; then
  # before_tasks from step 2 already excludes queue dir; recompute from step 1.
  first_task_id="$(_fleet_task_dirs | grep -v "^$queued_task_id$" | head -1)"
fi
printf 'done\n' > "$TEST_ROOT/fleet/$first_task_id/app/status"

env -u TMUX -u TMUX_PANE \
  PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/promote.log" \
  MANAGED_PANE_ID="$MANAGED_PANE_ID" \
  MANAGED_COMMAND_LOG="$MANAGED_COMMAND_LOG" \
  MANAGED_EXISTS_FLAG="$MANAGED_EXISTS_FLAG" \
  MANAGED_CREATE_LOG="$MANAGED_CREATE_LOG" \
  MANAGED_MARKER_LOG="$MANAGED_MARKER_LOG" \
  WORKER_WINDOW_LOG="$WORKER_WINDOW_LOG" \
  ESCAPED_READER_COMMAND="$ESCAPED_READER_COMMAND" \
  SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
  SERGEANT_DISPATCH_MAX_WORKERS=1 SGT_WIKI_DISABLED=1 \
  bash -c 'source "$1"; _sgt_dispatch_queue_promote_ready' _ "$ROOT_DIR/bin/_sgt-lib.sh" >/dev/null

if [[ -d "$TEST_ROOT/fleet/$queued_task_id/app" ]]; then
  _pass "promotion: the queued task ID is admitted for real, reusing its original task ID (--resume-task-id)"
else
  _fail "promotion: expected $TEST_ROOT/fleet/$queued_task_id/app to exist after promotion"
fi
if [[ ! -d "$TEST_ROOT/fleet/.dispatch-queue/$queued_task_id" ]]; then
  _pass "promotion: the entry is removed from the durable queue once admitted"
else
  _fail "promotion: queue entry for $queued_task_id should have been removed"
fi

# ── 5. --resume-task-id reuses the exact given task ID on a fresh dispatch ──
# Requires a matching promotion token recorded under .promoting-<id>/, the
# same proof _sgt_dispatch_queue_promote_ready itself provides -- a bare
# --resume-task-id with no token must not be honored (admission-control
# bypass guard).

rm -f "$MANAGED_EXISTS_FLAG" "$MANAGED_COMMAND_LOG" "$MANAGED_CREATE_LOG" \
  "$MANAGED_MARKER_LOG" "$WORKER_WINDOW_LOG"

set +e
no_token_out="$(_dispatch resume-no-token 'No token brief' --resume-task-id fixed-task-no-token 2>&1)"
no_token_status=$?
set -e
if [[ "$no_token_status" -ne 0 && "$no_token_out" == *"promotion proof"* ]]; then
  _pass "--resume-task-id: rejected outright without a matching promotion token (admission-control bypass guard)"
else
  _fail "--resume-task-id: should require a valid promotion token; status=$no_token_status out=$no_token_out"
fi
if [[ ! -d "$TEST_ROOT/fleet/fixed-task-no-token" ]]; then
  _pass "--resume-task-id: no fleet task directory is created without a valid token"
else
  _fail "--resume-task-id: a fleet task directory should not exist without a valid token"
fi

# A matching token alone, with no matching promoter_pid (process lineage), is
# also rejected: a token-only forgery is exactly as easy for an unrelated
# caller to construct as a genuine promotion, so the token check alone is not
# sufficient proof (see bin/sgt-dispatch's --resume-task-id comment).
mkdir -p "$TEST_ROOT/fleet/.dispatch-queue/.promoting-fixed-task-wrong-pid"
printf 'test-token-wrong-pid\n' > "$TEST_ROOT/fleet/.dispatch-queue/.promoting-fixed-task-wrong-pid/promotion_token"
printf '1\n' > "$TEST_ROOT/fleet/.dispatch-queue/.promoting-fixed-task-wrong-pid/promoter_pid"
set +e
wrong_pid_out="$(_dispatch resume-wrong-pid 'Wrong pid brief' --resume-task-id fixed-task-wrong-pid \
  --promotion-token test-token-wrong-pid 2>&1)"
wrong_pid_status=$?
set -e
if [[ "$wrong_pid_status" -ne 0 && "$wrong_pid_out" == *"promotion proof"* ]]; then
  _pass "--resume-task-id: a matching token with a non-matching promoter_pid (process lineage) is still rejected"
else
  _fail "--resume-task-id: should require promoter_pid to match \$PPID too; status=$wrong_pid_status out=$wrong_pid_out"
fi

mkdir -p "$TEST_ROOT/fleet/.dispatch-queue/.promoting-fixed-task-abc123"
printf 'test-token-abc123\n' > "$TEST_ROOT/fleet/.dispatch-queue/.promoting-fixed-task-abc123/promotion_token"
printf '%s\n' "$$" > "$TEST_ROOT/fleet/.dispatch-queue/.promoting-fixed-task-abc123/promoter_pid"
_dispatch resume-fixed 'Resume-fixed brief' --resume-task-id fixed-task-abc123 \
  --promotion-token test-token-abc123 >/dev/null
if [[ -d "$TEST_ROOT/fleet/fixed-task-abc123/app" ]]; then
  _pass "--resume-task-id: dispatch reuses the exact given task ID instead of generating a random one"
else
  _fail "--resume-task-id: expected fleet/fixed-task-abc123/app to exist"
fi

# ── 6. --resume-task-id combined with --json is a hard usage error ─────────
# Never a legitimate combination: a --json replay reuses sgt-callback's own
# correlation-keyed task-id resolution instead (see
# _sgt_dispatch_queue_promote_ready), and TASK_ID resolution ignores
# --resume-task-id whenever --json is set -- so silently ignoring the flag
# there, rather than rejecting the combination outright, would leave the
# admission-control gate (which is keyed only on --resume-task-id being
# non-empty) skippable via --json too.

json_resume_brief="$TEST_ROOT/json-resume-brief.txt"
(umask 077; printf '%s' 'json resume combo brief' > "$json_resume_brief")
mkdir -p "$TEST_ROOT/callbacks"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_ROOT/callbacks/testprofile"
chmod 700 "$TEST_ROOT/callbacks/testprofile"
set +e
json_resume_out="$(env -u TMUX -u TMUX_PANE PATH="$TEST_ROOT/fake-bin:$PATH" \
  SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
  SERGEANT_CALLBACKS="$TEST_ROOT/callbacks" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test --brief-file "$json_resume_brief" --repos app \
  --json --origin-profile testprofile --correlation-id corr-json-resume-001 \
  --resume-task-id fixed-task-abc123 2>&1)"
json_resume_status=$?
set -e
if [[ "$json_resume_status" -ne 0 && "$json_resume_out" == *"cannot be combined"* ]]; then
  _pass "--resume-task-id + --json: rejected as a hard usage error"
else
  _fail "--resume-task-id + --json: expected a 'cannot be combined' usage error; status=$json_resume_status out=$json_resume_out"
fi

printf '\nsgt-dispatch-admission-control: %d passed' "$pass"
if [[ "$fail" -gt 0 ]]; then
  printf ', %d FAILED\n' "$fail" >&2
  exit 1
fi
printf '\n'
