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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
