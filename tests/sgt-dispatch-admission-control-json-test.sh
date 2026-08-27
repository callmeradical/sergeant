#!/usr/bin/env bash
# Tests that dispatch admission control (openspec/changes/dispatch-admission-control)
# also applies to the --json/correlated-callback (Hermes) dispatch path: an
# over-budget --json call queues (instead of bypassing admission control
# entirely) and a later promotion replays it via --json/--origin-profile/
# --correlation-id, letting sgt-callback's own correlation-keyed idempotency
# resolve the replay back to the exact same task_id.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

pass=0
fail=0
_pass() { printf '  ok: %s\n' "$*"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n' "$*" >&2; fail=$((fail + 1)); }

mkdir -p "$TEST_ROOT/config" "$TEST_ROOT/fleet" "$TEST_ROOT/fake-bin" "$TEST_ROOT/repo" \
  "$TEST_ROOT/callbacks"
ln -s "$ROOT_DIR/bin/sgt-review-findings" "$TEST_ROOT/fake-bin/sgt-review-findings"
chmod 700 "$TEST_ROOT/fleet"

cat > "$TEST_ROOT/config/test.yaml" <<EOF
name: test
repos:
  - name: app
    path: $TEST_ROOT/repo
EOF

printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_ROOT/callbacks/testprofile"
chmod 700 "$TEST_ROOT/callbacks/testprofile"

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
    if [[ "$*" == *"sgt-coordinator"* && -f "$MANAGED_EXISTS_FLAG" ]]; then
      printf '%s\n' "$MANAGED_PANE_ID"
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
  *) exit 0 ;;
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

_env() {
  env -u TMUX -u TMUX_PANE \
    PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
    LIVE_PANES="${LIVE_PANES:-}" \
    MANAGED_PANE_ID="$MANAGED_PANE_ID" \
    MANAGED_COMMAND_LOG="$MANAGED_COMMAND_LOG" \
    MANAGED_EXISTS_FLAG="$MANAGED_EXISTS_FLAG" \
    MANAGED_CREATE_LOG="$MANAGED_CREATE_LOG" \
    MANAGED_MARKER_LOG="$MANAGED_MARKER_LOG" \
    WORKER_WINDOW_LOG="$WORKER_WINDOW_LOG" \
    ESCAPED_READER_COMMAND="$ESCAPED_READER_COMMAND" \
    SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
    SERGEANT_CALLBACKS="$TEST_ROOT/callbacks" SGT_WIKI_DISABLED=1 \
    "$@"
}

_brief_file() {
  local f="$TEST_ROOT/brief-$RANDOM.txt"
  (umask 077; printf '%s' "$1" > "$f")
  printf '%s\n' "$f"
}

_fleet_task_dirs() {
  # Excludes every dot-prefixed directory: .dispatch-queue (this change's own
  # admission queue) and .callback-transactions/.callback-origins (sgt-callback's
  # pre-existing correlated-admission bookkeeping), neither of which is a real
  # fleet task directory.
  find "$TEST_ROOT/fleet" -mindepth 1 -maxdepth 1 -type d ! -name '.*' \
    -exec basename {} \;
}

# ── 1. Fixture: one already-live worker, seeded directly (matching the
# non-JSON admission-control test) rather than via a real --json dispatch, so
# this file stays scoped to admission control and does not also have to
# stand up the full synchronous notification-handshake wait that only the
# --json path performs after a real worker pane is created ─────────────────

seed_task="existing-worker-task"
mkdir -p "$TEST_ROOT/fleet/$seed_task/app"
printf 'in_progress\n' > "$TEST_ROOT/fleet/$seed_task/app/status"
printf '%%1\n' > "$TEST_ROOT/fleet/$seed_task/app/pane"
# Must exactly match what the fake tmux's LIVE_PANES branch reports for %1.
printf '0|%%1|1111|111111|coordinator-command\n' > "$TEST_ROOT/fleet/$seed_task/app/pane_identity"
chmod 600 "$TEST_ROOT/fleet/$seed_task/app/pane_identity"
LIVE_PANES='%1'

# ── 2. Over budget: a --json dispatch queues instead of bypassing admission ─
# The seeded live worker + SERGEANT_DISPATCH_MAX_WORKERS=1 forces this call
# over budget.

before_tasks="$(_fleet_task_dirs)"
brief2="$(_brief_file 'JSON overbudget brief')"
json_out2="$(SERGEANT_DISPATCH_MAX_WORKERS=1 _env "$ROOT_DIR/bin/sgt-dispatch" test \
  --brief-file "$brief2" --repos app --branch json-overbudget-branch --json \
  --origin-profile testprofile \
  --correlation-id corr-overbudget-001 2>"$TEST_ROOT/stderr2.log")"
status2="$(printf '%s' "$json_out2" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' 2>/dev/null || echo PARSE_ERROR)"
after_tasks="$(_fleet_task_dirs)"
if [[ "$status2" == "queued" ]]; then
  _pass "over budget (--json): dispatch reports status=queued instead of bypassing admission control"
else
  _fail "over budget (--json): expected status=queued, got '$status2'; raw=$json_out2 stderr=$(cat "$TEST_ROOT/stderr2.log")"
fi
if [[ "$after_tasks" == "$before_tasks" ]]; then
  _pass "over budget (--json): no new fleet task directory was created"
else
  _fail "over budget (--json): a fleet task directory was created despite being over budget"
fi
task_id2="$(printf '%s' "$json_out2" | python3 -c 'import json,sys; print(json.load(sys.stdin)["task_id"])' 2>/dev/null || true)"
if [[ -n "$task_id2" && -d "$TEST_ROOT/fleet/.dispatch-queue/$task_id2" ]]; then
  _pass "over budget (--json): a durable queue entry was recorded under its returned task_id"
else
  _fail "over budget (--json): expected a queue entry for task_id '$task_id2'"
fi
if [[ "$(cat "$TEST_ROOT/fleet/.dispatch-queue/$task_id2/origin_profile" 2>/dev/null)" == "testprofile" && \
      "$(cat "$TEST_ROOT/fleet/.dispatch-queue/$task_id2/correlation_id" 2>/dev/null)" == "corr-overbudget-001" ]]; then
  _pass "over budget (--json): the queue entry records origin_profile/correlation_id for later replay"
else
  _fail "over budget (--json): queue entry missing origin_profile/correlation_id"
fi

# ── 3. A retry of the same correlated request while still queued is a no-op,
# not a collision or a duplicate entry ───────────────────────────────────────

json_out2b="$(SERGEANT_DISPATCH_MAX_WORKERS=1 _env "$ROOT_DIR/bin/sgt-dispatch" test \
  --brief-file "$brief2" --repos app --branch json-overbudget-branch --json \
  --origin-profile testprofile \
  --correlation-id corr-overbudget-001 2>"$TEST_ROOT/stderr2b.log")"
status2b="$(printf '%s' "$json_out2b" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' 2>/dev/null || echo PARSE_ERROR)"
task_id2b="$(printf '%s' "$json_out2b" | python3 -c 'import json,sys; print(json.load(sys.stdin)["task_id"])' 2>/dev/null || true)"
if [[ "$status2b" == "queued" && "$task_id2b" == "$task_id2" ]]; then
  _pass "over budget (--json): a retry of the same correlation resolves to the same queued task_id"
else
  _fail "over budget (--json): retry expected status=queued task_id=$task_id2, got status=$status2b task_id=$task_id2b; stderr=$(cat "$TEST_ROOT/stderr2b.log")"
fi
queue_entry_count="$(find "$TEST_ROOT/fleet/.dispatch-queue" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
if [[ "$queue_entry_count" == "1" ]]; then
  _pass "over budget (--json): the retry did not create a second, duplicate queue entry"
else
  _fail "over budget (--json): expected exactly 1 queue entry after retry, found $queue_entry_count"
fi

# ── 4. Capacity freeing up replays the queued --json call correctly ────────
# Verified against a fake dispatch_bin that only records its argv: this keeps
# the assertion scoped to _sgt_dispatch_queue_promote_ready's own replay
# construction (does it correctly reconstruct a --json/--origin-profile/
# --correlation-id call with a valid --brief-file, rather than --resume-task-id)
# without also depending on this fixture's fake tmux fully simulating the
# --json path's separate synchronous notification-handshake wait.

printf 'done\n' > "$TEST_ROOT/fleet/$seed_task/app/status"

promote_log="$TEST_ROOT/promote-replay.log"
brief_capture="$TEST_ROOT/promote-replay-brief.log"
cat > "$TEST_ROOT/fake-bin/sgt-dispatch-fake" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$promote_log"
# Capture the --brief-file's content now: the real promote_ready removes this
# temp file immediately after a successful (here: fake) dispatch call returns.
prev=""
for arg in "\$@"; do
  if [[ "\$prev" == "--brief-file" ]]; then
    cat "\$arg" > "$brief_capture" 2>/dev/null || true
  fi
  prev="\$arg"
done
exit 0
EOF
chmod +x "$TEST_ROOT/fake-bin/sgt-dispatch-fake"

_env SERGEANT_DISPATCH_MAX_WORKERS=1 SGT_TEST_HOOKS=1 \
  _SGT_DISPATCH_QUEUE_EXECUTABLE_OVERRIDE="$TEST_ROOT/fake-bin/sgt-dispatch-fake" \
  bash -c 'source "$1"; _sgt_dispatch_queue_promote_ready' \
  _ "$ROOT_DIR/bin/_sgt-lib.sh" >/dev/null 2>"$TEST_ROOT/promote-stderr.log"

replay_call="$(cat "$promote_log" 2>/dev/null || true)"
if [[ "$replay_call" == *"--json"* && "$replay_call" == *"--origin-profile"*"testprofile"* && \
      "$replay_call" == *"--correlation-id"*"corr-overbudget-001"* ]]; then
  _pass "promotion (--json): replays with --json/--origin-profile/--correlation-id, not --resume-task-id"
else
  _fail "promotion (--json): replay args wrong: $replay_call; stderr=$(cat "$TEST_ROOT/promote-stderr.log")"
fi
if [[ "$replay_call" != *"--resume-task-id"* ]]; then
  _pass "promotion (--json): never passes --resume-task-id (correlation resolution already reuses the task_id)"
else
  _fail "promotion (--json): should not pass --resume-task-id for a correlated replay: $replay_call"
fi
if [[ "$(cat "$brief_capture" 2>/dev/null)" == "JSON overbudget brief" ]]; then
  _pass "promotion (--json): replays via a fresh --brief-file carrying the original brief content"
else
  _fail "promotion (--json): expected --brief-file with original content, got '$(cat "$brief_capture" 2>/dev/null)'"
fi
if [[ ! -d "$TEST_ROOT/fleet/.dispatch-queue/$task_id2" ]]; then
  _pass "promotion (--json): the queue entry is removed once the replay succeeds"
else
  _fail "promotion (--json): queue entry for $task_id2 should have been removed"
fi

printf '\nsgt-dispatch-admission-control-json: %d passed' "$pass"
if [[ "$fail" -gt 0 ]]; then
  printf ', %d FAILED\n' "$fail" >&2
  exit 1
fi
printf '\n'
