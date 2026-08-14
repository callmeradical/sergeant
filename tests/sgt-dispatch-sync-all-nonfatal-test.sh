#!/usr/bin/env bash
# Regression: a failing global fleet-reconciliation sweep must not abort a
# task-scoped dispatch.
#
# sgt-dispatch runs `sgt-watch --sync-all` before creating any worktree, td
# task, or fleet state.  sgt-watch returns 1 when ANY terminal worker anywhere
# in the fleet could not be recycled.  Under `set -euo pipefail` an unguarded
# invocation aborts dispatch with status 1 and no diagnostic.
#
# That is a deadlock in practice: the two most common terminal worker states
# (`drained`, `blocked`) are rejected by sgt-cleanup, so the unrecyclable
# records are permanent and every subsequent dispatch dies — including
# dispatches that have nothing to do with the offending records.
#
# Seam under test: the sgt-dispatch CLI.  Observations are its exit status,
# its stderr, and the durable fleet state it writes.  sgt-watch is replaced by
# a stub so the sweep's failure is deterministic and no real fleet is read.

set -euo pipefail
export TMUX=fixture TMUX_PANE=%11

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap '[[ -n "${KEEP_TEST_ROOT:-}" ]] || rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/config" "$TEST_ROOT/fleet" "$TEST_ROOT/fake-bin" "$TEST_ROOT/repo"
chmod 700 "$TEST_ROOT/fleet"

PASS=0; FAIL=0
_pass() { PASS=$(( PASS + 1 )); printf 'PASS: %s\n' "$1"; }
_fail() { FAIL=$(( FAIL + 1 )); printf 'FAIL: %s\n' "$1" >&2; }

cat > "$TEST_ROOT/config/test.yaml" <<EOF
name: test
repos:
  - name: app
    path: $TEST_ROOT/repo
EOF

cat > "$TEST_ROOT/fake-bin/tmux" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "display-message" ]] || printf '%s\n' "$*" >> "$TMUX_LOG"
case "$1" in
  has-session) exit 0 ;;
  display-message)
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

git -C "$TEST_ROOT/repo" init -q
git -C "$TEST_ROOT/repo" config user.name Test
git -C "$TEST_ROOT/repo" config user.email test@example.invalid
touch "$TEST_ROOT/repo/README.md"
git -C "$TEST_ROOT/repo" add README.md
git -C "$TEST_ROOT/repo" commit -qm fixture
git -C "$TEST_ROOT/repo" remote add origin git@github.com:org/test.git

# A copy of the distribution so sgt-watch can be stubbed while bundled
# resources (templates/worker-brief.md and friends) still resolve under the
# same canonical root that sgt-dispatch validates against.  .git is excluded:
# it is large and irrelevant to resource resolution.
mkdir -p "$TEST_ROOT/root"
tar -C "$ROOT_DIR" --exclude=.git -cf - . | tar -C "$TEST_ROOT/root" -xf -

# The stub reproduces production behaviour exactly: warn on stderr about a
# terminal worker that could not be recycled, then exit 1.
cat > "$TEST_ROOT/root/bin/sgt-watch" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--sync-all" ]]; then
  printf 'WARNING: terminal worker was not recycled: stale-task-abc123/other-repo\n' >&2
  printf '  reason: terminal worker process provenance is incomplete\n' >&2
  exit 1
fi
exit 0
EOF
chmod +x "$TEST_ROOT/root/bin/sgt-watch"

_fleet_task_count() {
  find "$TEST_ROOT/fleet" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '
}

set +e
PATH="$TEST_ROOT/fake-bin:$TEST_ROOT/root/bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
SGT_WIKI_DISABLED=1 \
  "$TEST_ROOT/root/bin/sgt-dispatch" test "unrelated work" --repos app \
  > "$TEST_ROOT/dispatch.out" 2> "$TEST_ROOT/dispatch.err"
rc=$?
set -e

# ── Test 1: dispatch is not aborted by the failing sweep ─────────────────────
# Before the fix, `set -e` aborts at the unguarded sync-all call with rc=1 and
# no fleet state at all.
if [[ "$rc" -eq 0 ]]; then
  _pass "dispatch succeeds despite a failing --sync-all sweep"
else
  _fail "dispatch aborted (rc=$rc) because the global sweep returned nonzero"
  printf '  stderr: %s\n' "$(tail -5 "$TEST_ROOT/dispatch.err")" >&2
fi

# ── Test 2: dispatch actually created its fleet state ────────────────────────
# Guards against a fix that merely swallows the status without proceeding.
if [[ "$(_fleet_task_count)" -ge 1 ]]; then
  _pass "dispatch created durable fleet state for its own task"
else
  _fail "dispatch created no fleet task directory"
fi

# ── Test 3: the sweep's diagnostics are still surfaced, not swallowed ────────
# The sweep is advisory, so its warnings must remain visible to the operator.
if grep -q "terminal worker was not recycled" "$TEST_ROOT/dispatch.err"; then
  _pass "sweep warnings are still reported on stderr"
else
  _fail "sweep warnings were suppressed"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
