#!/usr/bin/env bash
# _sgt-install-manifest.sh — The single source of truth for what a Sergeant
# checkout installs into a user's PATH.
#
# Source this file; do not execute it directly.
#
# Consumed by bin/sgt-install (which creates the links) and bin/sgt-bootstrap
# (which plans and verifies them). Keeping one manifest prevents the two
# commands from drifting apart as bin/ gains commands and runtime helpers.
#
# Policy (docs/repo-scoped-skills.md): no install step writes to a user's
# global agent configuration. Nothing here may target ~/.config/opencode,
# ~/.claude, or ~/.agents except to remove a deprecated link this checkout
# previously created.

[[ "${SGT_INSTALL_MANIFEST_LOADED:-}" == "1" ]] && return 0
SGT_INSTALL_MANIFEST_LOADED=1

# _sgt_install_script_root <script-path>
#
# Print the repository root that owns <script-path>, following symlinks so that
# a command invoked through ~/.local/bin still resolves to its checkout.
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
# installs into the target directory: the sgt-* commands, the _sgt-*.sh runtime
# helpers they source, and wiki-daily-digest.
#
# Globbing the helpers rather than naming them keeps a new runtime helper from
# silently breaking every installed command.
_sgt_install_sources() {
  local root="$1" source_file
  for source_file in "$root"/bin/sgt-* "$root"/bin/_sgt-*.sh "$root/bin/wiki-daily-digest"; do
    [[ -f "$source_file" ]] || continue
    printf '%s\n' "$source_file"
  done
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
