#!/usr/bin/env bash
# Tests for sgt-wake — durable wake condition scheduler.
#
# Seams under test:
#   sgt-wake <task-id> <repo>   reads fleet state + .sergeant-wake-condition,
#                                evaluates condition, resumes or records attempt
#   sgt-respond with waiting    waiting status is resumable
#   sgt-interactive-worker      waiting status exits cleanly (not orphaned)
#   sgt-dispatch brief          prohibits sleep loops; documents waiting/wake
#
# shellcheck disable=SC2030,SC2031,SC2034
# Test cases run in subshells for isolation, and assertions intentionally
# reference variables through eval strings.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

FLEET_DIR="$TEST_ROOT/fleet"
export SERGEANT_FLEET="$FLEET_DIR"
# ── Drain state isolation (td-79f0a8) ────────────────────────────────────────
# Commands exercised here source bin/_sgt-drain.sh, which resolves
# SERGEANT_DRAIN_DIR, else SERGEANT_CONFIG/drain, else the operator's real
# $HOME/.config/sergeant/drain.  Pin it to this suite's temporary root so the
# tests never consult — or mutate — live drain state.
export SERGEANT_DRAIN_DIR="$TEST_ROOT/drain"
export SERGEANT_CONFIG="$TEST_ROOT/sergeant-config"
mkdir -p "$SERGEANT_DRAIN_DIR" "$SERGEANT_CONFIG"

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

# _init_worktree_repo <dir> <origin_url>
#
# Makes <dir> a real git repository with an `origin` remote, so the wake
# adapters can resolve the owning GitHub repository from the recorded worktree.
_init_worktree_repo() {
  local dir="$1" remote_url="$2"
  mkdir -p "$dir"
  git -C "$dir" init --quiet
  git -C "$dir" remote add origin "$remote_url" 2>/dev/null || \
    git -C "$dir" remote set-url origin "$remote_url"
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

# ── Fake gh (resolves a base repo the way gh really does) ─────────────────────

# _setup_fake_gh <fake_bin> <run_json_file> <slug_record_file>
#
# Installs a `gh` stub that mirrors gh's base-repo resolution: an explicit
# --repo wins, otherwise the repository is derived from the current directory's
# `origin` remote, and when neither is available it fails with gh's real
# "failed to determine base repo" error on stderr.  The resolved slug is
# recorded so tests can prove which repository was queried.
_setup_fake_gh() {
  local fake_bin="$1" run_json="$2" slug_file="$3"
  mkdir -p "$fake_bin"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'FAKE_GH_JSON=%q\n' "$run_json"
    printf 'FAKE_GH_SLUG=%q\n' "$slug_file"
    cat <<'EOF'
slug=""
prev=""
for arg in "$@"; do
  [[ "$prev" != "--repo" ]] || slug="$arg"
  prev="$arg"
done
if [[ -z "$slug" ]]; then
  url="$(git remote get-url origin 2>/dev/null || true)"
  if [[ -n "$url" ]]; then
    slug="${url%.git}"
    slug="${slug#*github.com/}"
    slug="${slug#*github.com:}"
  fi
fi
if [[ -z "$slug" ]]; then
  printf 'failed to determine base repo: failed to run git: fatal: not a git repository\n' >&2
  exit 1
fi
printf '%s\n' "$slug" > "$FAKE_GH_SLUG"
printf '%s\n' "$*" >> "${FAKE_GH_SLUG}.args"
cat "$FAKE_GH_JSON"
EOF
  } > "$fake_bin/gh"
  chmod +x "$fake_bin/gh"
}

# ── Subshell failure propagation ─────────────────────────────────────────────
# Each test case runs in an isolated subshell.  Under set -euo pipefail, _assert
# calls exit 1 which exits only the subshell — the parent process never sees the
# failure unless we explicitly capture each subshell's exit code.
_wake_test_failed=0

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
) || _wake_test_failed=$((_wake_test_failed + 1))

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
) || _wake_test_failed=$((_wake_test_failed + 1))

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
) || _wake_test_failed=$((_wake_test_failed + 1))

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
) || _wake_test_failed=$((_wake_test_failed + 1))

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
) || _wake_test_failed=$((_wake_test_failed + 1))

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
) || _wake_test_failed=$((_wake_test_failed + 1))

# ── Test 7: github_check condition — named check completed successfully ──────
# Expect: condition met → calls sgt-respond.

(
  task="t7"; repo="app"; wt="$TEST_ROOT/t7-wt"
  _setup_waiting_worker "$task" "$repo" "$wt" "github_check" \
    "run_id=12345"$'\n'"check_name=ci/test"

  fake_bin="$TEST_ROOT/t7-fakebin"
  _setup_fake_respond "$fake_bin"
  # Fake gh that reports the named check as completed/success.
  cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
# gh run view <run_id> --json status,conclusion,jobs
if [[ "$1" == "run" && "$2" == "view" ]]; then
  printf '{"conclusion":"success","status":"completed","jobs":[{"name":"ci/test","status":"completed","conclusion":"success"}]}\n'
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
) || _wake_test_failed=$((_wake_test_failed + 1))

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
) || _wake_test_failed=$((_wake_test_failed + 1))

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
) || _wake_test_failed=$((_wake_test_failed + 1))

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
) || _wake_test_failed=$((_wake_test_failed + 1))

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
) || _wake_test_failed=$((_wake_test_failed + 1))

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
) || _wake_test_failed=$((_wake_test_failed + 1))

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
) || _wake_test_failed=$((_wake_test_failed + 1))

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
) || _wake_test_failed=$((_wake_test_failed + 1))

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
) || _wake_test_failed=$((_wake_test_failed + 1))

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
) || _wake_test_failed=$((_wake_test_failed + 1))

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
) || _wake_test_failed=$((_wake_test_failed + 1))

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
) || _wake_test_failed=$((_wake_test_failed + 1))

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
) || _wake_test_failed=$((_wake_test_failed + 1))

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
) || _wake_test_failed=$((_wake_test_failed + 1))

# ── Test 22: sgt-dispatch brief template prohibits sleep and documents waiting
# Expect: the worker brief template contains the required wake guidance strings.
# The brief was extracted from sgt-dispatch to templates/worker-brief.md
# (GH #182); check the template file, not the dispatch script.

(
  brief_template="$ROOT_DIR/templates/worker-brief.md"
  _assert_file_contains "dispatch brief prohibits sleep loops" "$brief_template" \
    "Do not use sleep or polling loops for deferred work"
  _assert_file_contains "dispatch brief documents waiting status" "$brief_template" \
    "waiting"
  _assert_file_contains "dispatch brief documents wake condition file" "$brief_template" \
    ".sergeant-wake-condition"
) || _wake_test_failed=$((_wake_test_failed + 1))

# ── Test 23 (td-89a991 / GH #176): github_check resolves the owning repo ─────
# The scheduler normally runs from wherever the coordinator invoked it, which is
# usually NOT inside the worker's repository.  gh resolves its base repo from
# the cwd, so the adapter must bind the query to the worker's recorded repo.
# Expect: the run is resolved against the worker's repo and the worker is woken.

(
  task="t23"; repo="app"; wt="$TEST_ROOT/t23-wt"
  _setup_waiting_worker "$task" "$repo" "$wt" "github_check" \
    "run_id=30878953687"$'\n'"check_name=unit-tests"
  _init_worktree_repo "$wt" "https://github.com/acme/widget.git"

  fake_bin="$TEST_ROOT/t23-fakebin"
  _setup_fake_respond "$fake_bin"
  run_json="$TEST_ROOT/t23-run.json"
  cat > "$run_json" <<'JSON'
{"status":"completed","conclusion":"success",
 "jobs":[{"name":"unit-tests","status":"completed","conclusion":"success"}]}
JSON
  slug_file="$TEST_ROOT/t23-slug"
  _setup_fake_gh "$fake_bin" "$run_json" "$slug_file"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t23-respond-calls"
  export FAKE_RESPOND_INPUT="$TEST_ROOT/t23-respond-input"

  # Invoke from a directory that is not a git repository at all.
  outside="$TEST_ROOT/t23-outside"
  mkdir -p "$outside"
  exit_code=0
  (
    cd "$outside" || exit 1
    PATH="$fake_bin:$PATH" "$ROOT_DIR/bin/sgt-wake" "$task" "$repo"
  ) 2>/dev/null || exit_code=$?

  _assert "github_check from outside repo: exits zero" "[[ $exit_code -eq 0 ]]"
  _assert "github_check from outside repo: sgt-respond called" \
    "[[ -s '$TEST_ROOT/t23-respond-calls' ]]"
  _assert "github_check from outside repo: queried the worker's own repository" \
    "[[ \"\$(cat '$slug_file' 2>/dev/null)\" == 'acme/widget' ]]"
) || _wake_test_failed=$((_wake_test_failed + 1))

# ── Test 24 (td-89a991 / GH #176): gh failure is surfaced, not swallowed ─────
# Expect: the real gh error text reaches the fleet diagnostic so a resolution
# failure is distinguishable from a genuinely pending run.

(
  task="t24"; repo="app"; wt="$TEST_ROOT/t24-wt"
  _setup_waiting_worker "$task" "$repo" "$wt" "github_check" \
    "run_id=555"$'\n'"check_name=unit-tests"

  fake_bin="$TEST_ROOT/t24-fakebin"
  _setup_fake_respond "$fake_bin"
  cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
printf 'HTTP 403: Resource not accessible by integration\n' >&2
exit 1
EOF
  chmod +x "$fake_bin/gh"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t24-respond-calls"

  exit_code=0
  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null || exit_code=$?
  _assert "gh failure: exits nonzero" "[[ $exit_code -ne 0 ]]"
  _assert "gh failure: sgt-respond not called" \
    "[[ ! -s '$TEST_ROOT/t24-respond-calls' ]]"
  _assert_file_contains "gh failure: stderr surfaced in diagnostic" \
    "$FLEET_DIR/$task/$repo/diagnostic" "Resource not accessible by integration"
) || _wake_test_failed=$((_wake_test_failed + 1))

# ── Test 25 (td-cccc42 / GH #174): check_name may contain spaces ─────────────
# Ordinary GitHub check names contain spaces and parentheses.  Expect: the
# condition parses and evaluates rather than being rejected before the query.

(
  task="t25"; repo="app"; wt="$TEST_ROOT/t25-wt"
  _setup_waiting_worker "$task" "$repo" "$wt" "github_check" \
    "run_id=777"$'\n'"check_name=All Tests Pass"
  _init_worktree_repo "$wt" "git@github.com:acme/widget.git"

  fake_bin="$TEST_ROOT/t25-fakebin"
  _setup_fake_respond "$fake_bin"
  run_json="$TEST_ROOT/t25-run.json"
  cat > "$run_json" <<'JSON'
{"status":"completed","conclusion":"success",
 "jobs":[{"name":"All Tests Pass","status":"completed","conclusion":"success"}]}
JSON
  _setup_fake_gh "$fake_bin" "$run_json" "$TEST_ROOT/t25-slug"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t25-respond-calls"
  export FAKE_RESPOND_INPUT="$TEST_ROOT/t25-respond-input"

  exit_code=0
  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null || exit_code=$?
  _assert "check_name with spaces: exits zero" "[[ $exit_code -eq 0 ]]"
  _assert "check_name with spaces: sgt-respond called" \
    "[[ -s '$TEST_ROOT/t25-respond-calls' ]]"
  _assert "check_name with spaces: ssh remote resolved to a slug" \
    "[[ \"\$(cat '$TEST_ROOT/t25-slug' 2>/dev/null)\" == 'acme/widget' ]]"
) || _wake_test_failed=$((_wake_test_failed + 1))

# ── Test 26 (td-cccc42 / GH #174): metacharacters in check_name rejected ─────
# Allowing spaces must not open a word-splitting or injection vector.

(
  task="t26"; repo="app"; wt="$TEST_ROOT/t26-wt"
  _setup_waiting_worker "$task" "$repo" "$wt" "github_check" \
    "run_id=777"$'\n'"check_name=ci \$(touch $TEST_ROOT/t26-pwned)"

  fake_bin="$TEST_ROOT/t26-fakebin"
  _setup_fake_respond "$fake_bin"
  run_json="$TEST_ROOT/t26-run.json"
  printf '{"status":"completed","conclusion":"success","jobs":[]}\n' > "$run_json"
  _setup_fake_gh "$fake_bin" "$run_json" "$TEST_ROOT/t26-slug"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t26-respond-calls"

  exit_code=0
  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null || exit_code=$?
  _assert "check_name injection: exits nonzero" "[[ $exit_code -ne 0 ]]"
  _assert "check_name injection: sgt-respond not called" \
    "[[ ! -s '$TEST_ROOT/t26-respond-calls' ]]"
  _assert "check_name injection: no command executed" \
    "[[ ! -e '$TEST_ROOT/t26-pwned' ]]"
  # Discriminating: the value must be rejected at parse time, before the
  # condition can reach any external command.
  _assert "check_name injection: rejected before GitHub was queried" \
    "[[ ! -e '$TEST_ROOT/t26-slug' ]]"
) || _wake_test_failed=$((_wake_test_failed + 1))

# ── Test 26b (SPEC-001): ordinary check names are representable ───────────────
# Real GitHub check names contain ampersands, brackets, and leading dots.

(
  for name in "Build & Test" "test [linux]" ".NET build" "cov 80%" "build (matrix=3.11)"; do
    task="t26b"; repo="app"; wt="$TEST_ROOT/t26b-wt"
    rm -rf "${FLEET_DIR:?}/${task:?}" "${wt:?}"
    _setup_waiting_worker "$task" "$repo" "$wt" "github_check" \
      "run_id=777"$'\n'"check_name=$name"
    _init_worktree_repo "$wt" "https://github.com/acme/widget.git"

    fake_bin="$TEST_ROOT/t26b-fakebin"
    _setup_fake_respond "$fake_bin"
    run_json="$TEST_ROOT/t26b-run.json"
    python3 - "$name" > "$run_json" <<'PY'
import json, sys
print(json.dumps({"status": "completed", "conclusion": "success",
                  "jobs": [{"name": sys.argv[1], "status": "completed",
                            "conclusion": "success"}]}))
PY
    rm -f "$TEST_ROOT/t26b-slug"
    _setup_fake_gh "$fake_bin" "$run_json" "$TEST_ROOT/t26b-slug"
    export FAKE_RESPOND_CALLS="$TEST_ROOT/t26b-respond-calls"
    export FAKE_RESPOND_INPUT="$TEST_ROOT/t26b-respond-input"
    rm -f "$FAKE_RESPOND_CALLS"

    exit_code=0
    PATH="$fake_bin:$PATH" \
      "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null || exit_code=$?
    _assert "check_name '$name': exits zero" "[[ $exit_code -eq 0 ]]"
    _assert "check_name '$name': sgt-respond called" \
      "[[ -s '$FAKE_RESPOND_CALLS' ]]"
  done
) || _wake_test_failed=$((_wake_test_failed + 1))

# ── Test 26c (STD-017): a present-but-empty field is named as empty ───────────

(
  task="t26c"; repo="app"; wt="$TEST_ROOT/t26c-wt"
  _setup_waiting_worker "$task" "$repo" "$wt" "github_check" \
    "run_id=777"$'\n'"check_name="

  fake_bin="$TEST_ROOT/t26c-fakebin"
  _setup_fake_respond "$fake_bin"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t26c-respond-calls"

  err="$TEST_ROOT/t26c.err"
  exit_code=0
  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>"$err" || exit_code=$?
  _assert "empty check_name: exits nonzero" "[[ $exit_code -ne 0 ]]"
  _assert_file_contains "empty check_name: reported as empty, not as bad characters" \
    "$err" "empty value"
) || _wake_test_failed=$((_wake_test_failed + 1))

# ── Test 26d (RDY-007): a dash-leading value is not passed to gh as an option ──

(
  task="t26d"; repo="app"; wt="$TEST_ROOT/t26d-wt"
  _setup_waiting_worker "$task" "$repo" "$wt" "github_check" \
    "run_id=--help"$'\n'"check_name=unit-tests"
  _init_worktree_repo "$wt" "https://github.com/acme/widget.git"

  fake_bin="$TEST_ROOT/t26d-fakebin"
  _setup_fake_respond "$fake_bin"
  run_json="$TEST_ROOT/t26d-run.json"
  printf '{"status":"completed","conclusion":"success","jobs":[]}\n' > "$run_json"
  _setup_fake_gh "$fake_bin" "$run_json" "$TEST_ROOT/t26d-slug"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t26d-respond-calls"

  exit_code=0
  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null || exit_code=$?
  _assert "dash-leading run_id: exits nonzero" "[[ $exit_code -ne 0 ]]"
  _assert "dash-leading run_id: sgt-respond not called" \
    "[[ ! -s '$TEST_ROOT/t26d-respond-calls' ]]"
  _assert "dash-leading run_id: gh was never invoked" \
    "[[ ! -e '$TEST_ROOT/t26d-slug' ]]"
) || _wake_test_failed=$((_wake_test_failed + 1))

# ── Test 27 (td-cccc42 / GH #174): a failed named check must NOT wake ────────
# Expect: no resume, and a conclusive non-success conclusion escalates to
# needs_input rather than pretending the condition may still be met later.

(
  task="t27"; repo="app"; wt="$TEST_ROOT/t27-wt"
  _setup_waiting_worker "$task" "$repo" "$wt" "github_check" \
    "run_id=777"$'\n'"check_name=unit-tests"
  _init_worktree_repo "$wt" "https://github.com/acme/widget.git"

  fake_bin="$TEST_ROOT/t27-fakebin"
  _setup_fake_respond "$fake_bin"
  run_json="$TEST_ROOT/t27-run.json"
  cat > "$run_json" <<'JSON'
{"status":"completed","conclusion":"failure",
 "jobs":[{"name":"unit-tests","status":"completed","conclusion":"failure"}]}
JSON
  _setup_fake_gh "$fake_bin" "$run_json" "$TEST_ROOT/t27-slug"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t27-respond-calls"

  exit_code=0
  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null || exit_code=$?
  _assert "failed check: exits nonzero" "[[ $exit_code -ne 0 ]]"
  _assert "failed check: sgt-respond NOT called" \
    "[[ ! -s '$TEST_ROOT/t27-respond-calls' ]]"
  status="$(cat "$FLEET_DIR/$task/$repo/status" 2>/dev/null || true)"
  _assert "failed check: escalated to needs_input" \
    "[[ \"\$status\" == 'needs_input' ]]"
  _assert_file_contains "failed check: message names the conclusion" \
    "$wt/.sergeant-message" "failure"
) || _wake_test_failed=$((_wake_test_failed + 1))

# ── Test 28 (td-cccc42 / GH #174): only the named check gates the wake ───────
# A run with several checks must be evaluated on the selected check alone.

(
  task="t28"; repo="app"; wt="$TEST_ROOT/t28-wt"
  _setup_waiting_worker "$task" "$repo" "$wt" "github_check" \
    "run_id=777"$'\n'"check_name=unit-tests"
  _init_worktree_repo "$wt" "https://github.com/acme/widget.git"

  fake_bin="$TEST_ROOT/t28-fakebin"
  _setup_fake_respond "$fake_bin"
  run_json="$TEST_ROOT/t28-run.json"
  cat > "$run_json" <<'JSON'
{"status":"completed","conclusion":"failure",
 "jobs":[{"name":"lint","status":"completed","conclusion":"failure"},
         {"name":"unit-tests","status":"completed","conclusion":"success"},
         {"name":"docs","status":"completed","conclusion":"skipped"}]}
JSON
  _setup_fake_gh "$fake_bin" "$run_json" "$TEST_ROOT/t28-slug"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t28-respond-calls"
  export FAKE_RESPOND_INPUT="$TEST_ROOT/t28-respond-input"

  exit_code=0
  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null || exit_code=$?
  _assert "named check success among failures: exits zero" "[[ $exit_code -eq 0 ]]"
  _assert "named check success among failures: sgt-respond called" \
    "[[ -s '$TEST_ROOT/t28-respond-calls' ]]"
  _assert_file_contains "named check success: evidence names the check" \
    "$TEST_ROOT/t28-respond-input" "unit-tests"
) || _wake_test_failed=$((_wake_test_failed + 1))

# ── Test 29 (td-cccc42 / GH #174): a skipped named check must NOT wake ───────
# Same run, but the selected check is the skipped one.

(
  task="t29"; repo="app"; wt="$TEST_ROOT/t29-wt"
  _setup_waiting_worker "$task" "$repo" "$wt" "github_check" \
    "run_id=777"$'\n'"check_name=docs"
  _init_worktree_repo "$wt" "https://github.com/acme/widget.git"

  fake_bin="$TEST_ROOT/t29-fakebin"
  _setup_fake_respond "$fake_bin"
  run_json="$TEST_ROOT/t29-run.json"
  cat > "$run_json" <<'JSON'
{"status":"completed","conclusion":"failure",
 "jobs":[{"name":"unit-tests","status":"completed","conclusion":"success"},
         {"name":"docs","status":"completed","conclusion":"skipped"}]}
JSON
  _setup_fake_gh "$fake_bin" "$run_json" "$TEST_ROOT/t29-slug"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t29-respond-calls"

  exit_code=0
  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null || exit_code=$?
  _assert "skipped check: exits nonzero" "[[ $exit_code -ne 0 ]]"
  _assert "skipped check: sgt-respond NOT called" \
    "[[ ! -s '$TEST_ROOT/t29-respond-calls' ]]"
) || _wake_test_failed=$((_wake_test_failed + 1))

# ── Test 30 (td-cccc42 / GH #174): absent named check is distinct from failed ─
# A completed run that never produced the named check is an adapter error, not
# a silent success and not a check failure.

(
  task="t30"; repo="app"; wt="$TEST_ROOT/t30-wt"
  _setup_waiting_worker "$task" "$repo" "$wt" "github_check" \
    "run_id=777"$'\n'"check_name=nonexistent-check"
  _init_worktree_repo "$wt" "https://github.com/acme/widget.git"

  fake_bin="$TEST_ROOT/t30-fakebin"
  _setup_fake_respond "$fake_bin"
  run_json="$TEST_ROOT/t30-run.json"
  cat > "$run_json" <<'JSON'
{"status":"completed","conclusion":"success",
 "jobs":[{"name":"unit-tests","status":"completed","conclusion":"success"}]}
JSON
  _setup_fake_gh "$fake_bin" "$run_json" "$TEST_ROOT/t30-slug"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t30-respond-calls"

  exit_code=0
  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null || exit_code=$?
  _assert "absent check: exits nonzero" "[[ $exit_code -ne 0 ]]"
  _assert "absent check: sgt-respond NOT called" \
    "[[ ! -s '$TEST_ROOT/t30-respond-calls' ]]"
  _assert_file_contains "absent check: reported as not found" \
    "$FLEET_DIR/$task/$repo/diagnostic" "not found"
) || _wake_test_failed=$((_wake_test_failed + 1))

# ── Test 31 (td-cccc42 / GH #174): an ambiguous named check is reported ──────

(
  task="t31"; repo="app"; wt="$TEST_ROOT/t31-wt"
  _setup_waiting_worker "$task" "$repo" "$wt" "github_check" \
    "run_id=777"$'\n'"check_name=unit-tests"
  _init_worktree_repo "$wt" "https://github.com/acme/widget.git"

  fake_bin="$TEST_ROOT/t31-fakebin"
  _setup_fake_respond "$fake_bin"
  run_json="$TEST_ROOT/t31-run.json"
  cat > "$run_json" <<'JSON'
{"status":"completed","conclusion":"success",
 "jobs":[{"name":"unit-tests","status":"completed","conclusion":"success"},
         {"name":"unit-tests","status":"completed","conclusion":"failure"}]}
JSON
  _setup_fake_gh "$fake_bin" "$run_json" "$TEST_ROOT/t31-slug"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t31-respond-calls"

  exit_code=0
  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null || exit_code=$?
  _assert "ambiguous check: exits nonzero" "[[ $exit_code -ne 0 ]]"
  _assert "ambiguous check: sgt-respond NOT called" \
    "[[ ! -s '$TEST_ROOT/t31-respond-calls' ]]"
  _assert_file_contains "ambiguous check: reported as ambiguous" \
    "$FLEET_DIR/$task/$repo/diagnostic" "ambiguous"
) || _wake_test_failed=$((_wake_test_failed + 1))

# ── Test 32 (td-cccc42 / GH #174): check_name is required (fail closed) ──────
# Without a selected check there is nothing to evaluate, so the adapter must
# refuse rather than accept any completed run.

(
  task="t32"; repo="app"; wt="$TEST_ROOT/t32-wt"
  _setup_waiting_worker "$task" "$repo" "$wt" "github_check" "run_id=777"
  _init_worktree_repo "$wt" "https://github.com/acme/widget.git"

  fake_bin="$TEST_ROOT/t32-fakebin"
  _setup_fake_respond "$fake_bin"
  run_json="$TEST_ROOT/t32-run.json"
  printf '{"status":"completed","conclusion":"success","jobs":[]}\n' > "$run_json"
  _setup_fake_gh "$fake_bin" "$run_json" "$TEST_ROOT/t32-slug"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t32-respond-calls"

  exit_code=0
  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null || exit_code=$?
  _assert "missing check_name: exits nonzero" "[[ $exit_code -ne 0 ]]"
  _assert "missing check_name: sgt-respond NOT called" \
    "[[ ! -s '$TEST_ROOT/t32-respond-calls' ]]"
  _assert "missing check_name: GitHub was never queried" \
    "[[ ! -e '$TEST_ROOT/t32-slug' ]]"
) || _wake_test_failed=$((_wake_test_failed + 1))

# ── Test 33 (td-cccc42 / GH #174): named check still running is unmet ────────
# A pending check must record an attempt and keep waiting — not escalate.

(
  task="t33"; repo="app"; wt="$TEST_ROOT/t33-wt"
  _setup_waiting_worker "$task" "$repo" "$wt" "github_check" \
    "run_id=777"$'\n'"check_name=unit-tests"
  _init_worktree_repo "$wt" "https://github.com/acme/widget.git"

  fake_bin="$TEST_ROOT/t33-fakebin"
  _setup_fake_respond "$fake_bin"
  run_json="$TEST_ROOT/t33-run.json"
  cat > "$run_json" <<'JSON'
{"status":"in_progress","conclusion":null,
 "jobs":[{"name":"unit-tests","status":"in_progress","conclusion":null}]}
JSON
  _setup_fake_gh "$fake_bin" "$run_json" "$TEST_ROOT/t33-slug"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t33-respond-calls"

  exit_code=0
  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null || exit_code=$?
  _assert "pending check: exits nonzero" "[[ $exit_code -ne 0 ]]"
  _assert "pending check: sgt-respond NOT called" \
    "[[ ! -s '$TEST_ROOT/t33-respond-calls' ]]"
  _assert "pending check: still waiting (not escalated)" \
    "[[ \"\$(cat '$FLEET_DIR/$task/$repo/status' 2>/dev/null)\" == 'waiting' ]]"
  _assert "pending check: attempt recorded" \
    "[[ -f '$FLEET_DIR/$task/$repo/wake_attempts' ]]"
) || _wake_test_failed=$((_wake_test_failed + 1))

# ── Test 34 (td-cccc42): every non-success conclusion is refused ─────────────
# The criterion names failure, cancelled, skipped, and timed_out explicitly.

(
  for conclusion in cancelled timed_out neutral action_required; do
    task="t34"; repo="app"; wt="$TEST_ROOT/t34-wt"
    rm -rf "${FLEET_DIR:?}/${task:?}" "${wt:?}"
    _setup_waiting_worker "$task" "$repo" "$wt" "github_check" \
      "run_id=777"$'\n'"check_name=unit-tests"
    _init_worktree_repo "$wt" "https://github.com/acme/widget.git"

    fake_bin="$TEST_ROOT/t34-fakebin"
    _setup_fake_respond "$fake_bin"
    run_json="$TEST_ROOT/t34-run.json"
    printf '{"status":"completed","conclusion":"%s","jobs":[{"name":"unit-tests","status":"completed","conclusion":"%s"}]}\n' \
      "$conclusion" "$conclusion" > "$run_json"
    _setup_fake_gh "$fake_bin" "$run_json" "$TEST_ROOT/t34-slug"
    export FAKE_RESPOND_CALLS="$TEST_ROOT/t34-respond-calls"
    rm -f "$FAKE_RESPOND_CALLS"

    exit_code=0
    PATH="$fake_bin:$PATH" \
      "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null || exit_code=$?
    _assert "conclusion $conclusion: exits nonzero" "[[ $exit_code -ne 0 ]]"
    _assert "conclusion $conclusion: sgt-respond NOT called" \
      "[[ ! -s '$FAKE_RESPOND_CALLS' ]]"
    _assert "conclusion $conclusion: escalated to needs_input" \
      "[[ \"\$(cat '$FLEET_DIR/$task/$repo/status' 2>/dev/null)\" == 'needs_input' ]]"
  done
) || _wake_test_failed=$((_wake_test_failed + 1))

# ── Test 35 (RDY-003): permanently unsatisfiable conditions escalate ─────────
# A condition that can never be met must not be retried until the attempt budget
# or deadline expires — it must surface to a human.  A legacy condition file
# written before check_name was required is the important real-world case.

(
  # Legacy: run_id only, no check_name (valid under the previous implementation).
  task="t35a"; repo="app"; wt="$TEST_ROOT/t35a-wt"
  _setup_waiting_worker "$task" "$repo" "$wt" "github_check" "run_id=777"
  _init_worktree_repo "$wt" "https://github.com/acme/widget.git"

  fake_bin="$TEST_ROOT/t35a-fakebin"
  _setup_fake_respond "$fake_bin"
  run_json="$TEST_ROOT/t35a-run.json"
  printf '{"status":"completed","conclusion":"success","jobs":[]}\n' > "$run_json"
  _setup_fake_gh "$fake_bin" "$run_json" "$TEST_ROOT/t35a-slug"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t35a-respond-calls"

  exit_code=0
  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null || exit_code=$?
  _assert "legacy condition: exits nonzero" "[[ $exit_code -ne 0 ]]"
  _assert "legacy condition: escalated to needs_input, not left waiting" \
    "[[ \"\$(cat '$FLEET_DIR/$task/$repo/status' 2>/dev/null)\" == 'needs_input' ]]"
  _assert "legacy condition: no attempt burned" \
    "[[ ! -f '$FLEET_DIR/$task/$repo/wake_attempts' ]]"
  _assert_file_contains "legacy condition: message states the remedy" \
    "$wt/.sergeant-message" "check_name"
) || _wake_test_failed=$((_wake_test_failed + 1))

(
  # An absent named check on a completed run can never appear.
  task="t35b"; repo="app"; wt="$TEST_ROOT/t35b-wt"
  _setup_waiting_worker "$task" "$repo" "$wt" "github_check" \
    "run_id=777"$'\n'"check_name=nonexistent"
  _init_worktree_repo "$wt" "https://github.com/acme/widget.git"

  fake_bin="$TEST_ROOT/t35b-fakebin"
  _setup_fake_respond "$fake_bin"
  run_json="$TEST_ROOT/t35b-run.json"
  printf '{"status":"completed","conclusion":"success","jobs":[{"name":"other","status":"completed","conclusion":"success"}]}\n' \
    > "$run_json"
  _setup_fake_gh "$fake_bin" "$run_json" "$TEST_ROOT/t35b-slug"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t35b-respond-calls"

  exit_code=0
  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null || exit_code=$?
  _assert "absent check on completed run: exits nonzero" "[[ $exit_code -ne 0 ]]"
  _assert "absent check on completed run: escalated, not retried forever" \
    "[[ \"\$(cat '$FLEET_DIR/$task/$repo/status' 2>/dev/null)\" == 'needs_input' ]]"
) || _wake_test_failed=$((_wake_test_failed + 1))

# ── Test 36 (STD-015): only a real github.com remote binds the query ─────────
# A host that merely ends in github.com must not be rewritten into a slug and
# queried as an unrelated repository.

(
  task="t36"; repo="app"; wt="$TEST_ROOT/t36-wt"
  _setup_waiting_worker "$task" "$repo" "$wt" "github_check" \
    "run_id=777"$'\n'"check_name=unit-tests"
  _init_worktree_repo "$wt" "https://mygithub.com/acme/widget.git"

  fake_bin="$TEST_ROOT/t36-fakebin"
  _setup_fake_respond "$fake_bin"
  run_json="$TEST_ROOT/t36-run.json"
  printf '{"status":"completed","conclusion":"success","jobs":[{"name":"unit-tests","status":"completed","conclusion":"success"}]}\n' \
    > "$run_json"
  _setup_fake_gh "$fake_bin" "$run_json" "$TEST_ROOT/t36-slug"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t36-respond-calls"
  export FAKE_RESPOND_INPUT="$TEST_ROOT/t36-respond-input"

  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null || true
  # gh must still have been invoked (resolving the repo from the worktree cwd),
  # but without a forced --repo derived from the non-GitHub host.
  _assert "non-github remote: gh was still invoked" \
    "[[ -s '$TEST_ROOT/t36-slug.args' ]]"
  _assert "non-github remote: no --repo was passed" \
    "! grep -q -- '--repo' '$TEST_ROOT/t36-slug.args'"
) || _wake_test_failed=$((_wake_test_failed + 1))

# ── Test 37 (RDY-009): a malformed run response never satisfies the condition ─

(
  task="t37"; repo="app"; wt="$TEST_ROOT/t37-wt"
  _setup_waiting_worker "$task" "$repo" "$wt" "github_check" \
    "run_id=777"$'\n'"check_name=unit-tests"
  _init_worktree_repo "$wt" "https://github.com/acme/widget.git"

  fake_bin="$TEST_ROOT/t37-fakebin"
  _setup_fake_respond "$fake_bin"
  run_json="$TEST_ROOT/t37-run.json"
  printf 'not json at all\n' > "$run_json"
  _setup_fake_gh "$fake_bin" "$run_json" "$TEST_ROOT/t37-slug"
  export FAKE_RESPOND_CALLS="$TEST_ROOT/t37-respond-calls"

  exit_code=0
  PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/bin/sgt-wake" "$task" "$repo" 2>/dev/null || exit_code=$?
  _assert "malformed run JSON: exits nonzero" "[[ $exit_code -ne 0 ]]"
  _assert "malformed run JSON: sgt-respond NOT called" \
    "[[ ! -s '$TEST_ROOT/t37-respond-calls' ]]"
  _assert "malformed run JSON: still waiting (transient adapter fault)" \
    "[[ \"\$(cat '$FLEET_DIR/$task/$repo/status' 2>/dev/null)\" == 'waiting' ]]"
) || _wake_test_failed=$((_wake_test_failed + 1))

if [[ "$_wake_test_failed" -gt 0 ]]; then
  printf 'FAIL: %d sgt-wake test case(s) failed\n' "$_wake_test_failed" >&2
  exit 1
fi
printf 'sgt-wake: all tests passed\n'
