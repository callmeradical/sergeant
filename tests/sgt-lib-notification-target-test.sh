#!/usr/bin/env bash
# Regression: race boundary in _sgt_notification_target_create
#
# pane_identity is stored exclusively inside
#   notifications/$id/targets/$nonce/pane_identity
# which is written before the nonce is atomically published via mv.
# There is no top-level notification_target_pane_identity file.
#
# Two injection windows are covered:
#
#   pre-mv:  a concurrent publisher writes to notification_target immediately
#     before our mv executes.  mv(rename(2)) is atomic: it overwrites the
#     destination unconditionally.  Function must succeed; notification_target
#     holds our nonce; replacement is atomically overwritten.
#
#   post-mv  (_SGT_POST_MV_HOOK, active only when SGT_TEST_HOOKS=1):
#     a concurrent publisher atomically replaces notification_target after
#     our mv.  Detected by post-mv verification.  Function must fail;
#     replacement nonce preserved; orphaned target_dir cleaned up.
#
#   clean success: no injection.  Function must succeed; nonce published;
#     pane_identity written into target_dir (not a top-level flat file).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fake_bin="$TEST_ROOT/fake-bin"
mkdir -p "$fake_bin"

real_mv="$(command -v mv)"
replacement_nonce="ffffffffffffffffffffffffffffffff"
pane_identity="0|%42|4242|123456|test-command"

make_wrapper() {
  local path="$1" repo_dir="$2" notif_id="${3:-test-notif-id}"
  cat > "$path" <<WRAPPER
#!/usr/bin/env bash
set -euo pipefail
source "$ROOT_DIR/bin/_sgt-lib.sh"
_sgt_notification_target_create "$repo_dir" "$notif_id" "$pane_identity"
WRAPPER
  chmod +x "$path"
}

# ── Case 1: pre-mv same-path replacement is atomically overwritten ────────────
#
# Fake mv intercepts the notification_target rename, writes the replacement
# nonce to the destination, then executes the real mv.  mv(rename(2)) is
# atomic: it overwrites the destination with the source regardless of what is
# already there.  The function must succeed and notification_target must hold
# the nonce the function published, not the injected replacement.
#
# This proves the correct simulation of the pre-mv TOCTOU window: the real
# rename runs on a destination that already holds a competing nonce; mv
# atomicity ensures the function's nonce is the final live value.

# Fake mv: for the notification_target rename, inject a same-path replacement
# to the destination immediately before executing the real mv.
cat > "$fake_bin/mv" <<EOF
#!/usr/bin/env bash
dst="\${!#}"
if [[ "\$dst" == */notification_target ]]; then
  # Inject same-path replacement immediately before the real rename.
  printf '%s\n' "$replacement_nonce" > "\$dst"
fi
exec "$real_mv" "\$@"
EOF
chmod +x "$fake_bin/mv"

repo_dir1="$TEST_ROOT/repo-premv"
mkdir -p "$repo_dir1"
wrapper1="$TEST_ROOT/run-premv.sh"
make_wrapper "$wrapper1" "$repo_dir1"

set +e
nonce1="$(HOME="$TEST_ROOT/home" PATH="$fake_bin:$PATH" bash "$wrapper1" 2>/dev/null)"
status=$?
set -e

# The function must succeed: mv atomically handles any pre-mv write to the
# destination.
if [[ "$status" -ne 0 ]]; then
  printf 'FAIL case1: function returned %d; expected 0 (mv atomically handles pre-mv replacement)\n' \
    "$status" >&2
  exit 1
fi

# notification_target must hold the function's own nonce, not the injected
# replacement.  The real mv atomically overwrites the replacement.
published1="$(tr -d '\n' < "$repo_dir1/notification_target" 2>/dev/null || printf '')"
if [[ "$published1" != "$nonce1" ]]; then
  printf 'FAIL case1: notification_target holds "%s"; want function nonce "%s"\n' \
    "$published1" "$nonce1" >&2
  exit 1
fi
if [[ "$published1" == "$replacement_nonce" ]]; then
  printf 'FAIL case1: replacement nonce was not atomically overwritten by mv\n' >&2
  exit 1
fi

# pane_identity must be in the target_dir (not a top-level flat file).
target_id1="$(cat "$repo_dir1/notifications/test-notif-id/targets/$nonce1/pane_identity" 2>/dev/null || printf '')"
if [[ "$target_id1" != "$pane_identity" ]]; then
  printf 'FAIL case1: target_dir pane_identity "%s" != expected "%s"\n' \
    "$target_id1" "$pane_identity" >&2
  exit 1
fi

if [[ -f "$repo_dir1/notification_target_pane_identity" ]]; then
  printf 'FAIL case1: unexpected notification_target_pane_identity flat file exists\n' >&2
  exit 1
fi

# ── Case 2: post-mv injection ────────────────────────────────────────────────
#
# _SGT_POST_MV_HOOK (active only when SGT_TEST_HOOKS=1) fires after mv and
# before the post-mv verification.  A concurrent publisher atomically replaces
# notification_target in this window.  The function must detect
# published_nonce != nonce, clean up the orphaned target_dir, and return
# failure.  The replacement nonce must be preserved.  No top-level
# notification_target_pane_identity is written because it no longer exists.

repo_dir2="$TEST_ROOT/repo-postmv"
mkdir -p "$repo_dir2"
wrapper2="$TEST_ROOT/run-postmv.sh"
make_wrapper "$wrapper2" "$repo_dir2"

postmv_hook="printf '%s\n' '$replacement_nonce' > '$repo_dir2/notification_target'"
set +e
SGT_TEST_HOOKS=1 _SGT_POST_MV_HOOK="$postmv_hook" HOME="$TEST_ROOT/home" \
  bash "$wrapper2" >/dev/null 2>&1
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
  printf 'FAIL case2: returned 0 despite post-mv replacement\n' >&2
  exit 1
fi

published2="$(cat "$repo_dir2/notification_target" 2>/dev/null || printf '')"
if [[ "$published2" != "$replacement_nonce" ]]; then
  printf 'FAIL case2: replacement nonce overwritten: got "%s", want "%s"\n' \
    "$published2" "$replacement_nonce" >&2
  exit 1
fi

# No top-level notification_target_pane_identity file should exist; the design
# eliminates it.
if [[ -f "$repo_dir2/notification_target_pane_identity" ]]; then
  printf 'FAIL case2: unexpected notification_target_pane_identity flat file exists\n' >&2
  exit 1
fi

orphan_count2="$(find "$repo_dir2/notifications" -mindepth 3 -maxdepth 3 -type d 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$orphan_count2" -ne 0 ]]; then
  printf 'FAIL case2: orphaned target_dir not cleaned up (found %s)\n' "$orphan_count2" >&2
  exit 1
fi

# ── Case 3: clean success path ───────────────────────────────────────────────

repo_dir3="$TEST_ROOT/repo-clean"
mkdir -p "$repo_dir3"
wrapper3="$TEST_ROOT/run-clean.sh"
make_wrapper "$wrapper3" "$repo_dir3"

set +e
nonce3="$(HOME="$TEST_ROOT/home" bash "$wrapper3" 2>/dev/null)"
status=$?
set -e

if [[ "$status" -ne 0 ]]; then
  printf 'FAIL case3: failed on clean success path\n' >&2
  exit 1
fi

[[ -n "$nonce3" ]] || { printf 'FAIL case3: no nonce returned\n' >&2; exit 1; }

published3="$(tr -d '\n' < "$repo_dir3/notification_target" 2>/dev/null || printf '')"
if [[ "$published3" != "$nonce3" ]]; then
  printf 'FAIL case3: returned nonce "%s" != published "%s"\n' "$nonce3" "$published3" >&2
  exit 1
fi

# pane_identity must be in the target_dir, not in a top-level flat file.
target_id3="$(cat "$repo_dir3/notifications/test-notif-id/targets/$nonce3/pane_identity" 2>/dev/null || printf '')"
if [[ "$target_id3" != "$pane_identity" ]]; then
  printf 'FAIL case3: target_dir pane_identity "%s" != expected "%s"\n' \
    "$target_id3" "$pane_identity" >&2
  exit 1
fi

if [[ -f "$repo_dir3/notification_target_pane_identity" ]]; then
  printf 'FAIL case3: unexpected notification_target_pane_identity flat file exists\n' >&2
  exit 1
fi

target_dir_count3="$(find "$repo_dir3/notifications" -mindepth 3 -maxdepth 3 -type d 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$target_dir_count3" -ne 1 ]]; then
  printf 'FAIL case3: expected 1 target_dir on success, found %s\n' "$target_dir_count3" >&2
  exit 1
fi

printf 'sgt-lib notification-target race boundary: ok\n'
