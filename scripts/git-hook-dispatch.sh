#!/usr/bin/env bash
# git-hook-dispatch.sh — installed into the shared hooks directory as each hook
# name, and dispatches to the hook script of the worktree actually being acted on.
#
# Installed by: mise run install  (and mise run install:hooks)
# Never edit the installed copy; edit this file and reinstall.
#
# Why this indirection exists (td-85b6bf).
#
# git resolves hooks from the COMMON git directory, which every linked worktree
# shares.  In a linked worktree:
#
#   git rev-parse --git-dir         -> .git/worktrees/<name>
#   git rev-parse --git-path hooks  -> .git/hooks          <- shared
#
# Install used to symlink that shared path to the scripts/hooks/<name> of
# whichever checkout happened to run install.  The ACTIVE hook was therefore
# always that one checkout's on-disk copy, never the version belonging to the
# branch being acted on.  Consequences, both observed on 2026-08-14:
#
#   * A pre-push gate ran against an unrelated tree's state, so it failed a
#     correct branch -- and could equally pass a broken one.
#   * Fixing the gate did not help: the fix lived in the pushed branch while the
#     stale main-checkout copy kept running.  The bug class survived its own fix.
#
# So the installed copy is this stable dispatcher instead.  Gate logic lives in
# each tree's scripts/hooks/<name> and travels with the branch; this file only
# has to answer "which tree?", so it does not need reinstalling when that logic
# changes.

set -uo pipefail

hook_name="${0##*/}"

# Recursion guard.  If a tree's scripts/hooks/<name> is ever a copy of this
# dispatcher, exec'ing it would fork forever.  Fail closed and name the cause.
guard_var="SGT_HOOK_DISPATCH_ACTIVE_${hook_name//[^A-Za-z0-9]/_}"
if [[ -n "${!guard_var:-}" ]]; then
  printf '%s: refusing to dispatch to itself.\n' "$hook_name" >&2
  printf '  %s appears to be a copy of scripts/git-hook-dispatch.sh.\n' \
    "scripts/hooks/$hook_name" >&2
  printf '  Restore the real hook script, then run: mise run install:hooks\n' >&2
  exit 1
fi
export "$guard_var=1"

# The tree being acted on.  git runs hooks with the working directory set to the
# root of that worktree, and --show-toplevel honours it, so this is correct for
# the main checkout and for every linked worktree.
tree="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$tree" ]]; then
  printf '%s: could not determine which worktree is being acted on.\n' "$hook_name" >&2
  printf '  Run from inside a git worktree, or use --no-verify to skip.\n' >&2
  exit 1
fi

target="$tree/scripts/hooks/$hook_name"

# Fail closed when the tree ships no hook script.  A gate that silently vanishes
# is precisely the failure this indirection exists to prevent, so absence must
# block and explain itself rather than allow the operation through.
if [[ ! -f "$target" ]]; then
  printf '%s: %s is missing, so the gate cannot run.\n' "$hook_name" "$target" >&2
  printf '  This checkout may predate the hook, or the file was removed.\n' >&2
  printf '  Fix the checkout and run: mise run install:hooks\n' >&2
  printf '  To bypass deliberately: git push --no-verify\n' >&2
  exit 1
fi

# exec so the gate's exit status and stdin (pre-push receives refs on stdin) pass
# through untouched.  bash explicitly: the target need not be executable, and its
# interpretation must not depend on the caller's shell.
exec bash "$target" "$@"
