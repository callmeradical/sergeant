#!/usr/bin/env bash
# _sgt-install-manifest.sh — The single source of truth for what a Sergeant
# checkout installs, and for whether a path may be repointed or must be
# preserved.
#
# Source this file; do not execute it directly.
#
# Consumed by bin/sgt-install (creates the links), bin/sgt-uninstall (removes
# them) and bin/sgt-bootstrap (plans and verifies them). One manifest and one
# classification function keep those three from drifting apart, so a plan can
# never predict an action the installer will not take.
#
# Policy (docs/repo-scoped-skills.md): no install step writes to a user's global
# agent configuration. Nothing here may target ~/.config/opencode, ~/.claude, or
# ~/.agents except to remove a deprecated link this checkout previously created.

[[ "${SGT_INSTALL_MANIFEST_LOADED:-}" == "1" ]] && return 0
SGT_INSTALL_MANIFEST_LOADED=1

# _sgt_install_target_dir
#
# Print the directory that receives this checkout's command links. Kept here so
# the three commands cannot disagree about the default.
_sgt_install_target_dir() {
  local target="${SGT_INSTALL_DIR:-$HOME/.local/bin}"
  # A relative value resolves against each caller's working directory, and
  # sgt-bootstrap runs `mise run install` from the checkout, so the two would
  # write to different places and litter the repository.
  case "$target" in
    /*) printf '%s\n' "$target" ;;
    *)
      printf '_sgt-install-manifest: SGT_INSTALL_DIR must be an absolute path, got %s\n' \
        "$target" >&2
      return 2
      ;;
  esac
}

# _sgt_install_script_root <script-path>
#
# Print the repository root that owns <script-path>, following symlinks so that
# a command invoked through ~/.local/bin still resolves to its checkout rather
# than to the install directory's parent.
# Bash 3.2 safe: no `readlink -f`, no `realpath`, no external `dirname`.
_sgt_install_script_root() {
  local script="$1" link dir hops=0
  while [[ -L "$script" ]]; do
    hops=$((hops + 1))
    if ((hops > 40)); then
      printf '_sgt-install-manifest: symlink loop while resolving %s\n' "$1" >&2
      return 1
    fi
    link="$(readlink "$script")"
    case "$link" in
      /*) script="$link" ;;
      *)
        case "$script" in
          */*) script="${script%/*}/$link" ;;
          *) script="$link" ;;
        esac
        ;;
    esac
  done
  case "$script" in
    */*) dir="${script%/*}" ;;
    *) dir='.' ;;
  esac
  # Physical, to match _sgt_install_resolve_link so a checkout reached through a
  # symlink still compares equal to a link resolved from the target directory.
  (cd -P "$dir/.." && pwd -P)
}

# _sgt_install_sources <repo-root>
#
# Print, one per line, every regular file in <repo-root>/bin that this checkout
# installs: the sgt-* commands, the _sgt-*.sh runtime helpers they source, and
# wiki-daily-digest. Globbing the helpers rather than naming them keeps a new
# runtime helper from being linked by one command and missed by another.
#
# Returns non-zero when the root yields nothing. A silently empty manifest would
# let a caller report a complete installation having examined no commands at all.
_sgt_install_sources() {
  local root="$1" source_file count=0
  for source_file in "$root"/bin/sgt-* "$root"/bin/_sgt-*.sh "$root/bin/wiki-daily-digest"; do
    [[ -f "$source_file" ]] || continue
    printf '%s\n' "$source_file"
    count=$((count + 1))
  done
  if ((count == 0)); then
    printf '_sgt-install-manifest: no installable commands found under %s/bin\n' "$root" >&2
    return 1
  fi
}

# _sgt_install_managed_globs
#
# Print the filename patterns this checkout claims inside the target directory.
# Used to sweep links left behind by commands that a later version renamed or
# removed, which the manifest no longer names.
_sgt_install_managed_globs() {
  # Both staged-name shapes are claimed so a leftover from an interrupted publish
  # is always reclaimable, including one written by an earlier version.
  printf '%s\n' 'sgt-*' '_sgt-*.sh' 'wiki-daily-digest' 'sgt-publish.*' '*.sgt-publish.*'
}

# _sgt_is_sergeant_checkout_root <dir>
#
# True when <dir> is a Sergeant checkout: it carries the repository's mise.toml
# alongside a Sergeant runtime helper in bin/.
#
# scripts/hooks is deliberately NOT part of the test. It first appeared well into
# the repository's history, so requiring it would stop recognising exactly the
# older checkouts the _sgt-lib.sh marker below exists for.
#
# _sgt-lib.sh is accepted as well as this manifest because it predates the
# manifest: a checkout made before the manifest existed must still be recognised
# as Sergeant's, or an upgrade would report ~38 of Sergeant's own links to the
# user as their assets.
_sgt_is_sergeant_checkout_root() {
  local root="$1" marker
  # mise.toml is what separates a checkout from a command directory: sgt-install
  # links its helpers into the latter, so a marker in bin/ alone would let the
  # install directory identify itself as a checkout.
  [[ -f "$root/mise.toml" ]] || return 1
  for marker in _sgt-install-manifest.sh _sgt-lib.sh; do
    [[ -f "$root/bin/$marker" ]] && return 0
  done
  return 1
}

# _sgt_is_sergeant_checkout_path <path>
#
# True when <path> is a file inside some Sergeant checkout's bin directory.
#
# The whole checkout must be identifiable, not just the directory holding the
# file: sgt-install links its own runtime helpers into the target directory, so a
# per-directory marker would make the install directory identify itself as a
# checkout and every user symlink resolving inside it would look like Sergeant's
# to reclaim.
_sgt_is_sergeant_checkout_path() {
  local candidate="$1" root
  case "$candidate" in
    */bin/*) root="${candidate%/bin/*}" ;;
    *) return 1 ;;
  esac
  _sgt_is_sergeant_checkout_root "$root"
}

# _sgt_install_is_sergeant_hook <hook-target>
#
# True when <hook-target> is a hook belonging to some Sergeant checkout, proven
# by a Sergeant runtime helper next to that checkout's scripts/hooks directory.
# Linked worktrees share one hooks directory with their primary checkout, so a
# hook installed by a sibling checkout is Sergeant's to repoint, not a user
# asset to preserve.
_sgt_install_is_sergeant_hook() {
  local candidate="$1" checkout
  case "$candidate" in
    */scripts/hooks/*) checkout="${candidate%/scripts/hooks/*}" ;;
    *) return 1 ;;
  esac
  _sgt_is_sergeant_checkout_root "$checkout"
}

# _sgt_install_is_sergeant_hook_path <path>
#
# True when <path> merely looks like a Sergeant hook by position, whether or not
# the checkout still exists. Used to reclaim a hook left dangling by a removed
# checkout, which git silently ignores — leaving the pre-push gate inert.
_sgt_install_is_sergeant_hook_path() {
  case "$1" in
    */scripts/hooks/*) return 0 ;;
    *) return 1 ;;
  esac
}

# _sgt_install_resolve_link <target>
#
# Print what <target> points at, as an absolute path with any `..` and `.`
# segments collapsed. A relative link target is resolved against the directory
# holding the link, never against the caller's working directory, and the result
# is normalised so callers can compare it as a plain string.
_sgt_install_resolve_link() {
  local target="$1" link_target target_dir resolved base dir
  link_target="$(readlink "$target")"
  case "$link_target" in
    /*) resolved="$link_target" ;;
    *)
      case "$target" in
        */*) target_dir="${target%/*}" ;;
        *) target_dir='.' ;;
      esac
      resolved="$target_dir/$link_target"
      ;;
  esac
  # Resolve the directory part physically so the result matches what the kernel
  # would follow: `cd`/`pwd` default to logical mode, which collapses `..`
  # lexically and leaves a symlinked parent component unresolved, producing a
  # path that never existed. A dangling link keeps its literal form, which
  # callers treat as broken either way.
  base="${resolved##*/}"
  case "$resolved" in
    */*) dir="${resolved%/*}" ;;
    *) dir='.' ;;
  esac
  if [[ -d "$dir" ]]; then
    resolved="$(cd -P "$dir" && pwd -P)/$base"
  fi
  printf '%s\n' "$resolved"
}

# _sgt_install_link_state <source-file> <target-dir>
#
# Classify what occupies <target-dir>/<basename of source-file>, printing one of:
#
#   linked    already an exact link to this checkout; nothing to do
#   absent    nothing occupies the path; safe to create
#   stale     a Sergeant-owned or dangling link; safe to replace in place
#   conflict  a real file, a directory, or a link to something a user owns;
#             must be preserved and reported
#
# Both the planner and the installer call this, so `--dry-run` cannot promise an
# action that `sgt-install` then refuses, or vice versa.
_sgt_install_link_state() {
  local source_file="$1" target_dir="$2" target link_target resolved_dir
  # Resolved physically and stripped of a trailing slash so the sibling test
  # below compares like with like: link targets are resolved physically, and a
  # command directory reached through a symlink would otherwise never match.
  target_dir="${target_dir%/}"
  # An unreadable directory keeps its original spelling rather than collapsing to
  # the empty string and classifying against /.
  if resolved_dir="$(cd -P "$target_dir" 2>/dev/null && pwd -P)"; then
    target_dir="$resolved_dir"
  fi
  target="$target_dir/${source_file##*/}"

  if [[ -L "$target" ]]; then
    link_target="$(_sgt_install_resolve_link "$target")"
    if [[ "$link_target" == "$source_file" ]]; then
      printf 'linked\n'
    elif [[ ! -e "$link_target" ]]; then
      # A broken link is not a user asset; reclaim it.
      printf 'stale\n'
    elif [[ "${link_target%/*}" == "$target_dir" ]]; then
      # A link resolving to a sibling in the command directory is the user's own
      # arrangement, whatever that directory's parent looks like.
      printf 'conflict\n'
    elif [[ -f "$link_target" ]] && _sgt_is_sergeant_checkout_path "$link_target"; then
      printf 'stale\n'
    else
      printf 'conflict\n'
    fi
  elif [[ -e "$target" ]]; then
    printf 'conflict\n'
  else
    printf 'absent\n'
  fi
}

# _sgt_install_managed_state <target> <owned-substring>
#
# Classify what occupies the path of an executable this command installs,
# printing one of:
#
#   present   an executable already occupies the name; the installer owns this
#             name in the directory it manages and may replace its own binary
#   absent    nothing there; safe to install
#   reclaim   a dangling link, or a link into a tool tree matching
#             <owned-substring>; safe to replace in place
#   conflict  something that is not a runnable tool — a non-executable file, a
#             directory, or a link to one — so it is the user's and is preserved
#
# `present` matters for rerun safety: `go install` and `uv tool install` write
# real files into the install directory, so a second run must recognise its own
# output instead of reporting it to the user as their conflict. A non-executable
# file at one of these names is not a tool and is always preserved.
#
# Shares _sgt_install_resolve_link with _sgt_install_link_state so a relative
# user-owned link is never mistaken for a reclaimable one.
_sgt_install_managed_state() {
  local target="$1" owned_substring="$2" link_target
  if [[ -L "$target" ]]; then
    link_target="$(_sgt_install_resolve_link "$target")"
    if [[ ! -e "$link_target" ]]; then
      printf 'reclaim\n'
    elif [[ "$link_target" == *"$owned_substring"* ]]; then
      printf 'reclaim\n'
    elif [[ -f "$link_target" && -x "$link_target" ]]; then
      printf 'present\n'
    else
      printf 'conflict\n'
    fi
  elif [[ -f "$target" && -x "$target" ]]; then
    printf 'present\n'
  elif [[ -e "$target" ]]; then
    printf 'conflict\n'
  else
    printf 'absent\n'
  fi
}

# _sgt_install_hooks_dir <repo-root>
#
# Print the hooks directory git consults for <repo-root>, resolving a linked
# worktree to the common git directory (a worktree's private git dir has no
# hooks/ and git never reads one there).
#
# core.hooksPath is honoured only when it is set in THIS repository's config and
# resolves inside the checkout. A global or system hooksPath belongs to every
# repository on the machine: writing Sergeant's pre-push hook there would make
# every unrelated `git push` run Sergeant's Docker drain suite. In that case the
# repository's own hooks directory is not the one git will read, so this returns
# non-zero and the caller reports that hooks were not installed.
# _sgt_install_hooks_refusal_advice <repo-root>
#
# Print the remediation for why _sgt_install_hooks_dir refused <repo-root>.
#
# The cause is re-derived rather than remembered: every caller resolves the hooks
# directory in a command substitution, so a variable set inside the resolver
# would never reach the parent shell and the advice would always be generic.
_sgt_install_hooks_refusal_advice() {
  local root="$1" private primary
  private="$(git -C "$root" rev-parse --absolute-git-dir 2>/dev/null || true)"
  if [[ -n "$private" && -f "$private/commondir" ]]; then
    primary="$(_sgt_install_primary_checkout "$root")"
    printf 'this is a linked worktree, which shares its primary checkout hooks directory; install hooks from the primary checkout%s\n' \
      "${primary:+ at $primary}"
    return 0
  fi
  if git -C "$root" config --path --get core.hooksPath >/dev/null 2>&1; then
    printf 'core.hooksPath redirects git away from this repository; unset it for this repository to install hooks here\n'
    return 0
  fi
  printf 'no git hooks directory could be resolved for %s\n' "$root"
}

# _sgt_install_primary_checkout <repo-root>
#
# Print the working tree that owns the shared git directory of <repo-root>, or
# nothing when it cannot be determined.
_sgt_install_primary_checkout() {
  local root="$1" common
  common="$(git -C "$root" rev-parse --git-common-dir 2>/dev/null || true)"
  [[ -n "$common" ]] || return 0
  case "$common" in
    /*) ;;
    *) common="$root/$common" ;;
  esac
  [[ -d "$common" ]] || return 0
  common="$(cd -P "$common" && pwd -P)"
  printf '%s\n' "${common%/.git}"
}

_sgt_install_hooks_dir() {
  local root="$1" configured resolved common private
  # A linked worktree shares the primary checkout's hooks directory. Writing
  # there would repoint the primary's hook at the worktree, and once the worktree
  # is removed git silently skips the dangling hook, leaving the gate inert.
  #
  # Detected structurally: a linked worktree's private git dir holds a
  # `commondir` file. Comparing path strings instead would misread a normal clone
  # whose .git is a symlink, because git resolves --absolute-git-dir but not the
  # composed --git-common-dir.
  private="$(git -C "$root" rev-parse --absolute-git-dir 2>/dev/null || true)"
  if [[ -n "$private" && -f "$private/commondir" ]]; then
    return 1
  fi
  if configured="$(git -C "$root" config --local --path --get core.hooksPath 2>/dev/null)" && \
     [[ -n "$configured" ]]; then
    case "$configured" in
      /*) resolved="$configured" ;;
      *) resolved="$root/$configured" ;;
    esac
    case "$resolved" in
      "$root"/*) printf '%s\n' "$resolved"; return 0 ;;
      *) return 1 ;;
    esac
  fi
  # A hooksPath from any wider scope redirects git away from this repository's
  # hooks directory, so there is nothing here that Sergeant may own.
  if configured="$(git -C "$root" config --path --get core.hooksPath 2>/dev/null)" && \
     [[ -n "$configured" ]]; then
    return 1
  fi
  common="$(git -C "$root" rev-parse --git-common-dir 2>/dev/null)" || return 1
  [[ -n "$common" ]] || return 1
  case "$common" in
    /*) printf '%s\n' "$common/hooks" ;;
    *) printf '%s\n' "$root/$common/hooks" ;;
  esac
}

# _sgt_install_hook_state <hook-source> <hooks-dir>
#
# Classify what occupies this hook's path, printing linked, absent, stale, or
# conflict with the same ownership rule as command links: a hook installed by
# another Sergeant checkout, or a broken link, is Sergeant's to repoint, while a
# hook the user wrote is preserved. Shared with the bootstrap so a conflict is
# reported before any package is installed rather than after.
_sgt_install_hook_state() {
  local hook="$1" hooks_dir="$2" target link_target
  target="$hooks_dir/${hook##*/}"
  if [[ -L "$target" ]]; then
    link_target="$(_sgt_install_resolve_link "$target")"
    if [[ "$link_target" == "$hook" ]]; then
      printf 'linked\n'
    elif [[ ! -e "$link_target" ]] || \
         { [[ -f "$link_target" ]] && _sgt_install_is_sergeant_hook "$link_target"; }; then
      printf 'stale\n'
    else
      printf 'conflict\n'
    fi
  elif [[ -e "$target" ]]; then
    printf 'conflict\n'
  else
    printf 'absent\n'
  fi
}

# _sgt_install_link_points_into <link> <repo-root>
#
# True when <link> is a symlink resolving to a path inside <repo-root>/bin.
# The single ownership test used by the stale sweep in both sgt-install and
# sgt-uninstall, so a relative link is treated identically by each.
_sgt_install_link_points_into() {
  local link="$1" root="$2" resolved
  [[ -L "$link" ]] || return 1
  resolved="$(_sgt_install_resolve_link "$link")"
  case "$resolved" in
    "$root"/bin/*) return 0 ;;
    *) return 1 ;;
  esac
}

# _sgt_command_available <command>
#
# True when <command> resolves on PATH to something actually executable.
# `command -v` alone reports success for a non-executable file on PATH, which
# would make a broken or placeholder tool look installed.
_sgt_command_available() {
  local resolved
  resolved="$(type -P "$1" 2>/dev/null)" || return 1
  [[ -n "$resolved" && -x "$resolved" ]]
}

# _sgt_install_owned_deprecated_links <repo-root> <target-dir>
#
# Print, one per line, only the deprecated links this checkout actually owns:
# a symlink still pointing at the recorded path inside <repo-root>. Both
# sgt-install and sgt-uninstall consume this, so the ownership rule lives here
# with the other classifiers rather than being restated at each call site.
_sgt_install_owned_deprecated_links() {
  local root="$1" target_dir="$2" entry link owned
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    link="${entry%%::*}"
    owned="${entry##*::}"
    [[ -L "$link" ]] || continue
    [[ "$(_sgt_install_resolve_link "$link")" == "$owned" ]] || continue
    printf '%s\n' "$link"
  done <<EOF
$(_sgt_install_deprecated_links "$root" "$target_dir")
EOF
}

# _sgt_install_deprecated_links <repo-root> <target-dir>
#
# Print, one per line, `<link-path>::<owned-target>` pairs for links that older
# Sergeant checkouts created and that this checkout must remove. A link is only
# removed when it still points at the recorded path inside <repo-root>, so a
# user's own unrelated command of the same name is never deleted.
_sgt_install_deprecated_links() {
  local root="$1" target_dir="$2"
  printf '%s::%s\n' "$target_dir/oc-inject" "$root/bin/oc-inject"
  printf '%s::%s\n' "$HOME/.config/opencode/plugins/oc-inject.js" \
    "$root/opencode/plugins/oc-inject.js"
}
