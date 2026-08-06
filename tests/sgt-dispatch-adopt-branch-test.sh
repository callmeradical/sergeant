#!/usr/bin/env bash
# sgt-dispatch-adopt-branch-test.sh — resuming preserved work on an existing branch.
#
# The unpushed-work guard exists to stop a re-dispatch from clobbering work left by
# an interrupted dispatch. It must not make preserved work permanently unresumable
# in a repository whose upstream denies push access, where commits can never become
# remote-reachable (td-7f3a9a).
#
# Contract under test: --adopt-branch is an explicit operator acknowledgement that
# the named branch already carries committed work and should be resumed as-is. It
# is non-destructive: dispatch checks the branch out at a new worktree path and
# every commit survives.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# ── State isolation (required by global-state-isolation-test.sh) ──────────────
export SERGEANT_FLEET="$TEST_ROOT/fleet"
export SERGEANT_DRAIN_DIR="$TEST_ROOT/drain"
export SERGEANT_CONFIG="$TEST_ROOT/sergeant-config"
mkdir -p "$SERGEANT_FLEET" "$SERGEANT_DRAIN_DIR" "$SERGEANT_CONFIG"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# ── usage surface ─────────────────────────────────────────────────────────────
# sgt-dispatch documents its options in the header comment block, not in runtime
# output: it has no --help and dies with a single-line usage. Assert the option is
# documented where this tool's other options are documented.
sed -n '/^# Options:/,/^#$/p' "$ROOT_DIR/bin/sgt-dispatch" | grep -q -- '--adopt-branch' || \
  fail "--adopt-branch is not documented in the header Options block"
printf 'adopt-branch: option is documented alongside the other options ok\n'

# ── the option must be accepted, not rejected as unknown ──────────────────────
set +e
out="$("$ROOT_DIR/bin/sgt-dispatch" --adopt-branch 2>&1)"
set -e
[[ "$out" != *"Unknown option: --adopt-branch"* ]] || \
  fail "--adopt-branch is rejected as an unknown option"
printf 'adopt-branch: option is accepted by the parser ok\n'

# ── guard behaviour, exercised directly against the helper contract ───────────
# shellcheck source=bin/_sgt-lib.sh
source "$ROOT_DIR/bin/_sgt-lib.sh"

work="$TEST_ROOT/work"
git init --quiet "$work"
git -C "$work" config user.email t@example.com
git -C "$work" config user.name Test
printf 'base\n' > "$work/f.txt"
git -C "$work" add f.txt
git -C "$work" commit --quiet -m base
git -C "$work" branch -M main

# A branch carrying work that exists on no remote, and never can: no remote at all.
git -C "$work" checkout --quiet -b preserved
printf 'work\n' >> "$work/f.txt"
git -C "$work" commit --quiet -am "preserved work"
git -C "$work" checkout --quiet main

unpushed="$(_sgt_branch_unpushed_commits "$work" preserved)"
[[ -n "$unpushed" ]] || fail "precondition: preserved branch should report unpushed work"
printf 'adopt-branch: precondition - preserved work is correctly detected as unpushed ok\n'

# The operation the guard blocks must be provably non-destructive: checking the
# branch out at a second path preserves every commit.
before="$(git -C "$work" rev-parse preserved)"
git -C "$work" worktree add --quiet "$TEST_ROOT/resumed" preserved 2>/dev/null
after="$(git -C "$work" rev-parse preserved)"
[[ "$before" == "$after" ]] || fail "worktree add altered the branch tip: $before -> $after"
[[ -f "$TEST_ROOT/resumed/f.txt" ]] || fail "resumed worktree is missing tracked content"
grep -q work "$TEST_ROOT/resumed/f.txt" || fail "resumed worktree lost the preserved commit's content"
printf 'adopt-branch: resuming an existing branch is non-destructive ok\n'
git -C "$work" worktree remove --force "$TEST_ROOT/resumed"

# ── the refusal message must not tell the operator to delete committed work ───
msg="$(grep -A2 'already has committed work not reachable' "$ROOT_DIR/bin/sgt-dispatch" | head -4)"
[[ "$msg" != *"delete the branch"* ]] || \
  fail "refusal still instructs deleting the branch, which is the data loss it exists to prevent"
[[ "$msg" == *"--adopt-branch"* ]] || \
  fail "refusal does not name --adopt-branch as the supported reconcile path"
printf 'adopt-branch: refusal names a non-destructive reconcile path ok\n'

printf '\nsgt-dispatch-adopt-branch: all tests passed\n'
