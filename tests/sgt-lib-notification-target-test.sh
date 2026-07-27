#!/usr/bin/env bash
# Regression: race boundary in _sgt_notification_target_create
#
# pane_identity is stored exclusively inside
#   notifications/$id/targets/$nonce/pane_identity
# which is written before the nonce is atomically published via mv.
# There is no top-level notification_target_pane_identity file.
#
# One injection window is covered:
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

# ── Case 1: post-mv injection ────────────────────────────────────────────────
#
# _SGT_POST_MV_HOOK (active only when SGT_TEST_HOOKS=1) fires after mv and
# before the post-mv verification.  A concurrent publisher atomically replaces
# notification_target in this window.  The function must detect
# published_nonce != nonce, clean up the orphaned target_dir, and return
# failure.  The replacement nonce must be preserved.  No top-level
# notification_target_pane_identity is written because it no longer exists.

repo_dir1="$TEST_ROOT/repo-postmv"
mkdir -p "$repo_dir1"
wrapper1="$TEST_ROOT/run-postmv.sh"
make_wrapper "$wrapper1" "$repo_dir1"

postmv_hook="printf '%s\n' '$replacement_nonce' > '$repo_dir1/notification_target'"
set +e
SGT_TEST_HOOKS=1 _SGT_POST_MV_HOOK="$postmv_hook" HOME="$TEST_ROOT/home" \
  bash "$wrapper1" >/dev/null 2>&1
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
  printf 'FAIL case1: returned 0 despite post-mv replacement\n' >&2
  exit 1
fi

published1="$(cat "$repo_dir1/notification_target" 2>/dev/null || printf '')"
if [[ "$published1" != "$replacement_nonce" ]]; then
  printf 'FAIL case1: replacement nonce overwritten: got "%s", want "%s"\n' \
    "$published1" "$replacement_nonce" >&2
  exit 1
fi

# No top-level notification_target_pane_identity file should exist; the design
# eliminates it.
if [[ -f "$repo_dir1/notification_target_pane_identity" ]]; then
  printf 'FAIL case1: unexpected notification_target_pane_identity flat file exists\n' >&2
  exit 1
fi

orphan_count1="$(find "$repo_dir1/notifications" -mindepth 3 -maxdepth 3 -type d 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$orphan_count1" -ne 0 ]]; then
  printf 'FAIL case1: orphaned target_dir not cleaned up (found %s)\n' "$orphan_count1" >&2
  exit 1
fi

# ── Case 2: clean success path ───────────────────────────────────────────────

repo_dir2="$TEST_ROOT/repo-clean"
mkdir -p "$repo_dir2"
wrapper2="$TEST_ROOT/run-clean.sh"
make_wrapper "$wrapper2" "$repo_dir2"

set +e
nonce_out="$(HOME="$TEST_ROOT/home" bash "$wrapper2" 2>/dev/null)"
status=$?
set -e

if [[ "$status" -ne 0 ]]; then
  printf 'FAIL case2: failed on clean success path\n' >&2
  exit 1
fi

[[ -n "$nonce_out" ]] || { printf 'FAIL case2: no nonce returned\n' >&2; exit 1; }

published2="$(tr -d '\n' < "$repo_dir2/notification_target" 2>/dev/null || printf '')"
if [[ "$published2" != "$nonce_out" ]]; then
  printf 'FAIL case2: returned nonce "%s" != published "%s"\n' "$nonce_out" "$published2" >&2
  exit 1
fi

# pane_identity must be in the target_dir, not in a top-level flat file.
target_id="$(cat "$repo_dir2/notifications/test-notif-id/targets/$nonce_out/pane_identity" 2>/dev/null || printf '')"
if [[ "$target_id" != "$pane_identity" ]]; then
  printf 'FAIL case2: target_dir pane_identity "%s" != expected "%s"\n' \
    "$target_id" "$pane_identity" >&2
  exit 1
fi

if [[ -f "$repo_dir2/notification_target_pane_identity" ]]; then
  printf 'FAIL case2: unexpected notification_target_pane_identity flat file exists\n' >&2
  exit 1
fi

target_dir_count2="$(find "$repo_dir2/notifications" -mindepth 3 -maxdepth 3 -type d 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$target_dir_count2" -ne 1 ]]; then
  printf 'FAIL case2: expected 1 target_dir on success, found %s\n' "$target_dir_count2" >&2
  exit 1
fi

printf 'sgt-lib notification-target race boundary: ok\n'
