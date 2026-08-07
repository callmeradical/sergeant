#!/usr/bin/env bash
# Tests that scripts/hooks/pre-push validates the worktree being pushed.
#
# Seam under test:
#   scripts/hooks/pre-push   ->   mise run --cd <REPO_DIR> test:docker:drain
#
# The hook is installed as .git/hooks/pre-push, a symlink into the main
# checkout's scripts/ directory. A git worktree shares that hooks directory, so
# resolving the repository from the hook script's own location always yields the
# MAIN checkout no matter which worktree is being pushed.
#
# That makes the gate report on a tree nobody is pushing: it can pass while
# broken code ships, and fail while a fix ships. The hook must resolve the
# worktree git is pushing from instead.
#
# Method: stub `mise` on PATH so it records the --cd argument instead of running
# Docker, invoke the hook the way git does (cwd = the worktree root), and assert
# which tree it selected.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT_DIR/scripts/hooks/pre-push"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

pass=0
fail=0
_pass() { printf '  ok: %s\n' "$*"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n' "$*" >&2; fail=$((fail + 1)); }

# ── Stubs: record the invocation rather than running Docker ──────────────────
STUB_BIN="$TEST_ROOT/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/mise" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$TEST_ROOT/mise.args"
exit 0
EOF
cat > "$STUB_BIN/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$STUB_BIN/mise" "$STUB_BIN/docker"

# ── Fixture: a main checkout with a linked worktree, mirroring the real layout ─
MAIN="$TEST_ROOT/main"
mkdir -p "$MAIN"
git -C "$MAIN" init -q -b main
git -C "$MAIN" -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed
mkdir -p "$MAIN/scripts/hooks"
cp "$HOOK" "$MAIN/scripts/hooks/pre-push"
chmod +x "$MAIN/scripts/hooks/pre-push"

LINKED="$TEST_ROOT/linked-worktree"
git -C "$MAIN" worktree add -q -b feature "$LINKED"

# Install the hook exactly as `mise run install` does: a symlink from the shared
# hooks directory into the main checkout's scripts/.
ln -sf "$MAIN/scripts/hooks/pre-push" "$MAIN/.git/hooks/pre-push"

_repo_dir_chosen_from() {
  # git runs pre-push with the working directory set to the root of the
  # worktree being pushed.
  rm -f "$TEST_ROOT/mise.args"
  ( cd "$1" && PATH="$STUB_BIN:$PATH" bash "$MAIN/.git/hooks/pre-push" \
      >/dev/null 2>&1 ) || true
  sed -E 's/.*--cd ([^ ]+).*/\1/' "$TEST_ROOT/mise.args" 2>/dev/null || true
}

# ── Pushing from the main checkout selects the main checkout ─────────────────
got="$(_repo_dir_chosen_from "$MAIN")"
if [[ "$got" == "$MAIN" ]]; then
  _pass "push from the main checkout validates the main checkout"
else
  _fail "push from the main checkout validates the main checkout (chose '$got')"
fi

# ── Pushing from a linked worktree selects THAT worktree ─────────────────────
got="$(_repo_dir_chosen_from "$LINKED")"
if [[ "$got" == "$LINKED" ]]; then
  _pass "push from a linked worktree validates that worktree"
else
  _fail "push from a linked worktree validates that worktree (chose '$got' — the gate would report on a tree nobody is pushing)"
fi

printf '\npre-push hook worktree resolution: %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
