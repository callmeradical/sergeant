#!/usr/bin/env bash
# Regression tests for _sgt_read_owned_file and _sgt_read_same_owned_files.
#
# Background: on macOS (Darwin), opening a file read-only (exec N< path) causes
# fdescfs to report the fd's mode as the access-masked value (e.g. 0400 for a
# file opened O_RDONLY, even when the real file mode is 0600).  The device
# number of /dev/fd/N also differs from the underlying file's device number on
# macOS, which makes bash's `-ef` test unreliable when one operand is a /dev/fd
# path.  The old implementation checked mode and identity via `stat /dev/fd/N`
# and `path -ef /dev/fd/N`; both checks fail on macOS for read-only fds, so
# _sgt_read_owned_file always returned 1 and sgt-validate aborted with
# "Recorded coordinator pane identity is unreadable or unsafely owned".
#
# The fix replaces every /dev/fd-based check with path-based inode:device
# comparisons (_sgt_path_inode_dev), which are correct on both Linux and macOS.
#
# These tests directly exercise the affected functions to catch any regression
# to the /dev/fd approach.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

pass=0
fail=0

_pass() { printf '  ok: %s\n' "$*"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n' "$*" >&2; fail=$((fail + 1)); }

# ── _sgt_read_owned_file ─────────────────────────────────────────────────────

# Basic success: mode-600 file owned by current user.
# This is the macOS regression case: before the fix this always returned 1
# because _sgt_fd_mode /dev/fd/9 returned "400" for a read-only fd on macOS.
f="$TEST_ROOT/owned-600"
printf 'secret-content\n' > "$f"
chmod 600 "$f"
set +e
result=$(bash -c 'source "$1"; _sgt_read_owned_file "$2"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$f")
status=$?
set -e
if [[ "$status" -eq 0 && "$result" == "secret-content" ]]; then
  _pass "_sgt_read_owned_file: mode-600 file returns content (macOS regression)"
else
  _fail "_sgt_read_owned_file: mode-600 file returned status=$status result='$result' (expected 0/'secret-content')"
fi

# Reject mode-644 file.
f="$TEST_ROOT/owned-644"
printf 'data\n' > "$f"
chmod 644 "$f"
set +e
bash -c 'source "$1"; _sgt_read_owned_file "$2"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$f" >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -ne 0 ]]; then
  _pass "_sgt_read_owned_file: mode-644 file rejected"
else
  _fail "_sgt_read_owned_file: mode-644 file should be rejected"
fi

# Reject mode-640 file.
f="$TEST_ROOT/owned-640"
printf 'data\n' > "$f"
chmod 640 "$f"
set +e
bash -c 'source "$1"; _sgt_read_owned_file "$2"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$f" >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -ne 0 ]]; then
  _pass "_sgt_read_owned_file: mode-640 file rejected"
else
  _fail "_sgt_read_owned_file: mode-640 file should be rejected"
fi

# Reject symlink (even if target is mode-600 and owned).
f="$TEST_ROOT/real-600"
printf 'data\n' > "$f"
chmod 600 "$f"
link="$TEST_ROOT/symlink-to-600"
ln -s "$f" "$link"
set +e
bash -c 'source "$1"; _sgt_read_owned_file "$2"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$link" >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -ne 0 ]]; then
  _pass "_sgt_read_owned_file: symlink rejected"
else
  _fail "_sgt_read_owned_file: symlink should be rejected"
fi

# Reject non-existent path.
set +e
bash -c 'source "$1"; _sgt_read_owned_file "$2"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$TEST_ROOT/does-not-exist" >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -ne 0 ]]; then
  _pass "_sgt_read_owned_file: non-existent path rejected"
else
  _fail "_sgt_read_owned_file: non-existent path should be rejected"
fi

# ── _sgt_read_same_owned_files ───────────────────────────────────────────────

# Basic success: hardlinked pair, both mode-600 and same content.
# This is the other macOS regression case: before the fix both `_sgt_fd_mode
# /dev/fd/8|9` and `-ef /dev/fd/8|9` failed for read-only fds on macOS.
f1="$TEST_ROOT/same-first"
printf 'shared-value\n' > "$f1"
chmod 600 "$f1"
f2="$TEST_ROOT/same-second"
ln "$f1" "$f2"
set +e
result=$(bash -c 'source "$1"; _sgt_read_same_owned_files "$2" "$3"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$f1" "$f2")
status=$?
set -e
if [[ "$status" -eq 0 && "$result" == "shared-value" ]]; then
  _pass "_sgt_read_same_owned_files: hardlinked pair returns content (macOS regression)"
else
  _fail "_sgt_read_same_owned_files: returned status=$status result='$result' (expected 0/'shared-value')"
fi

# Reject when files are not hardlinked (different inodes, same content).
f3="$TEST_ROOT/not-linked-a"
f4="$TEST_ROOT/not-linked-b"
printf 'same-value\n' > "$f3"
printf 'same-value\n' > "$f4"
chmod 600 "$f3" "$f4"
set +e
bash -c 'source "$1"; _sgt_read_same_owned_files "$2" "$3"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$f3" "$f4" >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -ne 0 ]]; then
  _pass "_sgt_read_same_owned_files: non-hardlinked pair rejected"
else
  _fail "_sgt_read_same_owned_files: non-hardlinked pair should be rejected"
fi

# Reject when mode is not 600 (chmod on a hardlink changes the shared inode).
f5="$TEST_ROOT/mode-mismatch-base"
printf 'data\n' > "$f5"
chmod 644 "$f5"
f6="$TEST_ROOT/mode-mismatch-link"
ln "$f5" "$f6"
set +e
bash -c 'source "$1"; _sgt_read_same_owned_files "$2" "$3"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$f5" "$f6" >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -ne 0 ]]; then
  _pass "_sgt_read_same_owned_files: non-600-mode hardlink rejected"
else
  _fail "_sgt_read_same_owned_files: non-600-mode hardlink should be rejected"
fi

# Reject when first argument is a symlink.
f7="$TEST_ROOT/base-for-sym"
printf 'data\n' > "$f7"
chmod 600 "$f7"
f7b="$TEST_ROOT/hardlink-of-base"
ln "$f7" "$f7b"
f7sym="$TEST_ROOT/sym-to-base"
ln -s "$f7" "$f7sym"
set +e
bash -c 'source "$1"; _sgt_read_same_owned_files "$2" "$3"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$f7sym" "$f7b" >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -ne 0 ]]; then
  _pass "_sgt_read_same_owned_files: symlink first-arg rejected"
else
  _fail "_sgt_read_same_owned_files: symlink first-arg should be rejected"
fi

# Reject when second argument is a symlink (R003 — symmetric coverage).
f8="$TEST_ROOT/base-for-sym2"
printf 'data\n' > "$f8"
chmod 600 "$f8"
f8b="$TEST_ROOT/hardlink-of-base2"
ln "$f8" "$f8b"
f8sym="$TEST_ROOT/sym-to-base2"
ln -s "$f8" "$f8sym"
set +e
bash -c 'source "$1"; _sgt_read_same_owned_files "$2" "$3"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$f8b" "$f8sym" >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -ne 0 ]]; then
  _pass "_sgt_read_same_owned_files: symlink second-arg rejected"
else
  _fail "_sgt_read_same_owned_files: symlink second-arg should be rejected"
fi

# ── _sgt_read_matching_legacy_pane_identity ──────────────────────────────────

# Basic success: mode-644 file migrates to 600 and returns correct content.
f_leg="$TEST_ROOT/legacy-identity"
printf '0|%%42|4242|123456|worker-cmd\n' > "$f_leg"
chmod 644 "$f_leg"
set +e
result=$(bash -c 'source "$1"; _sgt_read_matching_legacy_pane_identity "$2" "$3"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$f_leg" '0|%42|4242|123456|worker-cmd')
status=$?
set -e
if [[ "$status" -eq 0 && "$result" == '0|%42|4242|123456|worker-cmd' ]]; then
  _pass "_sgt_read_matching_legacy_pane_identity: mode-644 file migrated and returned"
else
  _fail "_sgt_read_matching_legacy_pane_identity: status=$status result='$result'"
fi
# After migration, mode should be 600.
migrated_mode=$(stat -c '%a' -- "$f_leg" 2>/dev/null || stat -f '%Lp' "$f_leg" 2>/dev/null)
if [[ "$migrated_mode" == "600" ]]; then
  _pass "_sgt_read_matching_legacy_pane_identity: file migrated to mode 600"
else
  _fail "_sgt_read_matching_legacy_pane_identity: mode after migration is '$migrated_mode' (expected 600)"
fi

# Reject when content doesn't match the expected identity.
f_leg2="$TEST_ROOT/legacy-identity-mismatch"
printf '0|%%42|4242|123456|worker-cmd\n' > "$f_leg2"
chmod 644 "$f_leg2"
set +e
bash -c 'source "$1"; _sgt_read_matching_legacy_pane_identity "$2" "$3"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$f_leg2" '0|%WRONG|0000|000000|different-cmd' \
  >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -ne 0 ]]; then
  _pass "_sgt_read_matching_legacy_pane_identity: content mismatch rejected"
else
  _fail "_sgt_read_matching_legacy_pane_identity: content mismatch should be rejected"
fi

# Reject when path argument is a symlink (R004 — symlink coverage).
f_leg_real="$TEST_ROOT/legacy-identity-real"
printf '0|%%42|4242|123456|worker-cmd\n' > "$f_leg_real"
chmod 644 "$f_leg_real"
f_leg_sym="$TEST_ROOT/legacy-identity-sym"
ln -s "$f_leg_real" "$f_leg_sym"
set +e
bash -c 'source "$1"; _sgt_read_matching_legacy_pane_identity "$2" "$3"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$f_leg_sym" '0|%42|4242|123456|worker-cmd' \
  >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -ne 0 ]]; then
  _pass "_sgt_read_matching_legacy_pane_identity: symlink path rejected"
else
  _fail "_sgt_read_matching_legacy_pane_identity: symlink path should be rejected"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

printf '\nsgt-lib owned-file read: %d passed' "$pass"
if [[ "$fail" -gt 0 ]]; then
  printf ', %d FAILED\n' "$fail" >&2
  exit 1
fi
printf '\n'
