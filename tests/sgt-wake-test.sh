#!/usr/bin/env bash
# Tests for sgt-wake — durable wake condition scheduler.
#
# Seams under test:
#   sgt-wake <task-id> <repo>   reads fleet state + .sergeant-wake-condition,
#                                evaluates condition, resumes or records attempt
#   sgt-respond with waiting    waiting status is resumable
#   sgt-interactive-worker      waiting status exits cleanly (not orphaned)
#   sgt-dispatch brief          prohibits sleep loops; documents waiting/wake

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

FLEET_DIR="$TEST_ROOT/fleet"
export SERGEANT_FLEET="$FLEET_DIR"

# ── Helpers ──────────────────────────────────────────────────────────────────

_setup_waiting_worker() {
  local task_id="$1"
  local repo="$2"
  local worktree="$3"
  local condition_kind="${4:-not_before}"
  local extra_fields="${5:-}"
  local task_dir="$FLEET_DIR/$task_id"
  local repo_dir="$task_dir/$repo"

  mkdir -p "$repo_dir" "$worktree"
  printf '%s\n' "$worktree"            > "$repo_dir/worktree"
  printf 'waiting\n'                   > "$repo_dir/status"
  printf 'waiting\n'                   > "$worktree/.sergeant-status"
  printf '%s\n' "$repo_dir/"          > "$worktree/.sergeant-fleet-dir" 2>/dev/null || true

  {
    printf 'kind=%s\n' "$condition_kind"
    printf 'generation=1\n'
    [[ -z "$extra_fields" ]] || printf '%s\n' "$extra_fields"
  } > "$worktree/.sergeant-wake-condition"
}

_assert() {
  local description="$1"
  local condition="$2"
  if ! eval "$condition"; then
    printf 'FAIL: %s\n' "$description" >&2
    exit 1
  fi
}

_assert_file_contains() {
  local description="$1"
  local file="$2"
  local pattern="$3"
  if ! grep -Fq "$pattern" "$file" 2>/dev/null; then
    printf 'FAIL: %s (expected "%s" in %s)\n' "$description" "$pattern" "$file" >&2
    exit 1
  fi
}

_assert_exits_nonzero() {
  local description="$1"
  shift
  local exit_code=0
  "$@" 2>/dev/null || exit_code=$?
  if [[ "$exit_code" -eq 0 ]]; then
    printf 'FAIL: %s (expected nonzero exit, got 0)\n' "$description" >&2
    exit 1
  fi
}

# ── Fake responder (stubs sgt-respond for wake scheduler tests) ──────────────

_setup_fake_respond() {
  local fake_bin="$1"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/sgt-respond" <<'EOF'
#!/usr/bin/env bash
# Fake sgt-respond: records its invocation and input for test assertions.
printf '%s\n' "$*" >> "$FAKE_RESPOND_CALLS"
cat > "$FAKE_RESPOND_INPUT"
exit 0
EOF
  chmod +x "$fake_bin/sgt-respond"
}

# ── Test 1: not_before condition — not yet met (future timestamp) ────────────
# Expect: records attempt, exits nonzero, does NOT call sgt-respond.

(
  task="t1"; repo="app"; wt="$TEST_ROOT/t1-wt"
  _setup_waiting_worker "$task" "$repo" "$wt" "not_before" \
    "not_before=$(( $(date +%s) + 3600 ))"

  fake_bin="$TEST_ROOT/t1-fakebin"
  _setup_fake_respond "$fake_bin"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t1-respond-calls"
  export FAKE_RESPOND_INPUT="$TEST_ROOT/t1-respond-input"

  exit_code=0
  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null || exit_code=$?
  _assert "not_before future: exits nonzero" "[[ $exit_code -ne 0 ]]"
  _assert "not_before future: sgt-respond not called" "[[ ! -s '$TEST_ROOT/t1-respond-calls' ]]"
  _assert "not_before future: attempt recorded" \
    "[[ -f '$FLEET_DIR/$task/$repo/wake_attempts' ]]"
)

# ── Test 2: not_before condition — met (past timestamp) ─────────────────────
# Expect: calls sgt-respond with wake evidence, exits zero.

(
  task="t2"; repo="app"; wt="$TEST_ROOT/t2-wt"
  _setup_waiting_worker "$task" "$repo" "$wt" "not_before" \
    "not_before=$(( $(date +%s) - 10 ))"

  fake_bin="$TEST_ROOT/t2-fakebin"
  _setup_fake_respond "$fake_bin"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t2-respond-calls"
  export FAKE_RESPOND_INPUT="$TEST_ROOT/t2-respond-input"

  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null
  _assert "not_before past: sgt-respond called" "[[ -s '$TEST_ROOT/t2-respond-calls' ]]"
  _assert_file_contains "not_before past: correct task/repo args" \
    "$TEST_ROOT/t2-respond-calls" "$task $repo"
  _assert "not_before past: evidence non-empty" "[[ -s '$TEST_ROOT/t2-respond-input' ]]"
  _assert_file_contains "not_before past: evidence contains kind" \
    "$TEST_ROOT/t2-respond-input" "not_before"
)

# ── Test 3: fleet_dependency condition — dependency done ─────────────────────
# Expect: condition met → calls sgt-respond.

(
  task="t3"; repo="app"; wt="$TEST_ROOT/t3-wt"
  dep_task="other-task"; dep_repo="service"
  _setup_waiting_worker "$task" "$repo" "$wt" "fleet_dependency" \
    "task_id=$dep_task"$'\n'"repo=$dep_repo"

  # Put the dependency in 'done' state in the fleet.
  mkdir -p "$FLEET_DIR/$dep_task/$dep_repo"
  printf 'done\n' > "$FLEET_DIR/$dep_task/$dep_repo/status"

  fake_bin="$TEST_ROOT/t3-fakebin"
  _setup_fake_respond "$fake_bin"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t3-respond-calls"
  export FAKE_RESPOND_INPUT="$TEST_ROOT/t3-respond-input"

  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null
  _assert "fleet_dependency done: sgt-respond called" "[[ -s '$TEST_ROOT/t3-respond-calls' ]]"
  _assert_file_contains "fleet_dependency done: evidence contains kind" \
    "$TEST_ROOT/t3-respond-input" "fleet_dependency"
)

# ── Test 4: fleet_dependency condition — dependency still in_progress ────────
# Expect: records attempt, exits nonzero.

(
  task="t4"; repo="app"; wt="$TEST_ROOT/t4-wt"
  dep_task="other-task"; dep_repo="service"
  _setup_waiting_worker "$task" "$repo" "$wt" "fleet_dependency" \
    "task_id=$dep_task"$'\n'"repo=$dep_repo"

  mkdir -p "$FLEET_DIR/$dep_task/$dep_repo"
  printf 'in_progress\n' > "$FLEET_DIR/$dep_task/$dep_repo/status"

  fake_bin="$TEST_ROOT/t4-fakebin"
  _setup_fake_respond "$fake_bin"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t4-respond-calls"
  export FAKE_RESPOND_INPUT="$TEST_ROOT/t4-respond-input"

  exit_code=0
  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null || exit_code=$?
  _assert "fleet_dependency in_progress: exits nonzero" "[[ $exit_code -ne 0 ]]"
  _assert "fleet_dependency in_progress: sgt-respond not called" \
    "[[ ! -s '$TEST_ROOT/t4-respond-calls' ]]"
)

# ── Test 5: td_dependency condition — td task done ───────────────────────────
# Expect: condition met → calls sgt-respond.

(
  task="t5"; repo="app"; wt="$TEST_ROOT/t5-wt"
  _setup_waiting_worker "$task" "$repo" "$wt" "td_dependency" \
    "td_task_id=td-abc123"

  fake_bin="$TEST_ROOT/t5-fakebin"
  _setup_fake_respond "$fake_bin"
  # Fake td that reports the dependency as closed/done.
  cat > "$fake_bin/td" <<'EOF'
#!/usr/bin/env bash
# status td-abc123 -> done
if [[ "$1" == "status" ]]; then
  printf 'done\n'
  exit 0
fi
exit 1
EOF
  chmod +x "$fake_bin/td"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t5-respond-calls"
  export FAKE_RESPOND_INPUT="$TEST_ROOT/t5-respond-input"

  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null
  _assert "td_dependency done: sgt-respond called" "[[ -s '$TEST_ROOT/t5-respond-calls' ]]"
  _assert_file_contains "td_dependency done: evidence contains kind" \
    "$TEST_ROOT/t5-respond-input" "td_dependency"
)

# ── Test 6: td_dependency condition — td task open ───────────────────────────
# Expect: records attempt, exits nonzero.

(
  task="t6"; repo="app"; wt="$TEST_ROOT/t6-wt"
  _setup_waiting_worker "$task" "$repo" "$wt" "td_dependency" \
    "td_task_id=td-abc123"

  fake_bin="$TEST_ROOT/t6-fakebin"
  _setup_fake_respond "$fake_bin"
  cat > "$fake_bin/td" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "status" ]]; then
  printf 'in_progress\n'
  exit 0
fi
exit 1
EOF
  chmod +x "$fake_bin/td"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t6-respond-calls"
  export FAKE_RESPOND_INPUT="$TEST_ROOT/t6-respond-input"

  exit_code=0
  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null || exit_code=$?
  _assert "td_dependency open: exits nonzero" "[[ $exit_code -ne 0 ]]"
  _assert "td_dependency open: sgt-respond not called" \
    "[[ ! -s '$TEST_ROOT/t6-respond-calls' ]]"
)

# ── Test 7: github_check condition — check completed ─────────────────────────
# Expect: condition met → calls sgt-respond.

(
  task="t7"; repo="app"; wt="$TEST_ROOT/t7-wt"
  _setup_waiting_worker "$task" "$repo" "$wt" "github_check" \
    "run_id=12345"$'\n'"check_name=ci/test"

  fake_bin="$TEST_ROOT/t7-fakebin"
  _setup_fake_respond "$fake_bin"
  # Fake gh that reports check as completed/success.
  cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
# gh run view <run_id> --json conclusion
if [[ "$1" == "run" && "$2" == "view" ]]; then
  printf '{"conclusion":"success","status":"completed"}\n'
  exit 0
fi
exit 1
EOF
  chmod +x "$fake_bin/gh"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t7-respond-calls"
  export FAKE_RESPOND_INPUT="$TEST_ROOT/t7-respond-input"

  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null
  _assert "github_check success: sgt-respond called" "[[ -s '$TEST_ROOT/t7-respond-calls' ]]"
  _assert_file_contains "github_check success: evidence contains kind" \
    "$TEST_ROOT/t7-respond-input" "github_check"
)

# ── Test 8: github_check condition — check still pending ─────────────────────
# Expect: records attempt, exits nonzero.

(
  task="t8"; repo="app"; wt="$TEST_ROOT/t8-wt"
  _setup_waiting_worker "$task" "$repo" "$wt" "github_check" \
    "run_id=12345"$'\n'"check_name=ci/test"

  fake_bin="$TEST_ROOT/t8-fakebin"
  _setup_fake_respond "$fake_bin"
  cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "run" && "$2" == "view" ]]; then
  printf '{"conclusion":null,"status":"in_progress"}\n'
  exit 0
fi
exit 1
EOF
  chmod +x "$fake_bin/gh"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t8-respond-calls"
  export FAKE_RESPOND_INPUT="$TEST_ROOT/t8-respond-input"

  exit_code=0
  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null || exit_code=$?
  _assert "github_check pending: exits nonzero" "[[ $exit_code -ne 0 ]]"
  _assert "github_check pending: sgt-respond not called" \
    "[[ ! -s '$TEST_ROOT/t8-respond-calls' ]]"
)

# ── Test 9: human_response condition ────────────────────────────────────────
# Expect: sets needs_input so human can resume via sgt-respond.

(
  task="t9"; repo="app"; wt="$TEST_ROOT/t9-wt"
  _setup_waiting_worker "$task" "$repo" "$wt" "human_response"

  fake_bin="$TEST_ROOT/t9-fakebin"
  _setup_fake_respond "$fake_bin"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t9-respond-calls"
  export FAKE_RESPOND_INPUT="$TEST_ROOT/t9-respond-input"

  exit_code=0
  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null || exit_code=$?
  _assert "human_response: exits nonzero (needs human)" "[[ $exit_code -ne 0 ]]"
  _assert "human_response: sgt-respond not auto-called" \
    "[[ ! -s '$TEST_ROOT/t9-respond-calls' ]]"
  _assert "human_response: status set to needs_input" \
    "[[ \"\$(cat '$FLEET_DIR/$task/$repo/status' 2>/dev/null)\" == 'needs_input' ]]"
)

# ── Test 10: expired deadline ────────────────────────────────────────────────
# Expect: sets failed status with reason.

(
  task="t10"; repo="app"; wt="$TEST_ROOT/t10-wt"
  past="$(( $(date +%s) - 10 ))"
  _setup_waiting_worker "$task" "$repo" "$wt" "not_before" \
    "not_before=$(( $(date +%s) + 3600 ))"$'\n'"deadline=$past"

  fake_bin="$TEST_ROOT/t10-fakebin"
  _setup_fake_respond "$fake_bin"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t10-respond-calls"
  export FAKE_RESPOND_INPUT="$TEST_ROOT/t10-respond-input"

  exit_code=0
  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null || exit_code=$?
  _assert "expired deadline: exits nonzero" "[[ $exit_code -ne 0 ]]"
  _assert "expired deadline: sgt-respond not called" \
    "[[ ! -s '$TEST_ROOT/t10-respond-calls' ]]"
  status="$(cat "$FLEET_DIR/$task/$repo/status" 2>/dev/null || true)"
  _assert "expired deadline: fleet status is failed" \
    "[[ \"\$status\" == failed:* ]]"
  _assert_file_contains "expired deadline: worktree status is failed" \
    "$wt/.sergeant-status" "failed:"
)

# ── Test 11: max_attempts exceeded ──────────────────────────────────────────
# Expect: sets needs_input with message.

(
  task="t11"; repo="app"; wt="$TEST_ROOT/t11-wt"
  _setup_waiting_worker "$task" "$repo" "$wt" "not_before" \
    "not_before=$(( $(date +%s) + 3600 ))"$'\n'"max_attempts=2"

  # Pre-record 2 attempts (already at max).
  mkdir -p "$FLEET_DIR/$task/$repo"
  printf '2\n' > "$FLEET_DIR/$task/$repo/wake_attempts"

  fake_bin="$TEST_ROOT/t11-fakebin"
  _setup_fake_respond "$fake_bin"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t11-respond-calls"

  exit_code=0
  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null || exit_code=$?
  _assert "max_attempts: exits nonzero" "[[ $exit_code -ne 0 ]]"
  status="$(cat "$FLEET_DIR/$task/$repo/status" 2>/dev/null || true)"
  _assert "max_attempts: fleet status is needs_input" \
    "[[ \"\$status\" == 'needs_input' ]]"
  _assert "max_attempts: worktree status is needs_input" \
    "[[ \"\$(cat '$wt/.sergeant-status' 2>/dev/null)\" == 'needs_input' ]]"
  _assert "max_attempts: message file written" \
    "[[ -s '$wt/.sergeant-message' ]]"
)

# ── Test 12: unsupported condition kind ─────────────────────────────────────
# Expect: sets needs_input (unsupported condition cannot be auto-evaluated).

(
  task="t12"; repo="app"; wt="$TEST_ROOT/t12-wt"
  _setup_waiting_worker "$task" "$repo" "$wt" "custom_webhook"

  fake_bin="$TEST_ROOT/t12-fakebin"
  _setup_fake_respond "$fake_bin"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t12-respond-calls"

  exit_code=0
  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null || exit_code=$?
  _assert "unsupported kind: exits nonzero" "[[ $exit_code -ne 0 ]]"
  status="$(cat "$FLEET_DIR/$task/$repo/status" 2>/dev/null || true)"
  _assert "unsupported kind: status set to needs_input" \
    "[[ \"\$status\" == 'needs_input' ]]"
)

# ── Test 13: invalid/suspicious fields rejected ──────────────────────────────
# Expect: exits nonzero without calling sgt-respond; does NOT execute any command.

(
  task="t13"; repo="app"; wt="$TEST_ROOT/t13-wt"
  mkdir -p "$FLEET_DIR/$task/$repo" "$wt"
  printf '%s\n' "$wt"   > "$FLEET_DIR/$task/$repo/worktree"
  printf 'waiting\n'    > "$FLEET_DIR/$task/$repo/status"
  printf 'waiting\n'    > "$wt/.sergeant-status"

  # Wake condition with a command-injection attempt.
  printf 'kind=not_before\ngeneration=1\nnot_before=1000\ntoken=secret123\n' \
    > "$wt/.sergeant-wake-condition"

  fake_bin="$TEST_ROOT/t13-fakebin"
  _setup_fake_respond "$fake_bin"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t13-respond-calls"

  exit_code=0
  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null || exit_code=$?
  _assert "suspicious field token: exits nonzero" "[[ $exit_code -ne 0 ]]"
  _assert "suspicious field token: sgt-respond not called" \
    "[[ ! -s '$TEST_ROOT/t13-respond-calls' ]]"
)

# ── Test 14: deduplication — concurrent schedulers, same generation ──────────
# Expect: second invocation detects active lock and exits without recording.

(
  task="t14"; repo="app"; wt="$TEST_ROOT/t14-wt"
  _setup_waiting_worker "$task" "$repo" "$wt" "not_before" \
    "not_before=$(( $(date +%s) + 3600 ))"

  # Pre-acquire the lock for generation 1.
  lock_dir="$FLEET_DIR/$task/$repo/wake.lock"
  mkdir -p "$lock_dir"
  printf '%s\n' "$$" > "$lock_dir/pid"

  fake_bin="$TEST_ROOT/t14-fakebin"
  _setup_fake_respond "$fake_bin"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t14-respond-calls"

  exit_code=0
  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null || exit_code=$?
  _assert "dedup: exits nonzero when locked" "[[ $exit_code -ne 0 ]]"
  _assert "dedup: sgt-respond not called" \
    "[[ ! -s '$TEST_ROOT/t14-respond-calls' ]]"
  # Clean up lock.
  rm -rf "$lock_dir"
)

# ── Test 15: atomic attempt recording with backoff fields ───────────────────
# Expect: wake_attempts, last_attempt_ts, backoff_jitter, next_not_before written.

(
  task="t15"; repo="app"; wt="$TEST_ROOT/t15-wt"
  _setup_waiting_worker "$task" "$repo" "$wt" "not_before" \
    "not_before=$(( $(date +%s) + 3600 ))"$'\n'"backoff_base=60"

  fake_bin="$TEST_ROOT/t15-fakebin"
  _setup_fake_respond "$fake_bin"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t15-respond-calls"

  exit_code=0
  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null || exit_code=$?
  _assert "atomic attempt: exits nonzero" "[[ $exit_code -ne 0 ]]"
  _assert "atomic attempt: wake_attempts written" \
    "[[ -f '$FLEET_DIR/$task/$repo/wake_attempts' ]]"
  attempts="$(cat "$FLEET_DIR/$task/$repo/wake_attempts" 2>/dev/null || echo 0)"
  _assert "atomic attempt: count is 1" "[[ \"\$attempts\" == '1' ]]"
  _assert "atomic attempt: last_attempt_ts written" \
    "[[ -s '$FLEET_DIR/$task/$repo/wake_last_attempt_ts' ]]"
  _assert "atomic attempt: backoff_jitter written" \
    "[[ -s '$FLEET_DIR/$task/$repo/wake_backoff_jitter' ]]"
  _assert "atomic attempt: next_not_before written" \
    "[[ -s '$FLEET_DIR/$task/$repo/wake_next_not_before' ]]"
  # next_not_before must be >= last_attempt_ts + backoff_base.
  last_ts="$(cat "$FLEET_DIR/$task/$repo/wake_last_attempt_ts")"
  next="$(cat "$FLEET_DIR/$task/$repo/wake_next_not_before")"
  _assert "atomic attempt: next_not_before includes backoff" \
    "(( next >= last_ts + 60 ))"
)

# ── Test 16: sgt-wake requires waiting status ────────────────────────────────
# Expect: if worker is not in 'waiting' state, exits nonzero without resume.

(
  task="t16"; repo="app"; wt="$TEST_ROOT/t16-wt"
  mkdir -p "$FLEET_DIR/$task/$repo" "$wt"
  printf '%s\n' "$wt"    > "$FLEET_DIR/$task/$repo/worktree"
  printf 'in_progress\n' > "$FLEET_DIR/$task/$repo/status"
  printf 'in_progress\n' > "$wt/.sergeant-status"
  printf 'kind=not_before\ngeneration=1\nnot_before=1000\n' \
    > "$wt/.sergeant-wake-condition"

  fake_bin="$TEST_ROOT/t16-fakebin"
  _setup_fake_respond "$fake_bin"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t16-respond-calls"

  exit_code=0
  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null || exit_code=$?
  _assert "non-waiting status: exits nonzero" "[[ $exit_code -ne 0 ]]"
  _assert "non-waiting status: sgt-respond not called" \
    "[[ ! -s '$TEST_ROOT/t16-respond-calls' ]]"
)

# ── Test 17: no wake condition file ─────────────────────────────────────────
# Expect: exits nonzero cleanly (no condition to evaluate).

(
  task="t17"; repo="app"; wt="$TEST_ROOT/t17-wt"
  mkdir -p "$FLEET_DIR/$task/$repo" "$wt"
  printf '%s\n' "$wt"    > "$FLEET_DIR/$task/$repo/worktree"
  printf 'waiting\n'     > "$FLEET_DIR/$task/$repo/status"
  printf 'waiting\n'     > "$wt/.sergeant-status"
  # No .sergeant-wake-condition file.

  fake_bin="$TEST_ROOT/t17-fakebin"
  _setup_fake_respond "$fake_bin"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t17-respond-calls"

  exit_code=0
  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null || exit_code=$?
  _assert "no condition file: exits nonzero" "[[ $exit_code -ne 0 ]]"
  _assert "no condition file: sgt-respond not called" \
    "[[ ! -s '$TEST_ROOT/t17-respond-calls' ]]"
)

# ── Test 18: github_check adapter error (gh returns error) ──────────────────
# Expect: records adapter error in fleet diagnostic, exits nonzero.

(
  task="t18"; repo="app"; wt="$TEST_ROOT/t18-wt"
  _setup_waiting_worker "$task" "$repo" "$wt" "github_check" \
    "run_id=99999"$'\n'"check_name=ci/test"

  fake_bin="$TEST_ROOT/t18-fakebin"
  _setup_fake_respond "$fake_bin"
  # Fake gh that exits nonzero to simulate adapter failure.
  cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$fake_bin/gh"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t18-respond-calls"
  export FAKE_RESPOND_INPUT="$TEST_ROOT/t18-respond-input"

  exit_code=0
  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null || exit_code=$?
  _assert "gh error: exits nonzero" "[[ $exit_code -ne 0 ]]"
  _assert "gh error: sgt-respond not called" \
    "[[ ! -s '$TEST_ROOT/t18-respond-calls' ]]"
  _assert "gh error: diagnostic recorded" \
    "[[ -s '$FLEET_DIR/$task/$repo/diagnostic' ]]"
)

# ── Test 19: deployment condition — sets needs_input (adapter not yet wired) ─
# Expect: deployment kind is known but auto-evaluation is unsupported → needs_input.

(
  task="t19a"; repo="app"; wt="$TEST_ROOT/t19a-wt"
  _setup_waiting_worker "$task" "$repo" "$wt" "deployment" \
    "app=myapp"$'\n'"env=production"

  fake_bin="$TEST_ROOT/t19a-fakebin"
  _setup_fake_respond "$fake_bin"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t19a-respond-calls"

  exit_code=0
  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null || exit_code=$?
  _assert "deployment: exits nonzero" "[[ $exit_code -ne 0 ]]"
  _assert "deployment: sgt-respond not called" \
    "[[ ! -s '$TEST_ROOT/t19a-respond-calls' ]]"
  status="$(cat "$FLEET_DIR/$task/$repo/status" 2>/dev/null || true)"
  _assert "deployment: status set to needs_input" \
    "[[ \"\$status\" == 'needs_input' ]]"
  _assert "deployment: message written" \
    "[[ -s '$wt/.sergeant-message' ]]"
)

# ── Test 21: sgt-interactive-worker exits cleanly with 'waiting' status ──────
# Expect: worker exits with 'waiting' (not orphaned), fleet status = waiting.

(
  wt="$TEST_ROOT/t19-wt"
  repo_state="$TEST_ROOT/t19-state"
  fake_bin="$TEST_ROOT/t19-fakebin"
  mkdir -p "$wt" "$repo_state" "$fake_bin"

  # Fake 'opencode' agent that writes waiting status and a wake condition, exits.
  # sgt-interactive-worker only accepts: opencode, oc, goose, claude.
  cat > "$fake_bin/opencode" <<'AGENT'
#!/usr/bin/env bash
printf 'waiting\n' > .sergeant-status
printf 'kind=not_before\ngeneration=1\nnot_before=9999999999\n' \
  > .sergeant-wake-condition
AGENT
  chmod +x "$fake_bin/opencode"

  # sgt-interactive-worker requires a terminal; use script(1) to provide a pty.
  script_out="$TEST_ROOT/t19-script.out"
  script -q -e -c \
    "PATH='$fake_bin:$PATH' TMUX_PANE=%99 '$ROOT_DIR/bin/sgt-interactive-worker' '$repo_state' '$wt' '$fake_bin/opencode'" \
    "$script_out" 2>/dev/null || true

  wt_status="$(cat "$wt/.sergeant-status" 2>/dev/null || echo unknown)"
  fleet_status="$(cat "$repo_state/status" 2>/dev/null || echo unknown)"
  _assert "interactive-worker waiting: worktree status is waiting" \
    "[[ \"\$wt_status\" == 'waiting' ]]"
  _assert "interactive-worker waiting: fleet status is waiting" \
    "[[ \"\$fleet_status\" == 'waiting' ]]"
  _assert "interactive-worker waiting: no orphan diagnostic" \
    "[[ ! -s '$repo_state/diagnostic' ]]"
)

# ── Test 22: sgt-dispatch brief template prohibits sleep and documents waiting
# Expect: sgt-dispatch source contains the required wake guidance strings.
# The brief template is embedded in sgt-dispatch; verify its content directly.

(
  dispatch="$ROOT_DIR/bin/sgt-dispatch"
  _assert_file_contains "dispatch brief prohibits sleep loops" "$dispatch" \
    "Do not use sleep or polling loops for deferred work"
  _assert_file_contains "dispatch brief documents waiting status" "$dispatch" \
    "waiting"
  _assert_file_contains "dispatch brief documents wake condition file" "$dispatch" \
    ".sergeant-wake-condition"
)

printf 'sgt-wake: all tests passed\n'
