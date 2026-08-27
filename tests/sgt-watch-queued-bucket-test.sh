#!/usr/bin/env bash
# Tests for the "queued" bucket added to sgt-watch --list and
# sgt-watch --snapshot --project for openspec/changes/dispatch-admission-control.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

pass=0
fail=0
_pass() { printf '  ok: %s\n' "$*"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n' "$*" >&2; fail=$((fail + 1)); }

config="$TEST_ROOT/config"
fleet="$TEST_ROOT/fleet"
repo="$TEST_ROOT/repo"
mkdir -p "$config" "$fleet" "$repo"

cat > "$config/myproj.yaml" <<EOF
name: myproj
repos:
  - name: app
    path: $repo
EOF
git -C "$repo" init -q
git -C "$repo" config user.name Test
git -C "$repo" config user.email test@example.invalid
touch "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -qm fixture

_lib() {
  bash -c 'source "$1"; shift; "$@"' _ "$ROOT_DIR/bin/_sgt-lib.sh" "$@"
}

# ── --list reports a bare queued entry with no fleet task dir yet ───────────

SERGEANT_FLEET="$fleet" _lib _sgt_dispatch_queue_enqueue queued-task-1 myproj app "do work"
list_out="$(SERGEANT_FLEET="$fleet" "$ROOT_DIR/bin/sgt-watch" --list 2>&1)"
if [[ "$list_out" == *"queued-task-1"* && "$list_out" == *"queued (position 1 of 1)"* ]]; then
  _pass "sgt-watch --list: a queued-only task (no fleet directory yet) is reported as queued"
else
  _fail "sgt-watch --list: expected queued-task-1 reported queued; got:\n$list_out"
fi
if [[ "$list_out" == *"repos:   app"* ]]; then
  _pass "sgt-watch --list: queued entry shows its recorded repos"
else
  _fail "sgt-watch --list: expected repos field for queued entry; got:\n$list_out"
fi

# A second, lower-position entry reports its rank too.
SERGEANT_FLEET="$fleet" _lib _sgt_dispatch_queue_enqueue queued-task-2 myproj app "more work"
list_out2="$(SERGEANT_FLEET="$fleet" "$ROOT_DIR/bin/sgt-watch" --list 2>&1)"
if [[ "$list_out2" == *"queued (position 1 of 2)"* && "$list_out2" == *"queued (position 2 of 2)"* ]]; then
  _pass "sgt-watch --list: multiple queued entries report distinct FIFO positions"
else
  _fail "sgt-watch --list: expected two distinct queue positions; got:\n$list_out2"
fi

# ── --snapshot --project counts queued entries in fleet_queued ──────────────

snap_out="$(SERGEANT_CONFIG="$config" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-watch" --snapshot --project myproj 2>&1)"
queued_count="$(printf '%s' "$snap_out" | python3 -c \
  'import json,sys; d=json.load(sys.stdin); print(d["fleet"]["totals"]["queued"])' 2>/dev/null || echo "PARSE_ERROR")"
if [[ "$queued_count" == "2" ]]; then
  _pass "sgt-watch --snapshot --project: fleet.totals.queued counts both queued entries"
else
  _fail "sgt-watch --snapshot --project: expected totals.queued=2, got '$queued_count'; raw: $snap_out"
fi

# A queued entry for a DIFFERENT project must not be counted.
SERGEANT_FLEET="$fleet" _lib _sgt_dispatch_queue_enqueue other-project-task otherproj app "unrelated"
snap_out2="$(SERGEANT_CONFIG="$config" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-watch" --snapshot --project myproj 2>&1)"
queued_count2="$(printf '%s' "$snap_out2" | python3 -c \
  'import json,sys; d=json.load(sys.stdin); print(d["fleet"]["totals"]["queued"])' 2>/dev/null || echo "PARSE_ERROR")"
if [[ "$queued_count2" == "2" ]]; then
  _pass "sgt-watch --snapshot --project: a queued entry for an unrelated project is not counted"
else
  _fail "sgt-watch --snapshot --project: expected totals.queued to stay 2, got '$queued_count2'"
fi

printf '\nsgt-watch-queued-bucket: %d passed' "$pass"
if [[ "$fail" -gt 0 ]]; then
  printf ', %d FAILED\n' "$fail" >&2
  exit 1
fi
printf '\n'
