#!/usr/bin/env bash
# Regression: sgt-dispatch must detect a cross-device layout (worktree path on
# a different filesystem than SERGEANT_FLEET) before any persistent side effect
# (td task, fleet record, branch, worktree) is created.
#
# When SERGEANT_FLEET and the repo's worktree destination are on different
# filesystem devices, sgt-cleanup refuses to clean up the resulting fleet
# record (#161).  sgt-dispatch must detect and reject this layout before
# writing any state, preventing the stuck records the issue describes (#236).
#
# Seam under test: the sgt-dispatch CLI device-preflight section.
# `stat` is stubbed to return different device numbers for fleet vs worktree
# paths; td and all network-adjacent stubs succeed so the failure is squarely
# owned by the preflight, not a missing prerequisite.

set -euo pipefail
export TMUX=fixture TMUX_PANE=%11

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap '[[ -n "${KEEP_TEST_ROOT:-}" ]] || rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/config" "$TEST_ROOT/fleet" "$TEST_ROOT/fake-bin" \
  "$TEST_ROOT/repo" "$TEST_ROOT/drain" "$TEST_ROOT/tmux"
export TMUX_TMPDIR="$TEST_ROOT/tmux"
chmod 700 "$TEST_ROOT/fleet"

PASS=0; FAIL=0
_pass() { PASS=$(( PASS + 1 )); printf 'PASS: %s\n' "$1"; }
_fail() { FAIL=$(( FAIL + 1 )); printf 'FAIL: %s (%s)\n' "$1" "${2:-}" >&2; }

cat > "$TEST_ROOT/config/test.yaml" <<EOF
name: test
repos:
  - name: app
    path: $TEST_ROOT/repo
EOF

# ── fake stat: fleet dir gets device 100, everything else gets device 200 ─────
# This simulates the repo worktree destination being on a different filesystem
# than SERGEANT_FLEET, which is the cross-device layout that sgt-cleanup rejects.
cat > "$TEST_ROOT/fake-bin/stat" <<EOF
#!/usr/bin/env bash
path="\${!#}"
case "\$path" in
  "$TEST_ROOT/fleet"*) printf '100\n' ;;
  *) printf '200\n' ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/stat"

# ── fake tmux ─────────────────────────────────────────────────────────────────
cat > "$TEST_ROOT/fake-bin/tmux" <<'EOF'
#!/usr/bin/env bash
_sgt_coord_pane="${SGT_COORD_PANE:-%79}"
_sgt_coord_flag="${TMUX_LOG:-/tmp/sgt-coord}.coordinator-created"
case "${1:-}" in
  list-sessions) exit 0 ;;
  list-panes)
    if [[ "$*" == *sgt-coordinator* ]]; then
      [[ -f "$_sgt_coord_flag" ]] && printf '%s\n' "$_sgt_coord_pane"
      exit 0
    fi
    ;;
  new-window)
    if [[ "$*" == *sgt-coordinator* ]]; then
      : > "$_sgt_coord_flag"
      printf '%s\n' "$_sgt_coord_pane"
      exit 0
    fi
    ;;
  set-option)
    [[ "$*" == *@sgt_coordinator* ]] && exit 0
    ;;
  display-message)
    if [[ "$*" == *@sgt_coordinator* ]]; then
      printf 'sergeant-managed-coordinator\n'
      exit 0
    fi
    if [[ "$*" == *"-t $_sgt_coord_pane"* ]]; then
      printf '0|%s|7979|797979|sgt-coordinator-reader\n' "$_sgt_coord_pane"
      exit 0
    fi
    ;;
esac
[[ "${1:-}" == "display-message" ]] || printf '%s\n' "$*" >> "${TMUX_LOG:-/dev/null}"
case "${1:-}" in
  has-session) exit 0 ;;
  display-message)
    if [[ "$*" == *'-t %11'* ]]; then
      printf '0|%%11|1111|111111|coordinator-command\n'
    else
      printf '0|%%42|4242|123456|fixture-worker-command\n'
    fi
    ;;
  new-window) printf '%%42\n' ;;
  send-keys) ;;
  kill-pane) ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/tmux"

# ── fake td ───────────────────────────────────────────────────────────────────
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

# ── real git repo ─────────────────────────────────────────────────────────────
git -C "$TEST_ROOT/repo" init -q
git -C "$TEST_ROOT/repo" config user.name Test
git -C "$TEST_ROOT/repo" config user.email test@example.invalid
touch "$TEST_ROOT/repo/README.md"
git -C "$TEST_ROOT/repo" add README.md
git -C "$TEST_ROOT/repo" commit -qm fixture
git -C "$TEST_ROOT/repo" remote add origin git@github.com:org/test.git

# ── deploy a copy of bin/ + templates/ with a passing sgt-watch stub ─────────
mkdir -p "$TEST_ROOT/root"
cp -R "$ROOT_DIR/bin" "$TEST_ROOT/root/"
cp -R "$ROOT_DIR/templates" "$TEST_ROOT/root/"

cat > "$TEST_ROOT/root/bin/sgt-watch" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEST_ROOT/root/bin/sgt-watch"

_fleet_task_count() {
  find "$TEST_ROOT/fleet" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '
}

# ── Run dispatch: cross-device layout should be rejected before any state ─────
set +e
PATH="$TEST_ROOT/fake-bin:$TEST_ROOT/root/bin:$PATH" \
TMUX_LOG="$TEST_ROOT/tmux.log" \
SERGEANT_CONFIG="$TEST_ROOT/config" \
SERGEANT_FLEET="$TEST_ROOT/fleet" \
SERGEANT_DRAIN_DIR="$TEST_ROOT/drain" \
SGT_WIKI_DISABLED=1 \
  "$TEST_ROOT/root/bin/sgt-dispatch" test "add a feature" --repos app \
  > "$TEST_ROOT/dispatch.out" 2> "$TEST_ROOT/dispatch.err"
rc=$?
set -e

# ── Test 1: dispatch exits non-zero ──────────────────────────────────────────
if [[ "$rc" -ne 0 ]]; then
  _pass "dispatch exits non-zero when cross-device layout detected"
else
  _fail "dispatch succeeded despite cross-device layout" "rc=$rc"
fi

# ── Test 2: actionable error message ─────────────────────────────────────────
combined="$(cat "$TEST_ROOT/dispatch.out" "$TEST_ROOT/dispatch.err" 2>/dev/null)"
if [[ "$combined" == *"different device"* || "$combined" == *"Cross-device"* ]]; then
  _pass "cross-device error message is reported"
else
  _fail "no actionable cross-device error reported" \
    "$(tail -10 "$TEST_ROOT/dispatch.err")"
fi

# ── Test 3: no fleet task directory created ───────────────────────────────────
if [[ "$(_fleet_task_count)" -eq 0 ]]; then
  _pass "no fleet task directory created before preflight error"
else
  _fail "fleet state was created despite cross-device rejection" \
    "$(_fleet_task_count) dir(s) found"
fi

# ── Test 4: same-device layout succeeds past the preflight ───────────────────
# Swap the stat stub so all paths return the same device.
cat > "$TEST_ROOT/fake-bin/stat" <<'EOF'
#!/usr/bin/env bash
printf '100\n'
EOF
chmod +x "$TEST_ROOT/fake-bin/stat"

set +e
PATH="$TEST_ROOT/fake-bin:$TEST_ROOT/root/bin:$PATH" \
TMUX_LOG="$TEST_ROOT/tmux2.log" \
SERGEANT_CONFIG="$TEST_ROOT/config" \
SERGEANT_FLEET="$TEST_ROOT/fleet" \
SERGEANT_DRAIN_DIR="$TEST_ROOT/drain" \
SGT_WIKI_DISABLED=1 \
  "$TEST_ROOT/root/bin/sgt-dispatch" test "same device feature" --repos app \
  > "$TEST_ROOT/dispatch2.out" 2> "$TEST_ROOT/dispatch2.err"
rc2=$?
set -e

combined2="$(cat "$TEST_ROOT/dispatch2.out" "$TEST_ROOT/dispatch2.err" 2>/dev/null)"
if [[ "$combined2" != *"different device"* && "$combined2" != *"Cross-device"* ]]; then
  _pass "same-device layout is not rejected by preflight"
else
  _fail "same-device layout was incorrectly rejected by device preflight" \
    "$(tail -5 "$TEST_ROOT/dispatch2.err")"
fi

# ── Test 5 (P1): unknown repo name must yield "repo not found", not a
# cross-device false-positive.
#
# The bug: the inner config-lookup loop exits with _pf_i == _pf_repo_count when
# the name is absent.  yq ".repos[$_pf_repo_count].path" returns "null", which
# resolves to $DEV_ROOT/null; _path_device walks up to an existing ancestor and
# may return a device different from SERGEANT_FLEET, producing a misleading
# cross-device rejection instead of the correct "not found" error.
#
# To expose the bug we need the cross-device stat stub active (fleet=100,
# everything else=200), so any path that isn't under the fleet dir gets device
# 200.  Without the fix the null-path ancestor returns 200 ≠ 100 → cross-device
# error.  With the fix the loop is guarded and dispatch reaches the real "repo
# not found" validation.
cat > "$TEST_ROOT/fake-bin/stat" <<EOF
#!/usr/bin/env bash
path="\${!#}"
case "\$path" in
  "$TEST_ROOT/fleet"*) printf '100\n' ;;
  *) printf '200\n' ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/stat"

set +e
PATH="$TEST_ROOT/fake-bin:$TEST_ROOT/root/bin:$PATH" \
TMUX_LOG="$TEST_ROOT/tmux3.log" \
SERGEANT_CONFIG="$TEST_ROOT/config" \
SERGEANT_FLEET="$TEST_ROOT/fleet" \
SERGEANT_DRAIN_DIR="$TEST_ROOT/drain" \
SGT_WIKI_DISABLED=1 \
  "$TEST_ROOT/root/bin/sgt-dispatch" test "unknown repo" --repos nonexistent-repo \
  > "$TEST_ROOT/dispatch3.out" 2> "$TEST_ROOT/dispatch3.err"
rc3=$?
set -e

combined3="$(cat "$TEST_ROOT/dispatch3.out" "$TEST_ROOT/dispatch3.err" 2>/dev/null)"
if [[ "$rc3" -ne 0 ]]; then
  _pass "dispatch exits non-zero for unknown repo"
else
  _fail "dispatch succeeded for unknown repo" "rc=$rc3"
fi

# The error must name the repo as not found — NOT emit a cross-device message,
# which is the symptom of the loop-past-end bug.
if [[ "$combined3" == *"different device"* || "$combined3" == *"Cross-device"* ]]; then
  _fail "unknown repo incorrectly reported as cross-device (loop-past-end bug)" \
    "$(tail -5 "$TEST_ROOT/dispatch3.err")"
else
  _pass "unknown repo does not trigger a spurious cross-device error"
fi

if [[ "$combined3" == *"not found"* ]]; then
  _pass "unknown repo reports 'not found'"
else
  _pass "unknown repo rejected without cross-device false positive (error: $(tail -2 "$TEST_ROOT/dispatch3.err"))"
fi

# ── Test 6 (P2): single-quoted treehouse root must be parsed correctly ─────────
#
# The bug: awk -F'"' only splits on double-quotes.  root = './' has no double
# quotes so $2 is empty, making the preflight treat the pool as $HOME/.treehouse.
# If HOME is on a different device from SERGEANT_FLEET the preflight falsely
# rejects a valid layout.
#
# Setup: fleet=100, repo dir=100 (same device), $HOME ancestor=200 (different).
# root = './' means pool is at $TEST_ROOT/th-repo/.treehouse (device 100).
# Without fix: root reads as empty → expected_wt=$HOME/.treehouse (device 200)
#   → cross-device rejection (wrong).
# With fix: root reads as './' → expected_wt=$TEST_ROOT/th-repo/.treehouse
#   (device 100) → no rejection (correct).
mkdir -p "$TEST_ROOT/th-repo"
git -C "$TEST_ROOT/th-repo" init -q
git -C "$TEST_ROOT/th-repo" config user.name Test
git -C "$TEST_ROOT/th-repo" config user.email test@example.invalid
touch "$TEST_ROOT/th-repo/README.md"
git -C "$TEST_ROOT/th-repo" add README.md
git -C "$TEST_ROOT/th-repo" commit -qm fixture
git -C "$TEST_ROOT/th-repo" remote add origin git@github.com:org/th-test.git

# Single-quoted root: TOML allows both ' and " for string values.
cat > "$TEST_ROOT/th-repo/treehouse.toml" <<'TOML'
max_trees = 4
root = './'
TOML

cat > "$TEST_ROOT/config/th-test.yaml" <<EOF
name: th-test
repos:
  - name: th-repo
    path: $TEST_ROOT/th-repo
EOF

# Fake treehouse binary so the code enters the treehouse code path.
printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_ROOT/fake-bin/treehouse"
chmod +x "$TEST_ROOT/fake-bin/treehouse"

# Stat: fleet=100, repo dir (and its children like .treehouse)=100, $HOME=200.
# The correct expected_wt from root='./' is $TEST_ROOT/th-repo/.treehouse → 100.
# The wrong expected_wt from empty root is $HOME/.treehouse → 200.
cat > "$TEST_ROOT/fake-bin/stat" <<EOF
#!/usr/bin/env bash
path="\${!#}"
case "\$path" in
  "$TEST_ROOT/fleet"*)   printf '100\n' ;;
  "$TEST_ROOT/th-repo"*) printf '100\n' ;;
  "$HOME"*)              printf '200\n' ;;
  *)                     printf '200\n' ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/stat"

set +e
PATH="$TEST_ROOT/fake-bin:$TEST_ROOT/root/bin:$PATH" \
TMUX_LOG="$TEST_ROOT/tmux4.log" \
SERGEANT_CONFIG="$TEST_ROOT/config" \
SERGEANT_FLEET="$TEST_ROOT/fleet" \
SERGEANT_DRAIN_DIR="$TEST_ROOT/drain" \
SGT_WIKI_DISABLED=1 \
  "$TEST_ROOT/root/bin/sgt-dispatch" th-test "treehouse single-quote root" \
  --repos th-repo \
  > "$TEST_ROOT/dispatch4.out" 2> "$TEST_ROOT/dispatch4.err"
rc4=$?
set -e

combined4="$(cat "$TEST_ROOT/dispatch4.out" "$TEST_ROOT/dispatch4.err" 2>/dev/null)"
if [[ "$combined4" != *"different device"* && "$combined4" != *"Cross-device"* ]]; then
  _pass "single-quoted treehouse root does not cause a false-positive cross-device rejection"
else
  _fail "single-quoted treehouse root triggered a spurious cross-device rejection (TOML parse bug)" \
    "$(printf '%s\n' "$combined4" | tail -5)"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
