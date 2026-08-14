#!/usr/bin/env bash
# Regression: the installed git hook must run the pushed worktree's own gate.
#
# Seam under test: what `mise run install` writes into the shared hooks directory,
# invoked the way git invokes it.  The install task body is extracted from
# mise.toml and executed directly, so this needs neither mise nor docker.
#
# Why (td-85b6bf, residual after #231).  git resolves hooks from the COMMON git
# directory -- verified in a linked worktree:
#
#   git rev-parse --git-dir         -> .git/worktrees/<name>
#   git rev-parse --git-path hooks  -> .git/hooks          <- shared by all worktrees
#
# Two consequences, both observed:
#
# 1. install symlinked <common>/hooks/pre-push to the scripts/hooks/pre-push of
#    whichever checkout happened to run install.  The ACTIVE gate was therefore
#    always that checkout's on-disk copy, never the version in the branch being
#    pushed.  #231 fixed the gate's tree resolution, and the fix still could not
#    take effect: the active hook had 0 occurrences of SGT_TEST_REPO_DIR while the
#    pushed worktree's copy had 1, because the main checkout sat on another branch.
#    So the bug class survived its own fix.
#
# 2. install computed the destination from `git rev-parse --git-dir`, which in a
#    linked worktree is .git/worktrees/<name> -- a hooks directory git never
#    consults.  Running install from a linked worktree therefore installed hooks
#    that could not fire, or refused with "hooks dirs not found".
#
# The fix installs a small dispatching stub instead of a symlink.  The stub
# resolves the worktree being pushed and executes that tree's
# scripts/hooks/pre-push, so gate logic travels with the branch and the stub
# itself never needs updating when that logic changes.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export SERGEANT_CONFIG="$TEST_ROOT/config"
export SERGEANT_DRAIN_DIR="$TEST_ROOT/drain"
export SERGEANT_FLEET="$TEST_ROOT/fleet"
export TMUX_TMPDIR="$TEST_ROOT/tmux"
export SGT_INSTALL_DIR="$TEST_ROOT/install-bin"
mkdir -p "$SERGEANT_CONFIG" "$SERGEANT_DRAIN_DIR" "$SERGEANT_FLEET" "$TMUX_TMPDIR" \
  "$SGT_INSTALL_DIR"

PASS=0; FAIL=0
_pass() { PASS=$(( PASS + 1 )); printf 'PASS: %s\n' "$1"; }
_fail() { FAIL=$(( FAIL + 1 )); printf 'FAIL: %s\n' "$1" >&2; }

# ── Extract the real install:hooks body from mise.toml ───────────────────────
install_task="$TEST_ROOT/install-hooks.sh"
python3 - "$ROOT_DIR/mise.toml" "$install_task" <<'PY'
import re, sys
toml = open(sys.argv[1]).read()
start = toml.index('[tasks."install:hooks"]')
run = re.search(r'run = """(.*?)"""', toml[start:], re.S)
assert run, 'could not extract the install:hooks body'
body = run.group(1)
# `run = """..."""` is a TOML multi-line BASIC string, so TOML resolves escapes
# before mise sees the script.  Reading the raw file skips that step.
body = body.replace('\\\\', '\\').replace('\\"', '"')
open(sys.argv[2], 'w').write(body)
PY
[[ -s "$install_task" ]] || { printf 'FAIL: could not extract install:hooks\n' >&2; exit 1; }

# ── Fixture: main checkout plus a linked worktree, each with its own gate ────
main_repo="$TEST_ROOT/main-checkout"
mkdir -p "$main_repo/scripts/hooks"
git -C "$main_repo" init -q
git -C "$main_repo" config user.email test@example.invalid
git -C "$main_repo" config user.name 'Test'

# The main checkout's gate identifies itself, standing in for a stale copy on an
# unrelated branch.
cat > "$main_repo/scripts/hooks/pre-push" <<'MAINGATE'
#!/usr/bin/env bash
printf 'GATE=main-checkout\n' >> "$GATE_LOG"
exit 0
MAINGATE
chmod +x "$main_repo/scripts/hooks/pre-push"
# The real dispatcher, since install copies it into the shared hooks directory.
cp "$ROOT_DIR/scripts/git-hook-dispatch.sh" "$main_repo/scripts/git-hook-dispatch.sh"
chmod +x "$main_repo/scripts/git-hook-dispatch.sh"
printf 'x\n' > "$main_repo/marker"
git -C "$main_repo" add -A
git -C "$main_repo" commit -qm fixture

linked_wt="$TEST_ROOT/linked-worktree"
git -C "$main_repo" worktree add -q "$linked_wt" -b feature
# The pushed branch's gate differs -- this is the one that must run.
cat > "$linked_wt/scripts/hooks/pre-push" <<'FEATGATE'
#!/usr/bin/env bash
printf 'GATE=pushed-worktree\n' >> "$GATE_LOG"
exit 0
FEATGATE
chmod +x "$linked_wt/scripts/hooks/pre-push"

common_hooks="$(git -C "$main_repo" rev-parse --git-path hooks)"
common_hooks="$(cd "$main_repo" && cd "$common_hooks" && pwd -P)"

# ── 1. install from a LINKED worktree targets the shared hooks dir ───────────
# Previously this used `git rev-parse --git-dir`, which in a linked worktree is
# .git/worktrees/<name> -- a hooks directory git never consults.
rm -f "$common_hooks/pre-push"
set +e
install_out="$(cd "$linked_wt" && MISE_PROJECT_ROOT="$linked_wt" bash "$install_task" 2>&1)"
install_rc=$?
set -e
if [[ "$install_rc" -eq 0 ]]; then
  _pass "install:hooks succeeds from a linked worktree"
else
  _fail "install:hooks failed from a linked worktree"
  printf '    %s\n' "$(tail -3 <<<"$install_out")" >&2
fi
if [[ -e "$common_hooks/pre-push" ]]; then
  _pass "hook installed into the shared (common) hooks directory"
else
  _fail "no hook at the shared hooks directory git actually consults ($common_hooks)"
fi

# ── 2. The installed hook is not pinned to one checkout ─────────────────────
if [[ -L "$common_hooks/pre-push" ]]; then
  target="$(readlink "$common_hooks/pre-push")"
  _fail "installed hook is a symlink to one checkout ($target); it can never follow the pushed tree"
else
  _pass "installed hook is not a symlink into a single checkout"
fi

# ── 3. Pushing from the linked worktree runs THAT tree's gate ───────────────
# git runs pre-push with cwd at the worktree being pushed and GIT_DIR set to its
# gitdir; reproduce both.
GATE_LOG="$TEST_ROOT/gate.log"
: > "$GATE_LOG"
set +e
(
  cd "$linked_wt"
  GIT_DIR="$(git rev-parse --absolute-git-dir)" \
  GATE_LOG="$GATE_LOG" \
    bash "$common_hooks/pre-push" origin https://example.invalid/x.git < /dev/null
) > "$TEST_ROOT/dispatch.out" 2>&1
dispatch_rc=$?
set -e

if grep -Fqx 'GATE=pushed-worktree' "$GATE_LOG"; then
  _pass "the pushed worktree's gate ran"
else
  _fail "the pushed worktree's gate did not run (log: $(tr '\n' ' ' < "$GATE_LOG"))"
  printf '    %s\n' "$(tail -3 "$TEST_ROOT/dispatch.out")" >&2
fi
if grep -Fqx 'GATE=main-checkout' "$GATE_LOG"; then
  _fail "the main checkout's stale gate ran instead of the pushed tree's"
else
  _pass "the main checkout's gate did not run"
fi
if [[ "$dispatch_rc" -eq 0 ]]; then
  _pass "dispatch propagates the gate's success status"
else
  _fail "dispatch did not propagate success (rc=$dispatch_rc)"
fi

# ── 4. A failing gate still blocks the push ────────────────────────────────
cat > "$linked_wt/scripts/hooks/pre-push" <<'FAILGATE'
#!/usr/bin/env bash
printf 'GATE=pushed-worktree-failing\n' >> "$GATE_LOG"
exit 3
FAILGATE
chmod +x "$linked_wt/scripts/hooks/pre-push"
: > "$GATE_LOG"
set +e
(
  cd "$linked_wt"
  GIT_DIR="$(git rev-parse --absolute-git-dir)" GATE_LOG="$GATE_LOG" \
    bash "$common_hooks/pre-push" origin https://example.invalid/x.git < /dev/null
) >/dev/null 2>&1
fail_rc=$?
set -e
if [[ "$fail_rc" -ne 0 ]]; then
  _pass "a failing gate still blocks the push"
else
  _fail "a failing gate was swallowed; the push would proceed"
fi

# ── 5. Pushing from the main checkout runs the main checkout's gate ─────────
cat > "$linked_wt/scripts/hooks/pre-push" <<'FEATGATE2'
#!/usr/bin/env bash
printf 'GATE=pushed-worktree\n' >> "$GATE_LOG"
exit 0
FEATGATE2
chmod +x "$linked_wt/scripts/hooks/pre-push"
: > "$GATE_LOG"
set +e
(
  cd "$main_repo"
  GIT_DIR="$(git rev-parse --absolute-git-dir)" GATE_LOG="$GATE_LOG" \
    bash "$common_hooks/pre-push" origin https://example.invalid/x.git < /dev/null
) >/dev/null 2>&1
set -e
if grep -Fqx 'GATE=main-checkout' "$GATE_LOG" && ! grep -Fqx 'GATE=pushed-worktree' "$GATE_LOG"; then
  _pass "pushing from the main checkout runs the main checkout's gate"
else
  _fail "wrong gate ran for a main-checkout push (log: $(tr '\n' ' ' < "$GATE_LOG"))"
fi

# ── 6. A tree with no gate script fails closed, actionably ─────────────────
# A gate that silently disappears is the failure mode this whole card is about,
# so absence must block and say how to fix it rather than allow the push.
mv "$linked_wt/scripts/hooks/pre-push" "$TEST_ROOT/gate-parked"
: > "$GATE_LOG"
set +e
absent_out="$(
  cd "$linked_wt"
  GIT_DIR="$(git rev-parse --absolute-git-dir)" GATE_LOG="$GATE_LOG" \
    bash "$common_hooks/pre-push" origin https://example.invalid/x.git < /dev/null 2>&1
)"
absent_rc=$?
set -e
mv "$TEST_ROOT/gate-parked" "$linked_wt/scripts/hooks/pre-push"
if [[ "$absent_rc" -ne 0 ]]; then
  _pass "a tree with no gate script fails closed"
else
  _fail "a tree with no gate script silently allowed the push"
fi
if grep -Eq 'mise run install|scripts/hooks/pre-push|--no-verify' <<<"$absent_out"; then
  _pass "the absent-gate diagnostic is actionable"
else
  _fail "the absent-gate diagnostic gives no remedy: $absent_out"
fi

# ── 7. The stub cannot recurse into itself ─────────────────────────────────
# If a tree's scripts/hooks/pre-push is ever a copy of the stub, dispatching must
# terminate rather than fork forever.
cp "$common_hooks/pre-push" "$linked_wt/scripts/hooks/pre-push"
chmod +x "$linked_wt/scripts/hooks/pre-push"
: > "$GATE_LOG"
set +e
_recurse_out_unused="$(
  cd "$linked_wt"
  GIT_DIR="$(git rev-parse --absolute-git-dir)" GATE_LOG="$GATE_LOG" \
    timeout 20 bash "$common_hooks/pre-push" origin https://example.invalid/x.git < /dev/null 2>&1
)"
recurse_rc=$?
set -e
: "${_recurse_out_unused:-}"  # captured to keep the timeout output off the log
if [[ "$recurse_rc" -ne 124 ]]; then
  _pass "dispatch terminates instead of recursing"
else
  _fail "dispatch recursed until timeout"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
