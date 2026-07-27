#!/usr/bin/env bash
# Tests for sgt-drain / sgt-undrain — persistent drain state and reevaluation.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

config_dir="$TEST_ROOT/config"
export SERGEANT_CONFIG="$config_dir"
mkdir -p "$config_dir"

# ── Slice 1: no drain — admits everything ────────────────────────────────────

# shellcheck source=bin/_sgt-drain.sh
source "$ROOT_DIR/bin/_sgt-drain.sh"

_sgt_is_drained "myproject" && { printf '_sgt_is_drained should return 1 when no drain files exist\n' >&2; exit 1; }
_sgt_is_drained "" && { printf '_sgt_is_drained should return 1 for empty project and no global drain\n' >&2; exit 1; }
printf 'sgt-drain no-drain admits all: ok\n'

# ── Slice 2: global drain blocks all projects ────────────────────────────────

mkdir -p "$config_dir/drain"
printf 'reason=maintenance\ncreated=2025-01-01T00:00:00Z\n' > "$config_dir/drain/global"

_sgt_is_drained "myproject" || { printf '_sgt_is_drained should return 0 with global drain\n' >&2; exit 1; }
_sgt_is_drained "otherproject" || { printf '_sgt_is_drained should drain all projects when global drain active\n' >&2; exit 1; }
_sgt_is_drained "" || { printf '_sgt_is_drained should return 0 for empty project with global drain\n' >&2; exit 1; }
rm "$config_dir/drain/global"
printf 'sgt-drain global drain blocks all: ok\n'

# ── Slice 3: project drain blocks only that project ──────────────────────────

printf 'reason=feature-gate\ncreated=2025-01-01T00:00:00Z\n' > "$config_dir/drain/myproject"

_sgt_is_drained "myproject" || { printf '_sgt_is_drained should return 0 for matching project drain\n' >&2; exit 1; }
_sgt_is_drained "otherproject" && { printf '_sgt_is_drained should return 1 for non-matching project drain\n' >&2; exit 1; }
_sgt_is_drained "" && { printf '_sgt_is_drained should return 1 for empty project when only project drain active\n' >&2; exit 1; }
rm "$config_dir/drain/myproject"
printf 'sgt-drain project drain scopes correctly: ok\n'

# ── Slice 4: sgt-drain --global sets global drain ────────────────────────────

"$ROOT_DIR/bin/sgt-drain" --global --reason "test global" >/dev/null
[[ -f "$config_dir/drain/global" ]] || { printf 'sgt-drain --global should create global drain file\n' >&2; exit 1; }
grep -q 'reason=test global' "$config_dir/drain/global" || { printf 'global drain file should contain reason\n' >&2; exit 1; }
grep -q 'created=' "$config_dir/drain/global" || { printf 'global drain file should contain created timestamp\n' >&2; exit 1; }
_sgt_is_drained "anyproject" || { printf 'global drain should be active after sgt-drain --global\n' >&2; exit 1; }
printf 'sgt-drain --global creates drain: ok\n'

# ── Slice 5: sgt-undrain --global removes global drain ───────────────────────

"$ROOT_DIR/bin/sgt-drain" --undrain --global >/dev/null
[[ ! -f "$config_dir/drain/global" ]] || { printf 'sgt-drain --undrain --global should remove global drain file\n' >&2; exit 1; }
_sgt_is_drained "anyproject" && { printf 'global drain should be inactive after undrain\n' >&2; exit 1; }
printf 'sgt-drain --undrain --global removes drain: ok\n'

# ── Slice 6: sgt-drain <project> sets project drain ─────────────────────────

"$ROOT_DIR/bin/sgt-drain" myproject --reason "feature pause" >/dev/null
[[ -f "$config_dir/drain/myproject" ]] || { printf 'sgt-drain myproject should create project drain file\n' >&2; exit 1; }
grep -q 'reason=feature pause' "$config_dir/drain/myproject" || { printf 'project drain file should contain reason\n' >&2; exit 1; }
_sgt_is_drained "myproject" || { printf 'project drain should be active after sgt-drain myproject\n' >&2; exit 1; }
_sgt_is_drained "otherproject" && { printf 'sgt-drain myproject should not drain other projects\n' >&2; exit 1; }
printf 'sgt-drain project sets drain: ok\n'

# ── Slice 7: sgt-drain --undrain <project> removes project drain ─────────────

"$ROOT_DIR/bin/sgt-drain" --undrain myproject >/dev/null
[[ ! -f "$config_dir/drain/myproject" ]] || { printf 'sgt-drain --undrain myproject should remove drain file\n' >&2; exit 1; }
_sgt_is_drained "myproject" && { printf 'project drain should be inactive after undrain\n' >&2; exit 1; }
printf 'sgt-drain --undrain project removes drain: ok\n'

# ── Slice 8: sgt-drain idempotent — double drain is ok ──────────────────────

"$ROOT_DIR/bin/sgt-drain" --global --reason "first" >/dev/null
"$ROOT_DIR/bin/sgt-drain" --global --reason "second" >/dev/null
[[ -f "$config_dir/drain/global" ]] || { printf 'double drain should still have drain file\n' >&2; exit 1; }
grep -q 'reason=second' "$config_dir/drain/global" || { printf 'second drain should overwrite reason\n' >&2; exit 1; }
"$ROOT_DIR/bin/sgt-drain" --undrain --global >/dev/null
printf 'sgt-drain idempotent double drain: ok\n'

# ── Slice 9: sgt-drain --undrain no-op when not drained ─────────────────────

# Should not fail
"$ROOT_DIR/bin/sgt-drain" --undrain myproject >/dev/null
"$ROOT_DIR/bin/sgt-drain" --undrain --global >/dev/null
printf 'sgt-drain --undrain no-op when not drained: ok\n'

# ── Slice 10: drain without reason ──────────────────────────────────────────

"$ROOT_DIR/bin/sgt-drain" --global >/dev/null
[[ -f "$config_dir/drain/global" ]] || { printf 'drain without reason should still create file\n' >&2; exit 1; }
grep -q 'created=' "$config_dir/drain/global" || { printf 'drain without reason should have created timestamp\n' >&2; exit 1; }
"$ROOT_DIR/bin/sgt-drain" --undrain --global >/dev/null
printf 'sgt-drain without reason: ok\n'

printf 'sgt-drain: all tests passed\n'
