#!/usr/bin/env bash
# fixture-checkout.sh — build a throwaway copy of a Sergeant checkout.
#
# sgt-install and sgt-uninstall write to their own checkout's git hooks
# directory, so behavioural suites must drive a copy rather than the developer's
# checkout: driving the real one installs and then deletes the developer's
# pre-push hook as a side effect of running the tests.
#
# The copy mirrors the whole distribution instead of an enumerated list of
# directories. Enumerating is the defect this install work exists to remove:
# commands load bundled resources outside bin/ (sgt-dispatch requires
# templates/worker-brief.md), so a hand-listed fixture starts failing the moment
# the distribution grows a resource, for a reason unrelated to installing.
#
# Only genuinely non-distribution entries are excluded, so a new top-level
# resource needs no edit here. git and python3 are deliberately not used: this
# helper also runs inside the pinned bash:3.2 image, which ships neither.

# sgt_test_copy_checkout <source-root> <destination-root>
#
# Copies the working-tree contents of <source-root> into <destination-root>,
# which is created if absent. Working-tree contents, not committed contents, so
# a suite tests the checkout it was invoked from.
sgt_test_copy_checkout() {
  local root="$1" dest="$2" entry name

  mkdir -p "$dest"
  for entry in "$root"/* "$root"/.[!.]*; do
    [[ -e "$entry" ]] || continue
    name="${entry##*/}"
    case "$name" in
      # Version control, build output, and local task/agent state. A fixture
      # must not inherit the outer checkout's git identity, and .sergeant-*
      # would make the copy look like a live Sergeant worker worktree.
      .git | .gitmodules | .todos | .no-mistakes | dist | graphify-out | \
        node_modules | .sergeant-*)
        continue
        ;;
    esac
    cp -R "$entry" "$dest/$name"
  done
}
