#!/usr/bin/env bash
# sgt-drain-worker-test.sh — Behavioral tests for cooperative drain in
# sgt-interactive-worker.
#
# Tests the drain detection and drained-exit state produced by the worker's
# cooperative drain logic. Uses a minimal simulation of the worker's drain
# functions (_drain_is_active, _do_drain) to cover the observable state
# without requiring a real interactive terminal.
#
# Coverage:
#   1.  global drain detected: status=drained, .sergeant-drained written
#   2.  project drain match: status=drained
#   3.  project drain no match: no drain
#   4.  no drain signal: no drain
#   5.  worktree files preserved after drain
#   6.  td handoff called on drain
#   7.  drain is idempotent (already-drained file present → no re-drain)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# ── Drain state isolation (MUST precede any drain helper call) ────────────────
#
# _sgt_drain_state_dir resolves SERGEANT_DRAIN_DIR, else SERGEANT_CONFIG/drain,
# else $HOME/.config/sergeant/drain.  Without an override this suite wrote FOUR
# real global drains into the live shared drain directory, and every interactive
# worker of every coordinator that polled during one of those windows
# cooperatively drained and died mid-mission.  Both variables are exported so
# that any subprocess resolves the same temporary root regardless of which one
# it consults.
export SERGEANT_DRAIN_DIR="$TEST_ROOT/drain"
export SERGEANT_CONFIG="$TEST_ROOT/config"
mkdir -p "$SERGEANT_DRAIN_DIR" "$SERGEANT_CONFIG"

# ── Shared helpers ────────────────────────────────────────────────────────────

# Source the drain library directly for drain-state manipulation
# shellcheck disable=SC1091
source "$ROOT_DIR/bin/_sgt-drain.sh"

# Fail closed: prove the isolation actually took effect before writing anything.
_resolved_drain_dir="$(_sgt_drain_state_dir)"
case "$_resolved_drain_dir" in
  "$TEST_ROOT"/*) : ;;
  *)
    printf 'FAIL: drain state dir resolved outside the test root: %s\n' \
      "$_resolved_drain_dir" >&2
    exit 1
    ;;
esac

# mk_env below builds real git worktrees because sgt-td-memory refuses to attach
# handoff evidence to a path that is not one (GH #173), so skip early where git is
# unavailable, matching the other git-dependent drain tests.
command -v git >/dev/null 2>&1 || {
  printf 'sgt-drain-worker: skipped (git unavailable)\n'
  exit 0
}

fake_td="$TEST_ROOT/fake-bin/td"
mkdir -p "$TEST_ROOT/fake-bin"
cat > "$fake_td" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TD_LOG"
EOF
chmod +x "$fake_td"

mk_env() {
  local name="$1" project="${2:-testproject}"
  local root="$TEST_ROOT/$name"
  local worktree="$root/worktree"
  local state="$root/state"
  local task_dir="$root/task"
  mkdir -p "$worktree" "$state" "$task_dir"
  # A real git worktree: sgt-td-memory verifies the worktree it is handed and
  # refuses to attach handoff evidence to an unverified path (GH #173).
  git -C "$worktree" init -q -b main .
  git -C "$worktree" config user.name Test
  git -C "$worktree" config user.email test@example.invalid
  printf 'fixture\n' > "$worktree/fixture.txt"
  git -C "$worktree" add fixture.txt
  git -C "$worktree" commit -qm 'drain fixture'
  printf 'Project: %s\nBrief: test\n' "$project" > "$task_dir/brief.md"
  printf 'td-drain-test\n' > "$state/td_task"
  # sgt-td-memory binds to the worktree the fleet record owns (GH #173).
  printf '%s\n' "$worktree" > "$state/worktree"
  # Symlink state inside task dir so dirname(state) = task_dir
  ln -sfn "$state" "$task_dir/sergeant"
  printf '%s\n' "$root"
}

# Minimal simulation of the worker's drain logic:
# runs _do_drain equivalent in a subprocess, capturing state
run_worker_drain() {
  local worktree="$1" state="$2" project="$3"
  local task_dir; task_dir="$(dirname "$state")"
  (
    # Simulate sgt-interactive-worker's drain functions
    SCRIPT_DIR="$ROOT_DIR/bin"
    REPO_STATE="$state"
    WORKTREE="$worktree"
    _PROJECT_NAME="$project"
    # shellcheck source=bin/_sgt-drain.sh
    # shellcheck disable=SC1091
    source "$ROOT_DIR/bin/_sgt-drain.sh"
    source "$ROOT_DIR/bin/_sgt-lib.sh"

    _drain_is_active() {
      _sgt_drain_is_drained "$(_sgt_drain_global_file)" && return 0
      [[ -n "$_PROJECT_NAME" ]] && \
        _sgt_drain_is_drained "$(_sgt_drain_project_file "$_PROJECT_NAME")" && return 0
      return 1
    }

    if ! _drain_is_active; then
      exit 100  # drain not active
    fi

    PATH="$TEST_ROOT/fake-bin:$PATH"
    "$SCRIPT_DIR/sgt-td-memory" handoff "$REPO_STATE" "$WORKTREE" || true
    printf 'drained\n' > "$WORKTREE/.sergeant-drained"
    printf 'drained\n' > "$WORKTREE/.sergeant-status"
    printf 'drained\n' > "$REPO_STATE/status"
    rm -f "$REPO_STATE/result"
    exit 0
  )
}

# ── TEST 1: global drain detected ────────────────────────────────────────────

env1="$(mk_env drain-global-detected testproject)"
worktree1="$env1/worktree"
state1="$env1/task/sergeant"

_sgt_drain_write "$(_sgt_drain_global_file)" "test" "test-actor"

TD_LOG="$env1/td.log" run_worker_drain "$worktree1" "$state1" "testproject"
rc=$?
[[ "$rc" -eq 0 ]] || { printf 'FAIL test1: expected exit 0, got %d\n' "$rc" >&2; exit 1; }
[[ "$(cat "$worktree1/.sergeant-status")" == "drained" ]] || { printf 'FAIL test1: status not drained\n' >&2; exit 1; }
[[ -f "$worktree1/.sergeant-drained" ]] || { printf 'FAIL test1: .sergeant-drained missing\n' >&2; exit 1; }
[[ "$(cat "$state1/status")" == "drained" ]] || { printf 'FAIL test1: fleet status not drained\n' >&2; exit 1; }
grep -Fq 'handoff td-drain-test' "$env1/td.log" || { printf 'FAIL test1: td handoff not called\n' >&2; exit 1; }

"$ROOT_DIR/bin/sgt-undrain" --global
printf 'test1 global drain detected: ok\n'

# ── TEST 2: project drain match ───────────────────────────────────────────────

env2="$(mk_env drain-project-match testproject)"
worktree2="$env2/worktree"
state2="$env2/task/sergeant"

_sgt_drain_write "$(_sgt_drain_project_file "testproject")" "test" "test-actor"

TD_LOG="$env2/td.log" run_worker_drain "$worktree2" "$state2" "testproject"
rc=$?
[[ "$rc" -eq 0 ]] || { printf 'FAIL test2: expected exit 0, got %d\n' "$rc" >&2; exit 1; }
[[ "$(cat "$worktree2/.sergeant-status")" == "drained" ]] || { printf 'FAIL test2: status not drained\n' >&2; exit 1; }

"$ROOT_DIR/bin/sgt-undrain" testproject
printf 'test2 project drain match: ok\n'

# ── TEST 3: project drain no match ────────────────────────────────────────────

env3="$(mk_env drain-project-nomatch testproject)"
worktree3="$env3/worktree"
state3="$env3/task/sergeant"

_sgt_drain_write "$(_sgt_drain_project_file "otherproject")" "test" "test-actor"

set +e; run_worker_drain "$worktree3" "$state3" "testproject"; rc=$?; set -e
[[ "$rc" -eq 100 ]] || { printf 'FAIL test3: expected rc 100 (no drain), got %d\n' "$rc" >&2; exit 1; }
[[ ! -f "$worktree3/.sergeant-drained" ]] || { printf 'FAIL test3: unexpected .sergeant-drained\n' >&2; exit 1; }

"$ROOT_DIR/bin/sgt-undrain" otherproject
printf 'test3 project drain no match: ok\n'

# ── TEST 4: no drain signal ───────────────────────────────────────────────────

env4="$(mk_env drain-no-signal testproject)"
worktree4="$env4/worktree"
state4="$env4/task/sergeant"

set +e; run_worker_drain "$worktree4" "$state4" "testproject"; rc=$?; set -e
[[ "$rc" -eq 100 ]] || { printf 'FAIL test4: expected rc 100 (no drain), got %d\n' "$rc" >&2; exit 1; }
[[ ! -f "$worktree4/.sergeant-drained" ]] || { printf 'FAIL test4: unexpected .sergeant-drained\n' >&2; exit 1; }

printf 'test4 no drain signal: ok\n'

# ── TEST 5: worktree files preserved after drain ──────────────────────────────

env5="$(mk_env drain-preserves-files testproject)"
worktree5="$env5/worktree"
state5="$env5/task/sergeant"

printf 'work in progress\n' > "$worktree5/my-feature.go"
printf 'some change\n' > "$worktree5/modified-file.txt"

_sgt_drain_write "$(_sgt_drain_global_file)" "test" "test-actor"
TD_LOG="$env5/td.log" run_worker_drain "$worktree5" "$state5" "testproject"

[[ "$(cat "$worktree5/my-feature.go")" == "work in progress" ]] || { printf 'FAIL test5: my-feature.go changed\n' >&2; exit 1; }
[[ "$(cat "$worktree5/modified-file.txt")" == "some change" ]] || { printf 'FAIL test5: modified-file.txt changed\n' >&2; exit 1; }

"$ROOT_DIR/bin/sgt-undrain" --global
printf 'test5 worktree files preserved: ok\n'

# ── TEST 6: td handoff called ─────────────────────────────────────────────────

env6="$(mk_env drain-td-handoff testproject)"
worktree6="$env6/worktree"
state6="$env6/task/sergeant"

_sgt_drain_write "$(_sgt_drain_global_file)" "test" "test-actor"
TD_LOG="$env6/td.log" run_worker_drain "$worktree6" "$state6" "testproject"
grep -Fq 'handoff td-drain-test' "$env6/td.log" || { printf 'FAIL test6: td handoff not called\n' >&2; exit 1; }

"$ROOT_DIR/bin/sgt-undrain" --global
printf 'test6 td handoff called on drain: ok\n'

# ── TEST 7: drain idempotent (already drained) ────────────────────────────────

env7="$(mk_env drain-idempotent testproject)"
worktree7="$env7/worktree"
# state7 is unused; drain detection test operates directly on worktree7

# Pre-mark as drained
printf 'drained\n' > "$worktree7/.sergeant-drained"
printf 'drained\n' > "$worktree7/.sergeant-status"

_sgt_drain_write "$(_sgt_drain_global_file)" "test" "test-actor"

# The _watch_drain loop checks for .sergeant-drained existence before draining
# so we test the idempotency check in run_worker_drain via the check:
# "[[ ! -f "$WORKTREE/.sergeant-drained" ]] && _drain_is_active"
(
  source "$ROOT_DIR/bin/_sgt-drain.sh"
  _PROJECT_NAME="testproject"
  _drain_is_active() {
    _sgt_drain_is_drained "$(_sgt_drain_global_file)" && return 0
    [[ -n "$_PROJECT_NAME" ]] && \
      _sgt_drain_is_drained "$(_sgt_drain_project_file "$_PROJECT_NAME")" && return 0
    return 1
  }
  # Simulate _watch_drain's guard: only drain if not already drained
  if [[ ! -f "$worktree7/.sergeant-drained" ]] && _drain_is_active; then
    printf 'FAIL test7: should not re-drain\n' >&2
    exit 1
  fi
  exit 0
)
[[ "$(cat "$worktree7/.sergeant-status")" == "drained" ]] || { printf 'FAIL test7: status changed\n' >&2; exit 1; }

"$ROOT_DIR/bin/sgt-undrain" --global
printf 'test7 drain idempotent (already drained): ok\n'

printf '\nsgt-drain-worker: all tests passed\n'
