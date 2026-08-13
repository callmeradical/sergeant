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
# The fix replaces every /dev/fd path check with a descriptor-bound Python
# check: fstat(2) inspects the inherited open fd while lstat(2) inspects the
# current path.  This preserves the security binding without depending on the
# platform-specific fdescfs metadata exposed through /dev/fd.
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

# Closed-schema evidence records are multiline, but retain the same descriptor
# binding, ownership, stable-byte, and canonical terminal-LF requirements.
f="$TEST_ROOT/owned-multiline"
printf 'kind=recycle\noutcome=complete\n' > "$f"
chmod 600 "$f"
set +e
result=$(bash -c 'source "$1"; _sgt_read_owned_multiline_file "$2"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$f")
status=$?
set -e
if [[ "$status" -eq 0 && "$result" == $'kind=recycle\noutcome=complete' ]]; then
  _pass "_sgt_read_owned_multiline_file: stable mode-600 record returns exact lines"
else
  _fail "_sgt_read_owned_multiline_file: valid record returned status=$status result='$result'"
fi

printf 'kind=recycle\noutcome=complete\n\n' > "$f"
set +e
bash -c 'source "$1"; _sgt_read_owned_multiline_file "$2"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$f" >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -ne 0 ]]; then
  _pass "_sgt_read_owned_multiline_file: extra terminal LF rejected"
else
  _fail "_sgt_read_owned_multiline_file: extra terminal LF should be rejected"
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

# Legacy migration must compare the exact bytes on disk before replacing the
# file.  Command substitution historically normalized each of these malformed
# records into the expected value.
_assert_malformed_legacy_rejected() {
  local path="$1" label="$2" before status mode
  before="$path.before"
  cp -- "$path" "$before"
  set +e
  bash -c 'source "$1"; _sgt_read_matching_legacy_pane_identity "$2" "$3"' _ \
    "$ROOT_DIR/bin/_sgt-lib.sh" "$path" '0|%42|4242|123456|worker-cmd' \
    >/dev/null 2>&1
  status=$?
  set -e
  mode=$(stat -c '%a' -- "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null)
  if [[ "$status" -ne 0 && "$mode" == "644" ]] && cmp -s -- "$before" "$path"; then
    _pass "_sgt_read_matching_legacy_pane_identity: $label rejected byte-exact"
  else
    _fail "_sgt_read_matching_legacy_pane_identity: $label should be rejected without mutation"
  fi
}

malformed="$TEST_ROOT/legacy-extra-lf"
printf '0|%%42|4242|123456|worker-cmd\n\n' > "$malformed"
chmod 644 "$malformed"
_assert_malformed_legacy_rejected "$malformed" "extra terminal LF"

malformed="$TEST_ROOT/legacy-missing-lf"
printf '0|%%42|4242|123456|worker-cmd' > "$malformed"
chmod 644 "$malformed"
_assert_malformed_legacy_rejected "$malformed" "missing terminal LF"

malformed="$TEST_ROOT/legacy-nul"
printf '0|%%42|4242|123456|worker-cmd\0\n' > "$malformed"
chmod 644 "$malformed"
_assert_malformed_legacy_rejected "$malformed" "NUL byte"

malformed="$TEST_ROOT/legacy-control"
printf '0|%%42|4242|123456|worker-cmd\001\n' > "$malformed"
chmod 644 "$malformed"
_assert_malformed_legacy_rejected "$malformed" "control byte"

malformed="$TEST_ROOT/legacy-invalid-utf8"
printf '0|%%42|4242|123456|worker-cmd\377\n' > "$malformed"
chmod 644 "$malformed"
_assert_malformed_legacy_rejected "$malformed" "malformed UTF-8"

# The regular one-file and hardlink-pair readers use the same strict textual
# record transport instead of silently normalizing extra newlines.
malformed="$TEST_ROOT/owned-extra-lf"
printf 'owned-value\n\n' > "$malformed"
chmod 600 "$malformed"
set +e
bash -c 'source "$1"; _sgt_read_owned_file "$2"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$malformed" >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -ne 0 ]]; then
  _pass "_sgt_read_owned_file: extra terminal LF rejected byte-exact"
else
  _fail "_sgt_read_owned_file: extra terminal LF should be rejected"
fi

malformed_pair="$TEST_ROOT/pair-extra-lf"
ln "$malformed" "$malformed_pair"
set +e
bash -c 'source "$1"; _sgt_read_same_owned_files "$2" "$3"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$malformed" "$malformed_pair" >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -ne 0 ]]; then
  _pass "_sgt_read_same_owned_files: extra terminal LF rejected byte-exact"
else
  _fail "_sgt_read_same_owned_files: extra terminal LF should be rejected"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

# ── Descriptor-binding race regressions ──────────────────────────────────────────────────

# The public readers expose a test-only hook around descriptor opening.  It
# swaps a forged inode into each path immediately before open, then restores
# the trusted inode immediately afterward.  Path-only snapshots cannot observe
# this ABA swap; a reader bound to the held descriptor must reject it.
swap_hook="$TEST_ROOT/swap-around-open"
# shellcheck disable=SC2016 # The generated hook expands these values at runtime.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'phase="$1"; shift' \
  'for path in "$@"; do' \
  '  case "$phase" in' \
  '    before-open) mv -- "$path" "$path.trusted"; mv -- "$path.forged" "$path" ;;' \
  '    after-open)  mv -- "$path" "$path.forged-held"; mv -- "$path.trusted" "$path" ;;' \
  '    *) exit 64 ;;' \
  '  esac' \
  'done' > "$swap_hook"
chmod 700 "$swap_hook"

# A swap at the final migration boundary is rejected while the legacy fd is
# still open; the candidate never replaces the newly observed path.
migrate_hook="$TEST_ROOT/swap-before-migrate"
# shellcheck disable=SC2016 # The generated hook expands these values at runtime.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  '[[ "$1" == before-fchmod ]]' \
  'path="$2"' \
  'mv -- "$path" "$path.trusted"' \
  'mv -- "$path.forged" "$path"' > "$migrate_hook"
chmod 700 "$migrate_hook"
migrate_race="$TEST_ROOT/migrate-boundary"
printf 'migration-value\n' > "$migrate_race"
printf 'migration-value\n' > "$migrate_race.forged"
chmod 644 "$migrate_race" "$migrate_race.forged"
set +e
SGT_TEST_HOOKS=1 _SGT_OWNED_FILE_HOOK_ROOT="$TEST_ROOT" \
  _SGT_OWNED_FILE_MIGRATE_HOOK="$migrate_hook" \
  bash -c 'source "$1"; _sgt_read_matching_legacy_pane_identity "$2" migration-value' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$migrate_race" >/dev/null 2>&1
status=$?
set -e
migrate_mode=$(stat -c '%a' -- "$migrate_race" 2>/dev/null || stat -f '%Lp' "$migrate_race" 2>/dev/null)
trusted_mode=$(stat -c '%a' -- "$migrate_race.trusted" 2>/dev/null || \
  stat -f '%Lp' "$migrate_race.trusted" 2>/dev/null)
if [[ "$status" -ne 0 && "$migrate_mode" == "644" && "$trusted_mode" == "644" && \
  "$(<"$migrate_race")" == "migration-value" && \
  "$(<"$migrate_race.trusted")" == "migration-value" ]]; then
  _pass "_sgt_read_matching_legacy_pane_identity: final migration swap rejected"
else
  _fail "_sgt_read_matching_legacy_pane_identity: final migration swap should fail closed"
fi

# Rewriting the already-open inode after the exact read must not be hidden by a
# pathname replacement with the stale expected bytes.
rewrite_hook="$TEST_ROOT/rewrite-before-fchmod"
# shellcheck disable=SC2016 # The generated hook expands these values at runtime.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [[ "$1" == before-fchmod ]]; then' \
  '  printf "attacker-rewrite\\n" > "$2"' \
  'fi' > "$rewrite_hook"
chmod 700 "$rewrite_hook"
rewrite_race="$TEST_ROOT/rewrite-boundary"
printf 'migration-value\n' > "$rewrite_race"
chmod 644 "$rewrite_race"
set +e
SGT_TEST_HOOKS=1 _SGT_OWNED_FILE_HOOK_ROOT="$TEST_ROOT" \
  _SGT_OWNED_FILE_MIGRATE_HOOK="$rewrite_hook" \
  bash -c 'source "$1"; _sgt_read_matching_legacy_pane_identity "$2" migration-value' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$rewrite_race" >/dev/null 2>&1
status=$?
set -e
rewrite_mode=$(stat -c '%a' -- "$rewrite_race" 2>/dev/null || stat -f '%Lp' "$rewrite_race" 2>/dev/null)
rewrite_residue=$(find "$TEST_ROOT" -maxdepth 1 -name 'rewrite-boundary.tmp.*' -print -quit)
if [[ "$status" -ne 0 && "$rewrite_mode" == "644" && \
  "$(<"$rewrite_race")" == "attacker-rewrite" && -z "$rewrite_residue" ]]; then
  _pass "_sgt_read_matching_legacy_pane_identity: same-inode rewrite preserved and rejected"
else
  _fail "_sgt_read_matching_legacy_pane_identity: same-inode rewrite was overwritten or accepted"
fi

# A replacement installed after the former final validation must remain
# untouched.  Descriptor-local migration may change only the held inode.
post_validate_hook="$TEST_ROOT/swap-after-validation"
# shellcheck disable=SC2016 # The generated hook expands these values at runtime.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [[ "$1" == after-fchmod ]]; then' \
  '  path="$2"' \
  '  mv -- "$path" "$path.trusted"' \
  '  mv -- "$path.forged" "$path"' \
  'fi' > "$post_validate_hook"
chmod 700 "$post_validate_hook"
post_validate_race="$TEST_ROOT/post-validation-boundary"
printf 'migration-value\n' > "$post_validate_race"
printf 'replacement-bytes\n' > "$post_validate_race.forged"
chmod 644 "$post_validate_race" "$post_validate_race.forged"
set +e
SGT_TEST_HOOKS=1 _SGT_OWNED_FILE_HOOK_ROOT="$TEST_ROOT" \
  _SGT_OWNED_FILE_MIGRATE_HOOK="$post_validate_hook" \
  bash -c 'source "$1"; _sgt_read_matching_legacy_pane_identity "$2" migration-value' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$post_validate_race" >/dev/null 2>&1
status=$?
set -e
replacement_mode=$(stat -c '%a' -- "$post_validate_race" 2>/dev/null || \
  stat -f '%Lp' "$post_validate_race" 2>/dev/null)
original_mode=$(stat -c '%a' -- "$post_validate_race.trusted" 2>/dev/null || \
  stat -f '%Lp' "$post_validate_race.trusted" 2>/dev/null)
post_validate_residue=$(find "$TEST_ROOT" -maxdepth 1 \
  -name 'post-validation-boundary.tmp.*' -print -quit)
if [[ "$status" -ne 0 && "$replacement_mode" == "644" && "$original_mode" == "600" && \
  "$(<"$post_validate_race")" == "replacement-bytes" && \
  "$(<"$post_validate_race.trusted")" == "migration-value" && \
  -z "$post_validate_residue" ]]; then
  _pass "_sgt_read_matching_legacy_pane_identity: post-validation replacement untouched"
else
  _fail "_sgt_read_matching_legacy_pane_identity: post-validation replacement was overwritten or accepted"
fi

# fchmod changes inode metadata, so same-UID hardlink aliases observe the same
# mode migration.  No pathname is overwritten and content remains unchanged.
legacy_hardlink="$TEST_ROOT/legacy-hardlink"
legacy_hardlink_alias="$TEST_ROOT/legacy-hardlink-alias"
printf 'hardlink-value\n' > "$legacy_hardlink"
chmod 644 "$legacy_hardlink"
ln "$legacy_hardlink" "$legacy_hardlink_alias"
set +e
bash -c 'source "$1"; _sgt_read_matching_legacy_pane_identity "$2" hardlink-value' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$legacy_hardlink" >/dev/null 2>&1
status=$?
set -e
hardlink_mode=$(stat -c '%a' -- "$legacy_hardlink" 2>/dev/null || \
  stat -f '%Lp' "$legacy_hardlink" 2>/dev/null)
alias_mode=$(stat -c '%a' -- "$legacy_hardlink_alias" 2>/dev/null || \
  stat -f '%Lp' "$legacy_hardlink_alias" 2>/dev/null)
if [[ "$status" -eq 0 && "$hardlink_mode" == "600" && "$alias_mode" == "600" && \
  "$(<"$legacy_hardlink")" == "hardlink-value" && \
  "$(<"$legacy_hardlink_alias")" == "hardlink-value" ]]; then
  _pass "_sgt_read_matching_legacy_pane_identity: hardlink aliases share descriptor-local mode"
else
  _fail "_sgt_read_matching_legacy_pane_identity: hardlink migration changed content or diverged"
fi

# Restoring expected bytes and mtime cannot hide a same-inode rewrite before
# fchmod: ctime remains a monotonic witness to the intervening mutation.
restore_before_hook="$TEST_ROOT/restore-before-fchmod"
# shellcheck disable=SC2016 # The generated hook expands these values at runtime.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [[ "$1" == before-fchmod ]]; then' \
  '  path="$2"' \
  '  printf "attacker-value!\\n" > "$path"' \
  '  printf "migration-value\\n" > "$path"' \
  '  touch -r "$path.mtime-ref" "$path"' \
  'fi' > "$restore_before_hook"
chmod 700 "$restore_before_hook"
restore_before="$TEST_ROOT/restore-before"
printf 'migration-value\n' > "$restore_before"
chmod 644 "$restore_before"
cp -p -- "$restore_before" "$restore_before.mtime-ref"
set +e
SGT_TEST_HOOKS=1 _SGT_OWNED_FILE_HOOK_ROOT="$TEST_ROOT" \
  _SGT_OWNED_FILE_MIGRATE_HOOK="$restore_before_hook" \
  bash -c 'source "$1"; _sgt_read_matching_legacy_pane_identity "$2" migration-value' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$restore_before" >/dev/null 2>&1
status=$?
set -e
restore_before_mode=$(stat -c '%a' -- "$restore_before" 2>/dev/null || \
  stat -f '%Lp' "$restore_before" 2>/dev/null)
if [[ "$status" -ne 0 && "$restore_before_mode" == "644" && \
  "$(<"$restore_before")" == "migration-value" ]]; then
  _pass "_sgt_read_matching_legacy_pane_identity: restored pre-fchmod rewrite rejected by ctime"
else
  _fail "_sgt_read_matching_legacy_pane_identity: restored pre-fchmod rewrite escaped detection"
fi

# Capture metadata immediately after fchmod so an after-hook cannot rewrite,
# restore expected bytes+mtime, and return a false success.
restore_after_hook="$TEST_ROOT/restore-after-fchmod"
# shellcheck disable=SC2016 # The generated hook expands these values at runtime.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [[ "$1" == after-fchmod ]]; then' \
  '  path="$2"' \
  '  printf "attacker-value!\\n" > "$path"' \
  '  printf "migration-value\\n" > "$path"' \
  '  touch -r "$path.mtime-ref" "$path"' \
  'fi' > "$restore_after_hook"
chmod 700 "$restore_after_hook"
restore_after="$TEST_ROOT/restore-after"
printf 'migration-value\n' > "$restore_after"
chmod 644 "$restore_after"
cp -p -- "$restore_after" "$restore_after.mtime-ref"
set +e
SGT_TEST_HOOKS=1 _SGT_OWNED_FILE_HOOK_ROOT="$TEST_ROOT" \
  _SGT_OWNED_FILE_MIGRATE_HOOK="$restore_after_hook" \
  bash -c 'source "$1"; _sgt_read_matching_legacy_pane_identity "$2" migration-value' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$restore_after" >/dev/null 2>&1
status=$?
set -e
restore_after_mode=$(stat -c '%a' -- "$restore_after" 2>/dev/null || \
  stat -f '%Lp' "$restore_after" 2>/dev/null)
if [[ "$status" -ne 0 && "$restore_after_mode" == "600" && \
  "$(<"$restore_after")" == "migration-value" ]]; then
  _pass "_sgt_read_matching_legacy_pane_identity: restored post-fchmod rewrite rejected by ctime"
else
  _fail "_sgt_read_matching_legacy_pane_identity: restored post-fchmod rewrite escaped detection"
fi

# A write after fchmod is detected by the final metadata and exact-byte read;
# failure never restores stale content over the concurrent writer.
after_fchmod_hook="$TEST_ROOT/rewrite-after-fchmod"
# shellcheck disable=SC2016 # The generated hook expands these values at runtime.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [[ "$1" == after-fchmod ]]; then' \
  '  printf "writer-after-fchmod\\n" > "$2"' \
  'fi' > "$after_fchmod_hook"
chmod 700 "$after_fchmod_hook"
after_fchmod_race="$TEST_ROOT/after-fchmod-write"
printf 'migration-value\n' > "$after_fchmod_race"
chmod 644 "$after_fchmod_race"
set +e
SGT_TEST_HOOKS=1 _SGT_OWNED_FILE_HOOK_ROOT="$TEST_ROOT" \
  _SGT_OWNED_FILE_MIGRATE_HOOK="$after_fchmod_hook" \
  bash -c 'source "$1"; _sgt_read_matching_legacy_pane_identity "$2" migration-value' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$after_fchmod_race" >/dev/null 2>&1
status=$?
set -e
after_fchmod_mode=$(stat -c '%a' -- "$after_fchmod_race" 2>/dev/null || \
  stat -f '%Lp' "$after_fchmod_race" 2>/dev/null)
if [[ "$status" -ne 0 && "$after_fchmod_mode" == "600" && \
  "$(<"$after_fchmod_race")" == "writer-after-fchmod" ]]; then
  _pass "_sgt_read_matching_legacy_pane_identity: concurrent post-fchmod write preserved and rejected"
else
  _fail "_sgt_read_matching_legacy_pane_identity: concurrent post-fchmod write was hidden"
fi

# Hook/helper failure before fchmod leaves the original record byte-for-byte
# and mode-for-mode unchanged, with no candidate file to clean up.
failure_hook="$TEST_ROOT/fail-before-fchmod"
printf '%s\n' '#!/usr/bin/env bash' 'exit 42' > "$failure_hook"
chmod 700 "$failure_hook"
helper_failure="$TEST_ROOT/helper-failure"
printf 'migration-value\n' > "$helper_failure"
chmod 644 "$helper_failure"
set +e
SGT_TEST_HOOKS=1 _SGT_OWNED_FILE_HOOK_ROOT="$TEST_ROOT" \
  _SGT_OWNED_FILE_MIGRATE_HOOK="$failure_hook" \
  bash -c 'source "$1"; _sgt_read_matching_legacy_pane_identity "$2" migration-value' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$helper_failure" >/dev/null 2>&1
status=$?
set -e
helper_failure_mode=$(stat -c '%a' -- "$helper_failure" 2>/dev/null || \
  stat -f '%Lp' "$helper_failure" 2>/dev/null)
all_candidate_residue=$(find "$TEST_ROOT" -maxdepth 1 -name '*.tmp.*' -print -quit)
if [[ "$status" -ne 0 && "$helper_failure_mode" == "644" && \
  "$(<"$helper_failure")" == "migration-value" && -z "$all_candidate_residue" ]]; then
  _pass "_sgt_read_matching_legacy_pane_identity: helper failure leaves no mutation or residue"
else
  _fail "_sgt_read_matching_legacy_pane_identity: helper failure mutated state or left residue"
fi

# Merely naming a hook never executes it; the explicit test flag and matching
# test-root boundary are both required.
hook_disabled="$TEST_ROOT/hook-disabled"
printf 'trusted-disabled\n' > "$hook_disabled"
printf 'forged-disabled\n' > "$hook_disabled.forged"
chmod 600 "$hook_disabled" "$hook_disabled.forged"
set +e
result=$(_SGT_OWNED_FILE_HOOK_ROOT="$TEST_ROOT" _SGT_OWNED_FILE_OPEN_HOOK="$swap_hook" \
  bash -c 'source "$1"; _sgt_read_owned_file "$2"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$hook_disabled")
status=$?
set -e
if [[ "$status" -eq 0 && "$result" == "trusted-disabled" && \
  ! -e "$hook_disabled.trusted" && ! -e "$hook_disabled.forged-held" ]]; then
  _pass "owned-file test hook: disabled without SGT_TEST_HOOKS=1"
else
  _fail "owned-file test hook: executed without explicit test enablement"
fi

# The descriptor verifier rejects malformed numeric and mode arguments rather
# than allowing them to influence Python or shell parsing.
set +e
bash -c 'source "$1"; exec 9< "$2"; _sgt_validate_owned_fd nope "$2" 600' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$hook_disabled" >/dev/null 2>&1
invalid_fd_status=$?
bash -c 'source "$1"; exec 9< "$2"; _sgt_validate_owned_fd 9 "$2" "600;echo forged"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$hook_disabled" >/dev/null 2>&1
invalid_mode_status=$?
set -e
if [[ "$invalid_fd_status" -ne 0 && "$invalid_mode_status" -ne 0 ]]; then
  _pass "owned-file descriptor verifier: invalid fd and mode rejected"
else
  _fail "owned-file descriptor verifier: malformed arguments should fail closed"
fi

# Successful public calls close every fixed descriptor before returning.
fd_one="$TEST_ROOT/fd-close-one"
printf 'fd-one\n' > "$fd_one"
chmod 600 "$fd_one"
fd_pair_first="$TEST_ROOT/fd-close-pair-first"
fd_pair_second="$TEST_ROOT/fd-close-pair-second"
printf 'fd-pair\n' > "$fd_pair_first"
chmod 600 "$fd_pair_first"
ln "$fd_pair_first" "$fd_pair_second"
fd_legacy="$TEST_ROOT/fd-close-legacy"
printf 'legacy-fd\n' > "$fd_legacy"
chmod 644 "$fd_legacy"
set +e
bash -c '
  source "$1"
  _sgt_read_owned_file "$2" >/dev/null || exit 70
  if : 2>/dev/null <&9; then exit 71; fi
  _sgt_read_same_owned_files "$3" "$4" >/dev/null || exit 72
  if : 2>/dev/null <&8 || : 2>/dev/null <&9; then exit 73; fi
  _sgt_read_matching_legacy_pane_identity "$5" legacy-fd >/dev/null || exit 74
  if : 2>/dev/null <&9; then exit 75; fi
' _ "$ROOT_DIR/bin/_sgt-lib.sh" "$fd_one" "$fd_pair_first" "$fd_pair_second" \
  "$fd_legacy" >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -eq 0 ]]; then
  _pass "owned-file readers: fixed descriptors closed after successful calls"
else
  _fail "owned-file readers: leaked fd 8 or 9 (status=$status)"
fi

race_one="$TEST_ROOT/race-one"
printf 'trusted-one\n' > "$race_one"
printf 'forged-one\n' > "$race_one.forged"
chmod 600 "$race_one" "$race_one.forged"
set +e
SGT_TEST_HOOKS=1 _SGT_OWNED_FILE_HOOK_ROOT="$TEST_ROOT" \
  _SGT_OWNED_FILE_OPEN_HOOK="$swap_hook" \
  bash -c 'source "$1"; _sgt_read_owned_file "$2"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$race_one" >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -ne 0 && "$(<"$race_one")" == "trusted-one" ]]; then
  _pass "_sgt_read_owned_file: transient forged descriptor rejected"
else
  _fail "_sgt_read_owned_file: transient forged descriptor should be rejected"
fi

race_legacy="$TEST_ROOT/race-legacy"
legacy_value='0|%42|4242|123456|worker-cmd'
printf '%s\n' "$legacy_value" > "$race_legacy"
printf '%s\n' "$legacy_value" > "$race_legacy.forged"
chmod 644 "$race_legacy" "$race_legacy.forged"
set +e
SGT_TEST_HOOKS=1 _SGT_OWNED_FILE_HOOK_ROOT="$TEST_ROOT" \
  _SGT_OWNED_FILE_OPEN_HOOK="$swap_hook" \
  bash -c 'source "$1"; _sgt_read_matching_legacy_pane_identity "$2" "$3"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$race_legacy" "$legacy_value" >/dev/null 2>&1
status=$?
set -e
legacy_mode=$(stat -c '%a' -- "$race_legacy" 2>/dev/null || stat -f '%Lp' "$race_legacy" 2>/dev/null)
if [[ "$status" -ne 0 && "$legacy_mode" == "644" ]]; then
  _pass "_sgt_read_matching_legacy_pane_identity: transient forged descriptor rejected"
else
  _fail "_sgt_read_matching_legacy_pane_identity: transient forged descriptor should be rejected without migration"
fi

race_first="$TEST_ROOT/race-pair-first"
race_second="$TEST_ROOT/race-pair-second"
printf 'trusted-pair\n' > "$race_first"
ln "$race_first" "$race_second"
printf 'forged-pair\n' > "$race_first.forged"
ln "$race_first.forged" "$race_second.forged"
chmod 600 "$race_first" "$race_first.forged"
set +e
SGT_TEST_HOOKS=1 _SGT_OWNED_FILE_HOOK_ROOT="$TEST_ROOT" \
  _SGT_OWNED_FILE_OPEN_HOOK="$swap_hook" \
  bash -c 'source "$1"; _sgt_read_same_owned_files "$2" "$3"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$race_first" "$race_second" >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -ne 0 && "$(<"$race_first")" == "trusted-pair" && \
  "$(<"$race_second")" == "trusted-pair" ]]; then
  _pass "_sgt_read_same_owned_files: transient forged descriptor pair rejected"
else
  _fail "_sgt_read_same_owned_files: transient forged descriptor pair should be rejected"
fi

printf '\nsgt-lib owned-file read: %d passed' "$pass"
if [[ "$fail" -gt 0 ]]; then
  printf ', %d FAILED\n' "$fail" >&2
  exit 1
fi
printf '\n'
