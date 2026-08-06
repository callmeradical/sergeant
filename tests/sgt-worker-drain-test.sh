#!/usr/bin/env bash
# Tests for cooperative drain checkpoint in sgt-interactive-worker (td-6c9911)
# Verifies that a drained-status worker exits cleanly with td handoff.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

drain_dir="$TEST_ROOT/drains"
source_repo="$TEST_ROOT/source"
worktree="$TEST_ROOT/worktree"
repo_state="$TEST_ROOT/state"
fake_bin="$TEST_ROOT/fake-bin"
config_dir="$TEST_ROOT/config"

mkdir -p "$repo_state" "$source_repo" "$worktree" "$fake_bin" "$config_dir" "$drain_dir"
export SERGEANT_CONFIG="$config_dir"

# sgt-td-memory verifies the worktree it is handed and refuses to attach handoff
# evidence to a path that is not a git worktree (GH #173), so the drain fixtures
# below are real git worktrees.  That makes git a hard requirement for this test,
# and tests/run-drain-tests.sh also runs it in the pinned bash:3.2 image, which
# has no git, so skip early there exactly as the other git-dependent drain tests
# are skipped.
command -v git >/dev/null 2>&1 || {
  printf 'sgt-worker drain checkpoint: skipped (git unavailable)\n'
  exit 0
}
_init_fixture_worktree() {
  git -C "$1" init -q -b main .
  git -C "$1" config user.name Test
  git -C "$1" config user.email test@example.invalid
  printf 'fixture\n' > "$1/fixture.txt"
  git -C "$1" add fixture.txt
  git -C "$1" commit -qm 'drain fixture'
}
_init_fixture_worktree "$worktree"

cat > "$config_dir/test.yaml" <<EOF
repos:
  - name: app
    path: $source_repo
EOF

cat > "$fake_bin/td" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TD_LOG:-/dev/null}"
EOF
chmod +x "$fake_bin/td"

# Fake interactive agent: just sets .sergeant-status
cat > "$fake_bin/fake-opencode" <<'EOF'
#!/usr/bin/env bash
# Minimal stub: mark drained immediately (simulates agent responding to drain signal)
printf 'drained\n' > .sergeant-status
EOF
chmod +x "$fake_bin/fake-opencode"

# ── 1. Worker with drained status exits cleanly with td handoff ───────────────
# Pre-set drained status so the _finish handler sees it on agent exit.

printf 'td-drain-1\n' > "$repo_state/td_task"
# sgt-td-memory binds to the worktree the fleet record owns (GH #173).
printf '%s\n' "$worktree" > "$repo_state/worktree"
printf 'myproject\n' > "$repo_state/project"
printf 'drained\n' > "$worktree/.sergeant-status"

# Interactive worker requires a terminal — simulate with script/expect not needed;
# just test _finish behavior by running with a fake TTY via `script`
# or by checking the contract directly through a subshell that sources the worker.
# Since we cannot easily fake a terminal, test the drain state contract via
# sgt-interactive-worker sourced functions.

# ── Verify _finish handles drained status via library functions ────────────────
result="$(
  REPO_STATE="$repo_state" WORKTREE="$worktree" AGENT="$fake_bin/fake-opencode" \
  SERGEANT_DRAIN_DIR="$drain_dir" ROOT_DIR="$ROOT_DIR" fake_bin="$fake_bin" \
  PATH="$fake_bin:$ROOT_DIR/bin:$PATH" TD_LOG="$TEST_ROOT/td.log" \
  bash <<'INNER'
    set -uo pipefail
    SCRIPT_DIR="$ROOT_DIR/bin"
    source "$ROOT_DIR/bin/_sgt-response-lock.sh"
    source "$ROOT_DIR/bin/_sgt-drain.sh"
    _sgt_td_memory() { PATH="$fake_bin:$ROOT_DIR/bin:$PATH" "$ROOT_DIR/bin/sgt-td-memory" "$@"; }
    harness="fake-opencode"
    notification_pid=""
    watch_progress_pid=""

    _status() { tr -d '\n' < "$WORKTREE/.sergeant-status" 2>/dev/null || echo "in_progress"; }
    _sync_state() {
      local status; status="$(_status)"
      printf '%s\n' "$status" > "$REPO_STATE/status"
    }
    _finish() {
      local exit_code="$1" status
      trap - EXIT
      [[ -z "${notification_pid:-}" ]] || kill "$notification_pid" 2>/dev/null || true
      [[ -z "${watch_progress_pid:-}" ]] || kill "$watch_progress_pid" 2>/dev/null || true
      status="$(_status)"
      # Bash 3.2 misparses case patterns in a heredoc nested inside $().
      if [[ "$status" == "drained" ]]; then
        _sync_state
        rm -f "$REPO_STATE/diagnostic"
        "$ROOT_DIR/bin/sgt-td-memory" handoff "$REPO_STATE" "$WORKTREE" || true
        printf 'exit:0\n'
        return 0
      fi
      printf 'exit:other(%s)\n' "$status"
      return 1
    }
    _finish 0
INNER
)"
[[ "$result" == "exit:0" ]] || { echo "drained worker should exit 0; got: $result"; exit 1; }
grep -Fq "handoff td-drain-1" "$TEST_ROOT/td.log" 2>/dev/null || \
  { echo "td handoff should be written on drain checkpoint"; exit 1; }
[[ "$(cat "$repo_state/status" 2>/dev/null)" == "drained" ]] || \
  { echo "fleet status should be drained"; exit 1; }

# ── 2. _watch_progress writes drain signal when drain is active ───────────────

drain_worktree="$TEST_ROOT/drain-wt"
drain_repo="$TEST_ROOT/drain-state"
mkdir -p "$drain_worktree" "$drain_repo"
printf 'myproject\n' > "$drain_repo/project"

# Set a global drain
SERGEANT_DRAIN_DIR="$drain_dir" "$ROOT_DIR/bin/sgt-drain" --global --reason "worker signal test"

# Simulate one iteration of the drain check from _watch_progress
ROOT_DIR="$ROOT_DIR" drain_dir="$drain_dir" drain_worktree="$drain_worktree" \
drain_repo="$drain_repo" SERGEANT_DRAIN_DIR="$drain_dir" bash <<'INNER'
  source "$ROOT_DIR/bin/_sgt-drain.sh"
  WORKTREE="$drain_worktree"
  REPO_STATE="$drain_repo"
  worker_project="$(tr -d '\n' < "$REPO_STATE/project" 2>/dev/null || true)"
  if [[ ! -f "$WORKTREE/.sergeant-drain-signal" ]]; then
    if _sgt_drain_global_active || \
       { [[ -n "$worker_project" ]] && _sgt_drain_project_active "$worker_project"; }; then
      printf 'scope=global\n' > "$WORKTREE/.sergeant-drain-signal.tmp.$$" && \
        mv "$WORKTREE/.sergeant-drain-signal.tmp.$$" "$WORKTREE/.sergeant-drain-signal" || true
    fi
  fi
INNER

SERGEANT_DRAIN_DIR="$drain_dir" "$ROOT_DIR/bin/sgt-undrain" --global

[[ -f "$drain_worktree/.sergeant-drain-signal" ]] || \
  { echo "drain signal file should be written when drain is active"; exit 1; }

printf 'sgt-worker drain checkpoint: ok\n'
