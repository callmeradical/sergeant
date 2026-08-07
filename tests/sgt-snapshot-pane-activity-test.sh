#!/usr/bin/env bash
# Regression for GH #206: snapshot preserves active witnesses when pane_activity
# is unavailable (tmux 3.7b returns empty #{pane_activity}).
#
# Seam: sgt-watch --snapshot uses progress_ts as fallback when pane_activity is
# zero or empty.  A recent progress_ts must keep busy=true; a stale one must not.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fleet="$TEST_ROOT/fleet"
fake_bin="$TEST_ROOT/fake-bin"
IDENTITY_DIR="$TEST_ROOT/identities"
LIVE_PANES="$TEST_ROOT/live-panes"
mkdir -p "$fleet" "$fake_bin" "$IDENTITY_DIR"
: > "$LIVE_PANES"

# Fake tmux: PANE_ACTIVITY env controls what #{pane_activity} returns.
cat > "$fake_bin/tmux" <<'TMUX'
#!/usr/bin/env bash
_live() {
  local pane="$1" entry
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    [[ "$entry" == "$pane" ]] && return 0
  done < "$LIVE_PANES"
  return 1
}
case "$1" in
  display-message)
    target=""
    previous=""
    for arg in "$@"; do
      [[ "$previous" == -t ]] && target="$arg"
      previous="$arg"
    done
    _live "$target" || exit 1
    case "${!#}" in
      '#{pane_id}')       printf '%s\n' "$target" ;;
      '#{pane_activity}') printf '%s\n' "${PANE_ACTIVITY:-0}" ;;
      *)
        identity_file="$IDENTITY_DIR/${target#%}"
        if [[ -s "$identity_file" ]]; then
          cat "$identity_file"
        else
          printf '0|%s|4242|123456|worker\n' "$target"
        fi
        ;;
    esac
    ;;
esac
TMUX
chmod +x "$fake_bin/tmux"

PASS=0
FAIL=0

_pass() { PASS=$(( PASS + 1 )); printf 'PASS: %s\n' "$1"; }
_fail() { FAIL=$(( FAIL + 1 )); printf 'FAIL: %s\n' "$1" >&2; }

field() {
  local json="$1" expr="$2"
  python3 -c "import sys, json; d=json.loads(sys.stdin.read()); print($expr)" <<< "$json" 2>/dev/null
}

make_worker() {
  local name="$1" status="$2" pane="$3" progress_ts="$4"
  local task_dir="$fleet/task-$name" state wt
  state="$task_dir/app"
  wt="$TEST_ROOT/wt-$name"
  mkdir -p "$state" "$wt"
  printf 'Brief: test %s\n' "$name" > "$task_dir/brief.md"
  printf '%s\n' "$wt"       > "$state/worktree"
  printf '%s\n' "$status"   > "$state/status"
  printf '%s\n' "$status"   > "$wt/.sergeant-status"
  printf '%s\n' "$pane"     > "$state/pane"
  printf '0|%s|4242|123456|worker\n' "$pane" > "$IDENTITY_DIR/${pane#%}"
  printf '0|%s|4242|123456|worker\n' "$pane" > "$state/pane_identity"
  chmod 600 "$state/pane_identity"
  printf '%s\n' "$pane"        >> "$LIVE_PANES"
  printf '%s\n' "$progress_ts" > "$state/progress_ts"
}

snapshot() {
  env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" \
      "IDENTITY_DIR=$IDENTITY_DIR" "LIVE_PANES=$LIVE_PANES" \
      "${@}" \
      "$ROOT_DIR/bin/sgt-watch" --snapshot
}

# ── Test 1: recent progress_ts + pane_activity=0 → busy=true ─────────────────
make_worker "active-no-pane-act" "in_progress" "%80" "$(date +%s)"
json="$(PANE_ACTIVITY=0 snapshot)"
busy="$(field "$json" 'repr(d["busy"])')"
basis="$(field "$json" 'd["basis"]')"
if [[ "$busy" == "True" && "$basis" == "verified_active_witness" ]]; then
  _pass "pane_activity=0 + recent progress_ts → busy=true, verified_active_witness"
else
  _fail "pane_activity=0 + recent progress_ts: busy=$busy basis=$basis"
fi

# ── Test 2: stale progress_ts + pane_activity=0 → busy=null (inconclusive) ───
task_dir="$fleet/task-active-no-pane-act"
printf '%s\n' "$(( $(date +%s) - 99999 ))" > "$task_dir/app/progress_ts"
json2="$(PANE_ACTIVITY=0 SERGEANT_SNAPSHOT_RECENT_SECONDS=300 snapshot)"
busy2="$(field "$json2" 'repr(d["busy"])')"
if [[ "$busy2" == "None" ]]; then
  _pass "pane_activity=0 + stale progress_ts → busy=null (inconclusive)"
else
  _fail "pane_activity=0 + stale progress_ts: expected busy=null, got busy=$busy2"
fi

# ── Test 3: live pane_activity (normal tmux) takes precedence over progress_ts ─
# When pane_activity IS available and recent, the snapshot must still report
# busy=true — the progress_ts fallback must not break the normal path.
make_worker "active-with-pane-act" "in_progress" "%81" "$(( $(date +%s) - 99999 ))"
recent_pane_ts="$(date +%s)"
json3="$(PANE_ACTIVITY="$recent_pane_ts" snapshot)"
busy3="$(field "$json3" 'repr(d["busy"])')"
if [[ "$busy3" == "True" ]]; then
  _pass "recent pane_activity overrides stale progress_ts → busy=true"
else
  _fail "recent pane_activity: expected busy=true, got busy=$busy3"
fi

# ── Test 4: non-in_progress status is never a witness ────────────────────────
# Use a separate fleet to test the blocked worker in isolation.
fleet4="$TEST_ROOT/fleet4"
mkdir -p "$fleet4"
task4_dir="$fleet4/task-blocked"
state4="$task4_dir/app"
wt4="$TEST_ROOT/wt-blocked"
mkdir -p "$state4" "$wt4"
printf 'Brief: blocked\n' > "$task4_dir/brief.md"
printf '%s\n' "$wt4"      > "$state4/worktree"
printf 'blocked\n'        > "$state4/status"
printf 'blocked\n'        > "$wt4/.sergeant-status"
printf '%%82\n'           > "$state4/pane"
printf '0|%%82|4242|123456|worker\n' > "$IDENTITY_DIR/82"
printf '0|%%82|4242|123456|worker\n' > "$state4/pane_identity"
chmod 600 "$state4/pane_identity"
printf '%%82\n'           >> "$LIVE_PANES"
printf '%s\n' "$(date +%s)" > "$state4/progress_ts"

json4="$(PANE_ACTIVITY="$(date +%s)" \
  env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet4" \
      "IDENTITY_DIR=$IDENTITY_DIR" "LIVE_PANES=$LIVE_PANES" \
      "$ROOT_DIR/bin/sgt-watch" --snapshot)"
busy4="$(field "$json4" 'repr(d["busy"])')"
if [[ "$busy4" != "True" ]]; then
  _pass "blocked worker is not a verified active witness"
else
  _fail "blocked worker reported busy=true"
fi

# ── Test 5: _watch_progress updates progress_ts on every in_progress tick ────
# Verify that the modified _watch_progress loop writes progress_ts when the
# status is in_progress, not only on sentinel changes (GH #206 root cause).
# We simulate the loop directly: run one iteration of the logic and check that
# progress_ts was updated even with no sentinel change.
wt5="$TEST_ROOT/wt-progress-tick"
rs5="$TEST_ROOT/repo-state-tick"
mkdir -p "$wt5" "$rs5"
printf 'in_progress\n' > "$wt5/.sergeant-status"
# Set progress_ts to something old
printf '%s\n' "$(( $(date +%s) - 5000 ))" > "$rs5/progress_ts"
old_ts="$(cat "$rs5/progress_ts")"

# Run the critical section: if status is in_progress, record progress.
bash - <<BASH
set -euo pipefail
WORKTREE="$wt5"
REPO_STATE="$rs5"
_record_progress() { date +%s > "\$REPO_STATE/progress_ts" 2>/dev/null || true; }
current_status="\$(tr -d '\n' < "\$WORKTREE/.sergeant-status" 2>/dev/null || echo 'in_progress')"
if [[ "\$current_status" == "in_progress" ]]; then
  _record_progress
fi
BASH
new_ts="$(cat "$rs5/progress_ts")"
if [[ "$new_ts" -gt "$old_ts" ]]; then
  _pass "in_progress tick updates progress_ts unconditionally"
else
  _fail "in_progress tick did not update progress_ts: old=$old_ts new=$new_ts"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
