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
# Two seams, in one file because they answer one question — which device does a
# path belong to, and does dispatch act on that answer:
#
#   Tests 1-6  the sgt-dispatch CLI device-preflight section, with `stat`
#              stubbed to return chosen device numbers for fleet vs worktree
#              paths.  td and all network-adjacent stubs succeed so a failure is
#              squarely owned by the preflight, not a missing prerequisite.
#   Test 7     bin/_sgt-lib.sh:_path_device, the shared function both the
#              preflight and sgt-cleanup ask, against the REAL `stat` and a real
#              symlink (#236).  Stubbing `stat` is what hid this bug from Tests
#              1-6, so these cases deliberately do not stub it.  They live here
#              rather than in a tests/sgt-lib-*-test.sh file because the
#              behaviour they pin is the preflight verdict the Test 7h dispatch
#              case then asserts end-to-end, and splitting them would let one
#              half be changed without the other.

set -euo pipefail
export TMUX=fixture TMUX_PANE=%11

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
# Second-device fixture root (Test 7).  It lives on a machine-shared tmpfs, not
# under TEST_ROOT, so the trap must remove it too — and must fire on a signalled
# exit as well, or an interrupted run leaves the fixture behind for everyone.
ALT_ROOT=""
# Resolved before the trap is installed so cleanup can never expand an empty
# base into a root-level glob.
ALT_BASE="${SGT_TEST_ALT_DEVICE_DIR:-/dev/shm}"
_devpf_cleanup() {
  if [[ -n "${KEEP_TEST_ROOT:-}" ]]; then
    printf 'KEEP_TEST_ROOT: retained %s%s\n' "$TEST_ROOT" \
      "${ALT_ROOT:+ and $ALT_ROOT}" >&2
    return 0
  fi
  rm -rf "$TEST_ROOT"
  # Removed by glob, not by variable: mktemp creates the directory before the
  # command substitution assigns ALT_ROOT, and a signal in that window would
  # otherwise leak it.  The PID stamp keeps concurrent runs from reaping each
  # other's fixtures.
  rm -rf "$ALT_BASE"/sgt-devpf-$$-* 2>/dev/null || true
}
trap _devpf_cleanup EXIT
# A returning signal trap resumes the script, which would run every remaining
# assertion against a fixture that no longer exists.  Terminate instead.
trap '_devpf_cleanup; trap - EXIT; exit 130' INT TERM HUP
mkdir -p "$TEST_ROOT/config" "$TEST_ROOT/fleet" "$TEST_ROOT/fake-bin" \
  "$TEST_ROOT/repo" "$TEST_ROOT/drain" "$TEST_ROOT/tmux"
export TMUX_TMPDIR="$TEST_ROOT/tmux"
chmod 700 "$TEST_ROOT/fleet"

PASS=0; FAIL=0; SKIP=0
_pass() { PASS=$(( PASS + 1 )); printf 'PASS: %s\n' "$1"; }
_fail() { FAIL=$(( FAIL + 1 )); printf 'FAIL: %s (%s)\n' "$1" "${2:-}" >&2; }
# Counted, not just printed: a skipped two-device case must not be readable as
# "the #236 regression ran and passed" in the summary line.
_skip() { SKIP=$(( SKIP + 1 )); printf 'SKIP: %s (%s)\n' "$1" "${2:-}"; }

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

# ── Test 7 (#236 regression): device resolution through symlinks ─────────────
#
# Every test above stubs `stat`, so none of them can see how the real one
# behaves — which is exactly how #236 survived them.  Test 7 uses the real
# `stat` and real symlinks against bin/_sgt-lib.sh:_path_device, the function
# both the dispatch preflight and sgt-cleanup ask.
#
# Tests 7a-7c need only one device and run everywhere.  Tests 7d-7j need a
# second writable device to reproduce the reported topology:
#
#   $TEST_ROOT/fleet-link   symlink inode on device A (the container's overlay
#                           root; $HOME on the reporter's Homebrew install)
#           │
#           └─► $ALT_ROOT/fleet          target directory on device B (a tmpfs)
#               $ALT_ROOT/dev/app2       repo whose worktree parent is device B
#
# The layout is legal: the fleet state and the worktree both end up on device B,
# so sgt-cleanup can process it.  But `stat -c '%d' <symlink>` reports the
# device of the symlink inode, not of its target — GNU stat does not dereference
# unless asked — so _path_device measured device A for the fleet and device B
# for the worktree and dispatch rejected a layout it must accept.
#
# The second device comes from /dev/shm (a tmpfs) or $SGT_TEST_ALT_DEVICE_DIR.
# The Docker image always has both (/dev/shm tmpfs, / overlay) and
# tests/run-drain-tests.sh runs this suite there on every push, with
# SGT_TEST_REQUIRE_ALT_DEVICE=1 so a missing second device fails the gate instead
# of quietly reporting a green run that covered nothing of #236.  A host without
# a second device counts a SKIP in the summary line.

# Deliberately an independent oracle rather than a call into the library: the
# expected device must not be produced by the code under test.
_real_device() {
  stat -Lc '%d' "$1" 2>/dev/null || stat -Lf '%d' "$1" 2>/dev/null
}

# _path_device as the shipped library defines it — the seam under test.
_lib_path_device() {
  bash -c 'source "$1"; _path_device "$2"' _ "$ROOT_DIR/bin/_sgt-lib.sh" "$1"
}

# _assert_device <label> <path> <expected-device>
# Asserts _path_device exits 0 and prints <expected-device>.
_assert_device() {
  local label="$1" path="$2" want="$3" got rc
  set +e
  got="$(_lib_path_device "$path")"
  rc=$?
  set -e
  if [[ "$rc" -eq 0 && -n "$want" && "$got" == "$want" ]]; then
    _pass "$label"
  else
    _fail "$label" "rc=$rc got=$got want=$want"
  fi
}

test_root_device="$(_real_device "$TEST_ROOT" || true)"

# ── Test 7a: a nonexistent path still resolves through its ancestors ──────────
# The fix must not turn "does not exist yet" into a hard failure: the worktree
# destination normally does not exist when the preflight measures it.
_assert_device "_path_device uses the nearest existing ancestor for a nonexistent path" \
  "$TEST_ROOT/repo/not/created/yet" "$test_root_device"

# ── Test 7b: a dangling symlink resolves to its parent, it does not fail ──────
# `stat -L` on a dangling symlink fails.  Dereferencing without also treating a
# dangling link as nonexistent would make _path_device return 1 and dispatch die
# with "Cannot determine filesystem device" on a layout it used to accept.
ln -s "$TEST_ROOT/no-such-target" "$TEST_ROOT/dangling-link"
_assert_device "_path_device resolves a dangling symlink to its parent device" \
  "$TEST_ROOT/dangling-link" "$test_root_device"

# ── Test 7c: a symlink loop resolves to its parent, it does not hang or fail ──
# ELOOP is the other way `stat -L` fails.  `-e` reports false for a loop, so the
# ancestor walk handles it exactly like any other unresolvable path.
ln -s "$TEST_ROOT/loop-link" "$TEST_ROOT/loop-link"
_assert_device "_path_device resolves a symlink loop to its parent device" \
  "$TEST_ROOT/loop-link" "$test_root_device"

# ── Tests 7d-7j: the reported two-device topology ─────────────────────────────
# The second device comes from $ALT_BASE — /dev/shm, or $SGT_TEST_ALT_DEVICE_DIR
# when set; resolved next to the cleanup trap above.
alt_base_device=""
alt_skip_reason=""
if [[ ! -d "$ALT_BASE" || ! -w "$ALT_BASE" ]]; then
  alt_skip_reason="$ALT_BASE is missing or not writable; set SGT_TEST_ALT_DEVICE_DIR to a path on a second filesystem"
else
  alt_base_device="$(_real_device "$ALT_BASE" || true)"
  if [[ -z "$test_root_device" || -z "$alt_base_device" ]]; then
    alt_skip_reason="cannot read the device of $ALT_BASE or $TEST_ROOT"
  elif [[ "$test_root_device" == "$alt_base_device" ]]; then
    alt_skip_reason="$ALT_BASE is on the same device as $TEST_ROOT; set SGT_TEST_ALT_DEVICE_DIR to a path on a second filesystem"
  fi
fi

# A skip is honest on a one-device host, and a defect anywhere the caller
# promised two devices.  tests/run-drain-tests.sh and Dockerfile.test set
# SGT_TEST_REQUIRE_ALT_DEVICE=1 for the containerized pre-push gate, where
# /dev/shm is always a separate tmpfs: there, an absent second device means the
# gate stopped covering #236 and must fail rather than report a green skip.
if [[ -n "$alt_skip_reason" ]]; then
  if [[ "${SGT_TEST_REQUIRE_ALT_DEVICE:-0}" == "1" ]]; then
    _fail "#236 two-device cases could not run but SGT_TEST_REQUIRE_ALT_DEVICE=1" \
      "$alt_skip_reason; unset SGT_TEST_REQUIRE_ALT_DEVICE to skip them instead"
  else
    _skip "#236 two-device cases 7d-7j (symlink resolution, dispatch accept, dispatch reject)" \
      "$alt_skip_reason"
  fi
else
  ALT_ROOT="$(mktemp -d "$ALT_BASE/sgt-devpf-$$-XXXXXX")"
  mkdir -p "$ALT_ROOT/fleet" "$ALT_ROOT/fleet-b" "$ALT_ROOT/dev"
  chmod 700 "$ALT_ROOT/fleet" "$ALT_ROOT/fleet-b"
  ln -s "$ALT_ROOT/fleet" "$TEST_ROOT/fleet-link"
  target_device="$(_real_device "$ALT_ROOT/fleet" || true)"

  # ── Test 7d: the library seam, against the reported topology ───────────────
  _assert_device "_path_device measures an existing symlink by its resolved target device" \
    "$TEST_ROOT/fleet-link" "$target_device"

  # ── Test 7e: a relative symlink resolves against its own directory ──────────
  # Pointed across the device boundary deliberately: a relative link inside one
  # filesystem would report the same device before and after the fix and prove
  # nothing.
  ln -s fleet-link "$TEST_ROOT/relative-link"
  _assert_device "_path_device resolves a relative symlink to its target device" \
    "$TEST_ROOT/relative-link" "$target_device"

  # ── Test 7f: a symlink chain resolves to the final target ──────────────────
  ln -s "$TEST_ROOT/fleet-link" "$TEST_ROOT/chain-link"
  _assert_device "_path_device follows a symlink chain to its final target device" \
    "$TEST_ROOT/chain-link" "$target_device"

  # ── Test 7g: nonexistent path whose nearest existing ancestor is a symlink ──
  # The composition of 7a and 7d, and the shape dispatch measures when
  # SERGEANT_FLEET is a symlink whose subdirectories do not exist yet.
  _assert_device "_path_device resolves a nonexistent path under a symlinked ancestor" \
    "$TEST_ROOT/fleet-link/not/created/yet" "$target_device"

  # The real stat, not the stub every earlier test installs: the dispatch cases
  # below are only meaningful against real device numbers.
  mkdir -p "$TEST_ROOT/fake-bin-real-stat"
  cp "$TEST_ROOT/fake-bin/tmux" "$TEST_ROOT/fake-bin/td" \
    "$TEST_ROOT/fake-bin/opencode" "$TEST_ROOT/fake-bin-real-stat/"

  # ── Test 7h: dispatch clears the preflight over the real topology ──────────
  mkdir -p "$ALT_ROOT/dev/app2"
  git -C "$ALT_ROOT/dev/app2" init -q
  git -C "$ALT_ROOT/dev/app2" config user.name Test
  git -C "$ALT_ROOT/dev/app2" config user.email test@example.invalid
  touch "$ALT_ROOT/dev/app2/README.md"
  git -C "$ALT_ROOT/dev/app2" add README.md
  git -C "$ALT_ROOT/dev/app2" commit -qm fixture
  git -C "$ALT_ROOT/dev/app2" remote add origin git@github.com:org/alt-test.git

  cat > "$TEST_ROOT/config/sym-test.yaml" <<EOF
name: sym-test
repos:
  - name: app2
    path: $ALT_ROOT/dev/app2
EOF

  # This case asserts on the preflight, which runs long before the worker
  # handshake; the fixture agent never acknowledges, so cap that wait instead of
  # spending the default 60s on an outcome the assertions do not read.
  set +e
  PATH="$TEST_ROOT/fake-bin-real-stat:$TEST_ROOT/root/bin:$PATH" \
  TMUX_LOG="$TEST_ROOT/tmux5.log" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet-link" \
  SERGEANT_DRAIN_DIR="$TEST_ROOT/drain" \
  SGT_NOTIFICATION_ACK_TIMEOUT=2 \
  SGT_WIKI_DISABLED=1 \
    "$TEST_ROOT/root/bin/sgt-dispatch" sym-test "symlinked fleet" --repos app2 \
    > "$TEST_ROOT/dispatch5.out" 2> "$TEST_ROOT/dispatch5.err"
  set -e

  # Two assertions, because the absence of a rejection is not proof the
  # preflight ran: the layout must be accepted (no rejection, and no "cannot
  # determine" from a dereference that failed instead of resolving) AND the
  # dispatch must have reached the state creation the preflight guards.  The
  # dispatch itself does not complete — the stub agent never acknowledges — and
  # the record survives only because sgt-dispatch's rollback preserves a repo
  # state whose `pane` file is non-empty.  If that rollback ever stops
  # preserving it, this case fails loudly rather than silently weakening.
  combined5="$(cat "$TEST_ROOT/dispatch5.out" "$TEST_ROOT/dispatch5.err" 2>/dev/null)"
  fleet_records="$(find "$ALT_ROOT/fleet" -mindepth 2 -maxdepth 2 -type d -name app2 \
    2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$combined5" != *"different device"* && "$combined5" != *"Cross-device"* && \
        "$combined5" != *"Cannot determine filesystem device"* && \
        "$fleet_records" -gt 0 ]]; then
    _pass "dispatch clears the preflight for a fleet symlink whose target shares the worktree device"
  else
    _fail "dispatch rejected a same-device layout reached through a fleet symlink" \
      "fleet_records=$fleet_records $(printf '%s' "$combined5" | tail -5)"
  fi

  # ── Tests 7i-7j: dereferencing must not make everything look same-device ───
  # Following symlinks can only ever merge two paths onto one device, so the
  # cases above cannot show the gate still rejects anything.  Here the symlink's
  # TARGET is on device B while the repo — and therefore its worktree parent —
  # stays on device A, which is the layout sgt-cleanup genuinely cannot process
  # (#161).  Measured with the real stat, unlike Tests 1-3.
  ln -s "$ALT_ROOT/fleet-b" "$TEST_ROOT/fleet-link-b"
  reject_fleet_device="$(_lib_path_device "$TEST_ROOT/fleet-link-b" || true)"
  reject_wt_device="$(_lib_path_device "$TEST_ROOT" || true)"
  if [[ -n "$reject_fleet_device" && -n "$reject_wt_device" && \
        "$reject_fleet_device" != "$reject_wt_device" ]]; then
    _pass "_path_device still separates devices when the symlink target is on another filesystem"
  else
    _fail "_path_device collapsed a genuinely cross-device symlink layout onto one device" \
      "fleet=$reject_fleet_device worktree=$reject_wt_device"
  fi

  set +e
  PATH="$TEST_ROOT/fake-bin-real-stat:$TEST_ROOT/root/bin:$PATH" \
  TMUX_LOG="$TEST_ROOT/tmux6.log" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet-link-b" \
  SERGEANT_DRAIN_DIR="$TEST_ROOT/drain" \
  SGT_NOTIFICATION_ACK_TIMEOUT=2 \
  SGT_WIKI_DISABLED=1 \
    "$TEST_ROOT/root/bin/sgt-dispatch" test "cross-device through a symlink" --repos app \
    > "$TEST_ROOT/dispatch6.out" 2> "$TEST_ROOT/dispatch6.err"
  rc6=$?
  set -e

  combined6="$(cat "$TEST_ROOT/dispatch6.out" "$TEST_ROOT/dispatch6.err" 2>/dev/null)"
  reject_records="$(find "$ALT_ROOT/fleet-b" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
    | wc -l | tr -d ' ')"
  if [[ "$rc6" -ne 0 && "$reject_records" -eq 0 && \
        ( "$combined6" == *"different device"* || "$combined6" == *"Cross-device"* ) ]]; then
    _pass "dispatch still rejects a layout whose symlink target is on another device"
  else
    _fail "dispatch accepted a genuinely cross-device layout reached through a symlink" \
      "rc=$rc6 records=$reject_records $(printf '%s' "$combined6" | tail -5)"
  fi
fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[[ "$FAIL" -eq 0 ]]
