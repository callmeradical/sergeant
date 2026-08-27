#!/usr/bin/env bash
# Tests for bin/sgt-stop-all (openspec/changes/dispatch-admission-control):
# a single command that stops every live worker with no drain precondition,
# a default tier that captures a durable handoff before escalating, and a
# --force tier that skips straight to an unconditional kill.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

pass=0
fail=0
_pass() { printf '  ok: %s\n' "$*"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n' "$*" >&2; fail=$((fail + 1)); }

fleet="$TEST_ROOT/fleet"
mkdir -p "$fleet"

_lib() {
  bash -c 'source "$1"; shift; "$@"' _ "$ROOT_DIR/bin/_sgt-lib.sh" "$@"
}

_stop_all() {
  SERGEANT_FLEET="$fleet" "$ROOT_DIR/bin/sgt-stop-all" "$@"
}

_fake_proc_stat() {
  local proc_root="$1" pid="$2" starttime="$3"
  mkdir -p "$proc_root/$pid"
  printf '%s (proc) S 1 %s %s 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 %s 0\n' \
    "$pid" "$pid" "$pid" "$starttime" > "$proc_root/$pid/stat"
}

# ── Fixture: one live worker, no drain state anywhere ────────────────────────

worktree1="$TEST_ROOT/wt1"
repo1="$fleet/task-1/app"
mkdir -p "$repo1" "$worktree1"
git init -q "$worktree1"
git -C "$worktree1" config user.name Test
git -C "$worktree1" config user.email test@example.invalid
touch "$worktree1/README.md"
git -C "$worktree1" add README.md
git -C "$worktree1" commit -qm fixture
printf '%s\n' "$worktree1" > "$repo1/worktree"
printf 'in_progress\n'     > "$repo1/status"
printf 'in_progress\n'     > "$worktree1/.sergeant-status"
printf 'td-abc\n'          > "$repo1/td_task"

sleep 100 & pid1=$!
printf '%s\n' "$pid1" > "$repo1/worker_pid"
proc_root="$TEST_ROOT/proc"
_fake_proc_stat "$proc_root" "$pid1" 40000
printf 'linux:40000\n' > "$repo1/worker_process_start"
printf '%%1\n' > "$repo1/pane"
printf '0|%%1|100|10|cmd\n' > "$repo1/pane_identity"
chmod 600 "$repo1/pane_identity"

fake_bin="$TEST_ROOT/fake-bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/tmux" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "display-message" ]]; then
  for a in "$@"; do [[ "$a" == "%1" ]] && { printf '0|%%1|100|10|cmd\n'; exit 0; }; done
  exit 1
fi
exit 1
EOF
chmod +x "$fake_bin/tmux"
cat > "$fake_bin/td" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TEST_ROOT/td-calls.log"
case "\$1" in
  show|comment) printf '{}\n' ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$fake_bin/td"

# ── 1. Works with no drain active anywhere ──────────────────────────────────

dry_out="$(SGT_PROC_ROOT="$proc_root" PATH="$fake_bin:$PATH" _stop_all --dry-run 2>&1)"
if [[ "$dry_out" == *"task-1"* && "$dry_out" == *"app"* ]]; then
  _pass "sgt-stop-all: lists the live worker with no drain active, no drain precondition required"
else
  _fail "sgt-stop-all: expected task-1/app listed in dry-run; got: $dry_out"
fi
if [[ "$(cat "$worktree1/.sergeant-status")" == "in_progress" ]]; then
  _pass "sgt-stop-all --dry-run: does not modify status"
else
  _fail "sgt-stop-all --dry-run: should not have modified status"
fi

# ── 2. Requires --yes or --dry-run ───────────────────────────────────────────

set +e
out_noconfirm="$(SGT_PROC_ROOT="$proc_root" PATH="$fake_bin:$PATH" _stop_all 2>&1)"
status_noconfirm=$?
set -e
if [[ "$status_noconfirm" -ne 0 && "$out_noconfirm" == *"--yes"* ]]; then
  _pass "sgt-stop-all: refuses to act without --yes or --dry-run"
else
  _fail "sgt-stop-all: should require confirmation; status=$status_noconfirm out=$out_noconfirm"
fi

# ── 3. Default tier: durable-handoff capture attempt, then TERM, then stop ──

SGT_PROC_ROOT="$proc_root" PATH="$fake_bin:$PATH" SERGEANT_STOP_ALL_GRACE_DECISECONDS=20 \
  _stop_all --yes >/dev/null 2>&1 || true
sleep 0.2

if grep -q "td-abc" "$TEST_ROOT/td-calls.log" 2>/dev/null; then
  _pass "sgt-stop-all (default tier): attempts a durable-handoff capture (reaches td) before signaling"
else
  _fail "sgt-stop-all (default tier): expected a td handoff call for td-abc; log: $(cat "$TEST_ROOT/td-calls.log" 2>/dev/null)"
fi
if ! kill -0 "$pid1" 2>/dev/null; then
  _pass "sgt-stop-all (default tier): the live worker process is stopped"
else
  _fail "sgt-stop-all (default tier): worker process still alive"
  kill "$pid1" 2>/dev/null || true
fi
status1="$(cat "$worktree1/.sergeant-status" 2>/dev/null || echo "")"
if [[ "$status1" == "force-stopped" ]]; then
  _pass "sgt-stop-all (default tier): publishes a terminal force-stopped status"
else
  _fail "sgt-stop-all (default tier): expected force-stopped status, got '$status1'"
fi

# ── 4. --force skips the handoff attempt and the grace period entirely ─────

worktree2="$TEST_ROOT/wt2"
repo2="$fleet/task-2/svc"
mkdir -p "$repo2" "$worktree2"
git init -q "$worktree2"
git -C "$worktree2" config user.name Test
git -C "$worktree2" config user.email test@example.invalid
touch "$worktree2/README.md"
git -C "$worktree2" add README.md
git -C "$worktree2" commit -qm fixture
printf '%s\n' "$worktree2" > "$repo2/worktree"
printf 'in_progress\n'     > "$repo2/status"
printf 'in_progress\n'     > "$worktree2/.sergeant-status"
printf 'td-force-test\n'   > "$repo2/td_task"

cat > "$TEST_ROOT/ignore-term.sh" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
while true; do sleep 1; done
EOF
chmod +x "$TEST_ROOT/ignore-term.sh"
"$TEST_ROOT/ignore-term.sh" & pid2=$!
sleep 0.2
printf '%s\n' "$pid2" > "$repo2/worker_pid"
_fake_proc_stat "$proc_root" "$pid2" 50000
printf 'linux:50000\n' > "$repo2/worker_process_start"
printf '%%2\n' > "$repo2/pane"
printf '0|%%2|200|20|cmd\n' > "$repo2/pane_identity"
chmod 600 "$repo2/pane_identity"
cat > "$fake_bin/tmux" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "display-message" ]]; then
  for a in "$@"; do [[ "$a" == "%2" ]] && { printf '0|%%2|200|20|cmd\n'; exit 0; }; done
  exit 1
fi
exit 1
EOF
chmod +x "$fake_bin/tmux"

: > "$TEST_ROOT/td-calls.log"
start_ts=$(date +%s)
SGT_PROC_ROOT="$proc_root" PATH="$fake_bin:$PATH" _stop_all --force --yes >/dev/null 2>&1 || true
end_ts=$(date +%s)
elapsed=$((end_ts - start_ts))

if ! grep -q "td-force-test" "$TEST_ROOT/td-calls.log" 2>/dev/null; then
  _pass "sgt-stop-all --force: skips the durable-handoff attempt entirely"
else
  _fail "sgt-stop-all --force: should not have attempted a handoff; log: $(cat "$TEST_ROOT/td-calls.log")"
fi
if ! kill -0 "$pid2" 2>/dev/null; then
  _pass "sgt-stop-all --force: kills a TERM-ignoring worker immediately (no grace-period wait)"
else
  _fail "sgt-stop-all --force: worker (which ignores SIGTERM) survived --force"
  kill -9 "$pid2" 2>/dev/null || true
fi
if [[ "$elapsed" -le 2 ]]; then
  _pass "sgt-stop-all --force: completes fast, without waiting out a grace period ($elapsed s)"
else
  _fail "sgt-stop-all --force: took ${elapsed}s, suggesting it waited on a grace period"
fi
status2="$(cat "$worktree2/.sergeant-status" 2>/dev/null || echo "")"
if [[ "$status2" == "force-stopped" ]]; then
  _pass "sgt-stop-all --force: publishes a terminal force-stopped status"
else
  _fail "sgt-stop-all --force: expected force-stopped status, got '$status2'"
fi

# ── 5. No recorded pid: never claim "stopped" without proof ─────────────────
# A verified-live pane with no worker_pid file recorded at all must not be
# reported as stopped; there is no way to confirm the process is gone.

worktree5="$TEST_ROOT/wt5"
repo5="$fleet/task-5/nopid"
mkdir -p "$repo5" "$worktree5"
printf '%s\n' "$worktree5" > "$repo5/worktree"
printf 'in_progress\n'     > "$repo5/status"
printf 'in_progress\n'     > "$worktree5/.sergeant-status"
printf '%%5\n' > "$repo5/pane"
printf '0|%%5|500|50|cmd\n' > "$repo5/pane_identity"
chmod 600 "$repo5/pane_identity"
cat > "$fake_bin/tmux" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "display-message" ]]; then
  for a in "$@"; do [[ "$a" == "%5" ]] && { printf '0|%%5|500|50|cmd\n'; exit 0; }; done
  exit 1
fi
exit 1
EOF
chmod +x "$fake_bin/tmux"

set +e
SGT_PROC_ROOT="$proc_root" PATH="$fake_bin:$PATH" _stop_all --yes >/tmp/stop-all-nopid.out 2>&1
status_nopid=$?
set -e
if [[ "$status_nopid" -ne 0 ]]; then
  _pass "sgt-stop-all: a live worker with no recorded pid makes the run report failure, not success"
else
  _fail "sgt-stop-all: expected nonzero exit for a worker with no recorded pid"
fi
status5="$(cat "$worktree5/.sergeant-status" 2>/dev/null || echo "")"
if [[ "$status5" == "in_progress" ]]; then
  _pass "sgt-stop-all: a worker with no recorded pid is never marked force-stopped"
else
  _fail "sgt-stop-all: expected status to remain in_progress for the no-pid worker, got '$status5'"
fi

# ── 6. Recorded pid whose identity cannot be proven (recycled-pid simulation) ─
# worker_process_start does not match the live process's actual start time --
# never claim "stopped" here either; the process may be an unrelated one.

worktree6="$TEST_ROOT/wt6"
repo6="$fleet/task-6/mismatch"
mkdir -p "$repo6" "$worktree6"
printf '%s\n' "$worktree6" > "$repo6/worktree"
printf 'in_progress\n'     > "$repo6/status"
printf 'in_progress\n'     > "$worktree6/.sergeant-status"
sleep 100 & pid6=$!
printf '%s\n' "$pid6" > "$repo6/worker_pid"
_fake_proc_stat "$proc_root" "$pid6" 60000
printf 'linux:99999\n' > "$repo6/worker_process_start"
printf '%%6\n' > "$repo6/pane"
printf '0|%%6|600|60|cmd\n' > "$repo6/pane_identity"
chmod 600 "$repo6/pane_identity"
cat > "$fake_bin/tmux" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "display-message" ]]; then
  for a in "$@"; do [[ "$a" == "%6" ]] && { printf '0|%%6|600|60|cmd\n'; exit 0; }; done
  exit 1
fi
exit 1
EOF
chmod +x "$fake_bin/tmux"

set +e
SGT_PROC_ROOT="$proc_root" PATH="$fake_bin:$PATH" _stop_all --yes >/tmp/stop-all-mismatch.out 2>&1
status_mismatch=$?
set -e
if [[ "$status_mismatch" -ne 0 ]]; then
  _pass "sgt-stop-all: an unprovable pid identity (recorded/actual start mismatch) makes the run report failure"
else
  _fail "sgt-stop-all: expected nonzero exit for a worker with mismatched process identity"
fi
if kill -0 "$pid6" 2>/dev/null; then
  _pass "sgt-stop-all: never signals a pid whose identity it could not prove"
else
  _fail "sgt-stop-all: signaled a pid despite an identity mismatch"
fi
status6="$(cat "$worktree6/.sergeant-status" 2>/dev/null || echo "")"
if [[ "$status6" == "in_progress" ]]; then
  _pass "sgt-stop-all: a worker with an unprovable identity is never marked force-stopped"
else
  _fail "sgt-stop-all: expected status to remain in_progress for the mismatched worker, got '$status6'"
fi
kill "$pid6" 2>/dev/null || true
wait "$pid6" 2>/dev/null || true

printf '\nsgt-stop-all: %d passed' "$pass"
if [[ "$fail" -gt 0 ]]; then
  printf ', %d FAILED\n' "$fail" >&2
  exit 1
fi
printf '\n'
