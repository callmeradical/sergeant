#!/usr/bin/env bash
# sgt-dispatch-unpushed-guard-test.sh — regression tests for the re-dispatch guard
# that refuses a branch carrying committed work absent from every remote (td-7f3a9a).
#
# The guard exists to stop a re-dispatch from clobbering real work left by an
# interrupted dispatch. It must NOT fire merely because a branch has no
# remote-tracking counterpart of the same name, which is the normal case for any
# repository the operator cannot push to.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# shellcheck source=bin/_sgt-lib.sh
SERGEANT_SKIP_PREFLIGHT=1 source "$ROOT_DIR/bin/_sgt-lib.sh" 2>/dev/null || \
  source "$ROOT_DIR/bin/_sgt-lib.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

upstream="$TEST_ROOT/upstream.git"
work="$TEST_ROOT/work"

git init --quiet --bare "$upstream"
git init --quiet "$work"
git -C "$work" config user.email t@example.com
git -C "$work" config user.name Test
git -C "$work" remote add origin "$upstream"

printf 'one\n' > "$work/f.txt"
git -C "$work" add f.txt
git -C "$work" commit --quiet -m "base"
git -C "$work" branch -M main
git -C "$work" push --quiet -u origin main

# ── case 1 ────────────────────────────────────────────────────────────────────
# A local branch pointing at exactly the same commit as a pushed remote ref, with
# NO refs/remotes/origin/<branch> of its own. This is what a coordinator creates
# when resuming work in a repo it cannot push to. It carries ZERO unique commits,
# so the guard must not fire.
git -C "$work" branch resume-here main
out="$(_sgt_branch_unpushed_commits "$work" resume-here)"
[[ -z "$out" ]] || fail "case 1: branch identical to a remote ref reported unpushed work: $out"
printf 'unpushed-guard: branch at a remote commit with no origin counterpart is clean ok\n'

# ── case 2 ────────────────────────────────────────────────────────────────────
# Genuinely unpushed commits must still be reported — the guard's real purpose.
git -C "$work" checkout --quiet -b has-work main
printf 'two\n' >> "$work/f.txt"
git -C "$work" commit --quiet -am "unpushed work"
out="$(_sgt_branch_unpushed_commits "$work" has-work)"
[[ -n "$out" ]] || fail "case 2: genuinely unpushed commit was not reported"
[[ "$out" == *"unpushed work"* ]] || fail "case 2: report did not name the unpushed commit: $out"
printf 'unpushed-guard: genuinely unpushed commits are still reported ok\n'

# ── case 3 ────────────────────────────────────────────────────────────────────
# A commit reachable from ANY remote ref counts as pushed, even when the remote
# branch has a different name. Reachability, not name matching, is the contract.
git -C "$work" push --quiet origin has-work:refs/heads/some-other-name
git -C "$work" fetch --quiet origin
out="$(_sgt_branch_unpushed_commits "$work" has-work)"
[[ -z "$out" ]] || fail "case 3: commit present on a differently-named remote ref reported unpushed: $out"
printf 'unpushed-guard: a commit reachable from any remote ref counts as pushed ok\n'

# ── case 4 ────────────────────────────────────────────────────────────────────
# An absent branch is not an error and reports nothing.
out="$(_sgt_branch_unpushed_commits "$work" no-such-branch)"
[[ -z "$out" ]] || fail "case 4: absent branch reported commits: $out"
printf 'unpushed-guard: absent branch reports nothing ok\n'

# ── case 5 ────────────────────────────────────────────────────────────────────
# A repository with NO remotes at all: every commit is unpushed, and the helper
# must say so rather than erroring on an invalid ref set.
solo="$TEST_ROOT/solo"
git init --quiet "$solo"
git -C "$solo" config user.email t@example.com
git -C "$solo" config user.name Test
printf 'x\n' > "$solo/g.txt"
git -C "$solo" add g.txt
git -C "$solo" commit --quiet -m "solo commit"
git -C "$solo" branch -M main
out="$(_sgt_branch_unpushed_commits "$solo" main)"
[[ -n "$out" ]] || fail "case 5: repository with no remotes reported no unpushed work"
printf 'unpushed-guard: repository with no remotes reports its commits ok\n'

# ── case 6 ────────────────────────────────────────────────────────────────────
# Mutation check: the guard must key off reachability from remotes. If the helper
# is reduced to listing the whole branch history, case 1 has to go red — that is
# exactly the defect td-7f3a9a recorded.
if _sgt_branch_unpushed_commits() { git -C "$1" log --oneline "refs/heads/$2" 2>/dev/null || true; }; then
  out="$(_sgt_branch_unpushed_commits "$work" resume-here)"
  [[ -n "$out" ]] || fail "case 6: mutation harness did not reproduce the original defect"
  printf 'unpushed-guard: mutation to whole-history listing reproduces the defect ok\n'
fi

printf '\nsgt-dispatch-unpushed-guard: all tests passed\n'
