#!/usr/bin/env bash
# Tests for issue #201: sgt-dispatch resolves bundled templates through symlinks.
#
# Seams under test:
#   - _sgt_real_dir (in _sgt-lib.sh): symlink-resolving directory function
#   - sgt-dispatch SCRIPT_DIR: resolves to real bin/ dir regardless of symlinks
#   - Templates are accessible through the resolved SCRIPT_DIR

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

SYMLINK_BIN="$TEST_ROOT/installed-bin"
NESTED_BIN="$TEST_ROOT/nested-bin"
mkdir -p "$SYMLINK_BIN" "$NESTED_BIN"

# Symlink the entire bin/ tree into installed-bin (simulates 'make install').
for _script in "$ROOT_DIR/bin"/sgt-* "$ROOT_DIR/bin"/_sgt-*.sh; do
  [[ -f "$_script" ]] || continue
  ln -sf "$_script" "$SYMLINK_BIN/$(basename "$_script")"
done

# Nested symlink: symlink → symlink → real file.
ln -sf "$SYMLINK_BIN/sgt-dispatch" "$NESTED_BIN/sgt-dispatch"

PASS=0
FAIL=0

_pass() { PASS=$(( PASS + 1 )); printf 'PASS: %s\n' "$1"; }
_fail() { FAIL=$(( FAIL + 1 )); printf 'FAIL: %s\n' "$1" >&2; }

# Source only _sgt-lib.sh to get _sgt_real_dir, then use it as the resolver.
# This tests the function that every script now delegates to.
_probe_real_dir() {
  local target_script="$1"
  bash -c "
    source '$ROOT_DIR/bin/_sgt-lib.sh' 2>/dev/null
    _sgt_real_dir '$target_script'
  "
}

# ── Test 1: direct invocation resolves correctly ─────────────────────────────
result_direct="$(_probe_real_dir "$ROOT_DIR/bin/sgt-dispatch")"
if [[ "$result_direct" == "$ROOT_DIR/bin" ]]; then
  _pass "direct invocation: _sgt_real_dir resolves to real bin/"
else
  _fail "direct invocation: got '$result_direct', want '$ROOT_DIR/bin'"
fi

# ── Test 2: single symlink resolves to real bin/ ─────────────────────────────
result_symlink="$(_probe_real_dir "$SYMLINK_BIN/sgt-dispatch")"
if [[ "$result_symlink" == "$ROOT_DIR/bin" ]]; then
  _pass "single symlink: _sgt_real_dir resolves to real bin/"
else
  _fail "single symlink: got '$result_symlink', want '$ROOT_DIR/bin'"
fi

# ── Test 3: nested symlink (symlink → symlink) resolves correctly ─────────────
result_nested="$(_probe_real_dir "$NESTED_BIN/sgt-dispatch")"
if [[ "$result_nested" == "$ROOT_DIR/bin" ]]; then
  _pass "nested symlink (2-hop): _sgt_real_dir resolves to real bin/"
else
  _fail "nested symlink: got '$result_nested', want '$ROOT_DIR/bin'"
fi

# ── Test 4: worker-brief.md template is reachable from resolved SCRIPT_DIR ───
template_path="$result_symlink/../templates/worker-brief.md"
if [[ -f "$template_path" ]]; then
  _pass "worker-brief.md is reachable via symlink-resolved SCRIPT_DIR"
else
  _fail "worker-brief.md not found at '$template_path'"
fi

# ── Test 5: non-symlink path returns the same directory ──────────────────────
result_plain="$(_probe_real_dir "$ROOT_DIR/bin/_sgt-lib.sh")"
if [[ "$result_plain" == "$ROOT_DIR/bin" ]]; then
  _pass "non-symlink path: _sgt_real_dir returns correct directory unchanged"
else
  _fail "non-symlink path: got '$result_plain', want '$ROOT_DIR/bin'"
fi

# ── Test 6: all sgt-* scripts in SCRIPT_DIR use _sgt_real_dir or equivalent ──
# Every public script with SCRIPT_DIR= must resolve through symlinks (issue #201).
# We verify sgt-dispatch specifically — it was the reporter case.
bad_scripts=()
for _script in "$ROOT_DIR/bin"/sgt-dispatch "$ROOT_DIR/bin"/sgt-wake \
               "$ROOT_DIR/bin"/sgt-watch "$ROOT_DIR/bin"/sgt-recover \
               "$ROOT_DIR/bin"/sgt-respond "$ROOT_DIR/bin"/sgt-review-findings; do
  [[ -f "$_script" ]] || continue
  if grep -q 'SCRIPT_DIR=' "$_script"; then
    # Must not use the old bare pattern (which doesn't follow symlinks):
    #   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if grep -qE '^SCRIPT_DIR=.*BASH_SOURCE.*pwd[^-]' "$_script"; then
      bad_scripts+=("$(basename "$_script")")
    fi
  fi
done
if [[ ${#bad_scripts[@]} -eq 0 ]]; then
  _pass "no public scripts use the non-symlink-resolving SCRIPT_DIR pattern"
else
  _fail "scripts still use old non-resolving SCRIPT_DIR: ${bad_scripts[*]}"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
