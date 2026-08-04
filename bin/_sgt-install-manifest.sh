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
  (cd "$dir/.." && pwd)
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
  printf '%s\n' 'sgt-*' '_sgt-*.sh' 'wiki-daily-digest'
}

# _sgt_is_sergeant_checkout_path <path>
#
# True when <path> looks like a file inside some Sergeant checkout's bin
# directory, proven by that directory also holding a Sergeant runtime helper.
# Used to decide whether an existing link belongs to Sergeant (safe to repoint)
# or to the user (must be preserved).
#
# _sgt-lib.sh is included because it predates this manifest: a checkout made
# before the manifest existed must still be recognised as Sergeant's, or an
# upgrade would report ~38 of Sergeant's own links to the user as their assets.
_sgt_is_sergeant_checkout_path() {
  local candidate="$1" candidate_dir marker
  case "$candidate" in
    */bin/*) candidate_dir="${candidate%/*}" ;;
    *) return 1 ;;
  esac
  for marker in _sgt-install-manifest.sh _sgt-lib.sh; do
    [[ -f "$candidate_dir/$marker" ]] && return 0
  done
  return 1
}

# _sgt_install_is_sergeant_hook <hook-target>
#
# True when <hook-target> is a hook belonging to some Sergeant checkout, proven
# by a Sergeant runtime helper next to that checkout's scripts/hooks directory.
# Linked worktrees share one hooks directory with their primary checkout, so a
# hook installed by a sibling checkout is Sergeant's to repoint, not a user
# asset to preserve.
_sgt_install_is_sergeant_hook() {
  local candidate="$1" checkout marker
  case "$candidate" in
    */scripts/hooks/*) checkout="${candidate%/scripts/hooks/*}" ;;
    *) return 1 ;;
  esac
  for marker in _sgt-install-manifest.sh _sgt-lib.sh; do
    [[ -f "$checkout/bin/$marker" ]] && return 0
  done
  return 1
}

# _sgt_install_resolve_link <target>
#
# Print what <target> points at, as an absolute path. A relative link target is
# resolved against the directory holding the link, never against the caller's
# working directory.
_sgt_install_resolve_link() {
  local target="$1" link_target target_dir
  link_target="$(readlink "$target")"
  case "$link_target" in
    /*) printf '%s\n' "$link_target" ;;
    *)
      case "$target" in
        */*) target_dir="${target%/*}" ;;
        *) target_dir='.' ;;
      esac
      printf '%s\n' "$target_dir/$link_target"
      ;;
  esac
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
  local source_file="$1" target_dir="$2" target link_target
  target="$target_dir/${source_file##*/}"

  if [[ -L "$target" ]]; then
    link_target="$(_sgt_install_resolve_link "$target")"
    if [[ "$link_target" == "$source_file" ]]; then
      printf 'linked\n'
    elif [[ ! -e "$link_target" ]]; then
      # A broken link is not a user asset; reclaim it.
      printf 'stale\n'
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
# Classify what occupies a managed executable's path, printing one of:
#
#   absent    nothing there; safe to install
#   reclaim   a dangling link, or a link into a tool tree matching
#             <owned-substring>; safe to replace in place
#   conflict  anything the user owns; preserve and report
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
    else
      printf 'conflict\n'
    fi
  elif [[ -e "$target" ]]; then
    printf 'conflict\n'
  else
    printf 'absent\n'
  fi
}

# _sgt_install_hooks_dir <repo-root>
#
# Print the hooks directory git actually consults for <repo-root>, honouring
# core.hooksPath and resolving a linked worktree to the common git directory
# (a worktree's private git dir has no hooks/ and git never reads one there).
_sgt_install_hooks_dir() {
  local root="$1" configured common
  if configured="$(git -C "$root" config --path --get core.hooksPath 2>/dev/null)" && \
     [[ -n "$configured" ]]; then
    case "$configured" in
      /*) printf '%s\n' "$configured" ;;
      *) printf '%s\n' "$root/$configured" ;;
    esac
    return 0
  fi
  common="$(git -C "$root" rev-parse --git-common-dir 2>/dev/null)" || return 1
  [[ -n "$common" ]] || return 1
  case "$common" in
    /*) printf '%s\n' "$common/hooks" ;;
    *) printf '%s\n' "$root/$common/hooks" ;;
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
