#!/usr/bin/env bash
# Regression for GH #228: the worker launch command must not depend on the tmux
# pane's default-shell being bash.
#
# Seam under test: the string returned by _sgt_process_marker_command, executed
# the way tmux executes it -- `<default-shell> -c "<command>"`.  tmux runs a
# new-window command through the pane's shell, which follows tmux's
# `default-shell` option and therefore the user's $SHELL.  On macOS that is
# /bin/zsh by default (since Catalina), so a bash-only construct here kills every
# dispatched worker before sgt-interactive-worker ever starts.
#
# The failure this pins: the command used bash's numbered-fd redirect
#
#     exec 198<'/path/to/marker' && rm -f '/path/to/marker' && exec <worker> ...
#
# zsh parses the bare `198` in that position as a command name:
#
#     $ zsh -c 'exec 198</tmp/f && echo ok'
#     zsh: command not found: 198
#
# The pane died instantly, before `rm -f` ran, and sgt-dispatch surfaced only a
# generic notification-acknowledgement timeout ~60s later.  Note zsh's
# `exec {198}<file` is NOT a drop-in replacement: zsh auto-assigns an available
# fd and reports it in the named parameter rather than forcing 198, which breaks
# the `fd == 198` provenance contract in _sgt_process_marker_command.
#
# What must hold, for every shell a user could plausibly have as default-shell:
#   1. the command runs successfully;
#   2. fd 198 reaches the worker, still open and readable;
#   3. it carries the marker generation, proving provenance survived the exec;
#   4. the marker file is unlinked (a surviving marker is the tell for a failed
#      launch, per the issue);
#   5. the worker's arguments arrive intact.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# Declared isolation: this suite sources bin/_sgt-lib.sh, which resolves drain and
# fleet roots, so pin them even though nothing here mutates real state.
export SERGEANT_CONFIG="$TEST_ROOT/config"
export SERGEANT_DRAIN_DIR="$TEST_ROOT/drain"
export SERGEANT_FLEET="$TEST_ROOT/fleet"
export TMUX_TMPDIR="$TEST_ROOT/tmux"
mkdir -p "$SERGEANT_CONFIG" "$SERGEANT_DRAIN_DIR" "$SERGEANT_FLEET" "$TMUX_TMPDIR"

# shellcheck source=bin/_sgt-lib.sh
source "$ROOT_DIR/bin/_sgt-lib.sh"

state="$TEST_ROOT/state"
out_dir="$TEST_ROOT/out"
mkdir -p "$state" "$out_dir"

marker_path="$state/.marker.fixture"
marker_generation="$(printf '%032x' "$RANDOM")"

_seed_marker() {
  # Recreated before every shell: the command under test unlinks it on success,
  # and the path is baked into the command, so each run needs it back in place.
  # Unlink first -- the previous seed is mode 400, so a plain truncate would fail.
  rm -f "$marker_path"
  printf '%s\n' "$marker_generation" > "$marker_path"
  chmod 400 "$marker_path"
  local identity
  identity="$(stat -Lc '%d:%i' "$marker_path" 2>/dev/null \
    || stat -Lf '%d:%i' "$marker_path")"
  printf '%s|%s|198|%s\n' "$marker_generation" "$identity" "$marker_path" \
    > "$state/worker_process_marker"
  chmod 600 "$state/worker_process_marker"
}

# Stands in for sgt-interactive-worker.  Observes only the public contract: fd 198
# inherited and readable, and argv intact.
cat > "$TEST_ROOT/worker" <<'WORKER'
#!/usr/bin/env bash
set -u
if ! content="$(cat <&198 2>/dev/null)"; then
  printf 'worker: fd 198 was not inherited or not readable\n' >&2
  exit 3
fi
printf '%s' "$content" > "$OUT_DIR/fd198"
printf '%s\n' "$@" > "$OUT_DIR/args"
WORKER
chmod +x "$TEST_ROOT/worker"

_seed_marker
command="$(_sgt_process_marker_command "$state" "$TEST_ROOT/worker" argA 'arg with space')" || {
  printf 'FAIL: _sgt_process_marker_command rejected a valid marker fixture\n' >&2
  exit 1
}
[[ -n "$command" ]] || { printf 'FAIL: empty launch command\n' >&2; exit 1; }

failures=0
checked=0

# Shells a user could plausibly have as tmux default-shell.  zsh is the macOS
# default and the reported failure; sh/dash cover POSIX-only parsing.
for shell_name in bash zsh sh dash; do
  shell_path="$(command -v "$shell_name" 2>/dev/null || true)"
  if [[ -z "$shell_path" ]]; then
    printf '  %-5s skipped (not installed)\n' "$shell_name"
    continue
  fi
  checked=$((checked + 1))

  rm -f "$out_dir/fd198" "$out_dir/args"
  _seed_marker

  if ! OUT_DIR="$out_dir" "$shell_path" -c "$command" >"$TEST_ROOT/$shell_name.out" 2>&1; then
    printf '  %-5s FAIL: launch command did not run\n' "$shell_name"
    sed 's/^/        /' "$TEST_ROOT/$shell_name.out" >&2
    failures=$((failures + 1))
    continue
  fi

  if [[ "$(cat "$out_dir/fd198" 2>/dev/null || true)" != "$marker_generation" ]]; then
    printf '  %-5s FAIL: fd 198 did not carry the marker generation (got %q)\n' \
      "$shell_name" "$(cat "$out_dir/fd198" 2>/dev/null || true)"
    failures=$((failures + 1))
    continue
  fi

  if [[ -e "$marker_path" ]]; then
    printf '  %-5s FAIL: marker file survived a successful launch\n' "$shell_name"
    failures=$((failures + 1))
    continue
  fi

  if [[ "$(cat "$out_dir/args" 2>/dev/null || true)" != "argA
arg with space" ]]; then
    printf '  %-5s FAIL: worker arguments were mangled (got %q)\n' \
      "$shell_name" "$(cat "$out_dir/args" 2>/dev/null || true)"
    failures=$((failures + 1))
    continue
  fi

  printf '  %-5s ok\n' "$shell_name"
done

(( checked > 0 )) || {
  printf 'FAIL: no candidate shell was available to test\n' >&2
  exit 1
}

# bash alone passing is the pre-fix state and must not read as success.
command -v zsh >/dev/null 2>&1 || {
  printf 'FAIL: zsh is required to prove GH #228; install it in the test image\n' >&2
  exit 1
}

(( failures == 0 )) || {
  printf 'FAIL: worker launch command is shell-dependent (%d shell(s) failed)\n' \
    "$failures" >&2
  exit 1
}

printf 'worker launch command shell portability: ok (%d shells)\n' "$checked"
