#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin"
mkdir -p "$TEST_ROOT/proc/700" "$TEST_ROOT/empty-proc"
printf '700 (worker name) S 1 700 700 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 12345 0\n' \
  > "$TEST_ROOT/proc/700/stat"
cat > "$TEST_ROOT/bin/ps" <<'EOF'
#!/usr/bin/env bash
case "$*:$PS_STYLE" in
  *'pid=,ppid=,sid='*:linux) printf '700 1 700\n701 700 700\n' ;;
  *'pid=,ppid=,sid='*:darwin) exit 1 ;;
  *'pid=,ppid=,sess='*:darwin) printf '800 1 800\n801 800 800\n' ;;
  *'sid='*:linux) printf ' 700\n' ;;
  *'sid='*:darwin) exit 1 ;;
  *'sess='*:darwin) printf ' 800\n' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TEST_ROOT/bin/ps"
# shellcheck source=bin/_sgt-process.sh
source "$ROOT/bin/_sgt-process.sh"
[[ "$(PS_STYLE=linux PATH="$TEST_ROOT/bin:$PATH" _sgt_process_session_id 7)" == 700 ]]
[[ "$(PS_STYLE=darwin PATH="$TEST_ROOT/bin:$PATH" _sgt_process_session_id 8)" == 800 ]]
[[ "$(PS_STYLE=linux PATH="$TEST_ROOT/bin:$PATH" _sgt_process_table)" == *'701 700 700'* ]]
[[ "$(PS_STYLE=darwin PATH="$TEST_ROOT/bin:$PATH" _sgt_process_table)" == *'801 800 800'* ]]
[[ "$(SGT_PROC_ROOT="$TEST_ROOT/proc" _sgt_process_identity 700)" == 'linux:12345' ]]
if SGT_PROC_ROOT="$TEST_ROOT/empty-proc" PS_STYLE=darwin PATH="$TEST_ROOT/bin:$PATH" \
  _sgt_process_identity 800 >/dev/null 2>&1; then
  printf 'Darwin/BSD second-resolution identity was accepted as exact\n' >&2
  exit 1
fi

# Platforms without a proven exact process-birth identity still launch with the
# inherited marker capability. The zero floor is explicitly platform-tagged;
# retirement must later fail actionable rather than weakening Linux identity.
cat > "$TEST_ROOT/bin/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Darwin\n'
EOF
chmod +x "$TEST_ROOT/bin/uname"
cat > "$TEST_ROOT/bin/lsof" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${LSOF_FIXTURE_OUTPUT:-}" ]]; then
  printf '%s\n' "$LSOF_FIXTURE_OUTPUT"
  exit 0
fi
exit 1
EOF
chmod +x "$TEST_ROOT/bin/lsof"
# shellcheck source=bin/_sgt-lib.sh
source "$ROOT/bin/_sgt-lib.sh"
# shellcheck source=bin/_sgt-process.sh
source "$ROOT/bin/_sgt-process.sh"

# A current marker without durable history is a torn launch publication. A new
# launch must fail before allocating or replacing any evidence.
torn_state="$TEST_ROOT/torn-state"
mkdir -p "$torn_state"
printf 'prior-current-marker\n' > "$torn_state/worker_process_marker"
chmod 600 "$torn_state/worker_process_marker"
cp "$torn_state/worker_process_marker" "$TEST_ROOT/torn-marker.before"
if _sgt_prepare_worker_process_marker "$torn_state"; then
  printf 'marker preparation replaced torn current evidence\n' >&2
  exit 1
fi
cmp "$TEST_ROOT/torn-marker.before" "$torn_state/worker_process_marker"
[[ ! -e "$torn_state/worker_process_markers" ]]
[[ -z "$(find "$torn_state" -maxdepth 1 -name '.worker-process-marker.*' -print -quit)" ]]

_sgt_process_identity() { return 1; }
platform_fail_state="$TEST_ROOT/platform-fail-state"
mkdir -p "$platform_fail_state"
if SGT_TEST_HOOKS=1 SGT_TEST_PROCESS_PLATFORM=Darwin \
  SGT_TEST_MARKER_PLATFORM_WRITE_FAIL=1 \
  _sgt_prepare_worker_process_marker "$platform_fail_state"; then
  printf 'portable marker selected a generation after platform publication failure\n' >&2
  exit 1
fi
[[ ! -e "$platform_fail_state/worker_process_marker" && \
  ! -e "$platform_fail_state/worker_process_marker_platform" ]]
_sgt_worker_process_marker_preflight "$platform_fail_state"
portable_state="$TEST_ROOT/portable-state"
mkdir -p "$portable_state"
PATH="$TEST_ROOT/bin:$PATH" _sgt_prepare_worker_process_marker "$portable_state"
grep -Eq '^[0-9a-f]{32}\|[0-9]+:[0-9]+\|0$' \
  "$portable_state/worker_process_markers"
[[ "$(cat "$portable_state/worker_process_marker_platform")" == \
  'Darwin:no-exact-process-birth' ]]

# A failed portable generation is an all-or-nothing publication. Preserve the
# complete prior current/history/platform tuple byte-for-byte.
cp "$portable_state/worker_process_marker" "$TEST_ROOT/portable-current.before"
cp "$portable_state/worker_process_markers" "$TEST_ROOT/portable-history.before"
cp "$portable_state/worker_process_marker_platform" "$TEST_ROOT/portable-platform.before"
if PATH="$TEST_ROOT/bin:$PATH" SGT_TEST_HOOKS=1 \
  SGT_TEST_PROCESS_PLATFORM=Darwin SGT_TEST_MARKER_PLATFORM_WRITE_FAIL=1 \
  _sgt_prepare_worker_process_marker "$portable_state"; then
  printf 'portable marker preparation ignored injected platform failure\n' >&2
  exit 1
fi
cmp "$TEST_ROOT/portable-current.before" "$portable_state/worker_process_marker"
cmp "$TEST_ROOT/portable-history.before" "$portable_state/worker_process_markers"
cmp "$TEST_ROOT/portable-platform.before" "$portable_state/worker_process_marker_platform"

# A zero-floor generation is portable evidence even when another exact-looking
# current generation is selected; omitting its platform proof is malformed.
zero_floor_state="$TEST_ROOT/zero-floor-state"
mkdir -p "$zero_floor_state"
printf '11111111111111111111111111111111|1:2|198|/gone\n' \
  > "$zero_floor_state/worker_process_marker"
{
  printf '00000000000000000000000000000000|3:4|0\n'
  printf '11111111111111111111111111111111|1:2|123\n'
} > "$zero_floor_state/worker_process_markers"
chmod 600 "$zero_floor_state/worker_process_marker" \
  "$zero_floor_state/worker_process_markers"
if _sgt_worker_process_marker_preflight "$zero_floor_state" >/dev/null 2>&1; then
  printf 'zero-floor history without platform evidence passed preflight\n' >&2
  exit 1
fi

# Strict preflight parses history, membership, digest, and platform floor from
# one descriptor-bound snapshot. A pathname replacement after open is
# ambiguity and must never be followed through a second path read.
swap_state="$TEST_ROOT/history-swap-state"
mkdir -p "$swap_state"
swap_generation=22222222222222222222222222222222
printf '%s|5:6|198|/gone\n' "$swap_generation" \
  > "$swap_state/worker_process_marker"
printf '%s|5:6|123\n' "$swap_generation" \
  > "$swap_state/worker_process_markers"
printf '%s|5:6|0\n' "$swap_generation" \
  > "$swap_state/history-replacement"
chmod 600 "$swap_state/worker_process_marker" \
  "$swap_state/worker_process_markers" "$swap_state/history-replacement"
cat > "$TEST_ROOT/history-swap-hook" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == after-open && "$2" == */worker_process_markers ]] || exit 0
mv "$HISTORY_REPLACEMENT" "$2"
: > "$HISTORY_SWAP_MARKER"
EOF
chmod 700 "$TEST_ROOT/history-swap-hook"
if SGT_TEST_HOOKS=1 _SGT_OWNED_FILE_HOOK_ROOT="$TEST_ROOT" \
  _SGT_OWNED_FILE_OPEN_HOOK="$TEST_ROOT/history-swap-hook" \
  HISTORY_REPLACEMENT="$swap_state/history-replacement" \
  HISTORY_SWAP_MARKER="$TEST_ROOT/history-swap-fired" \
  _sgt_worker_process_marker_preflight "$swap_state" >/dev/null 2>&1; then
  printf 'history pathname swap passed strict marker preflight\n' >&2
  exit 1
fi
[[ -e "$TEST_ROOT/history-swap-fired" ]]
[[ "$(cat "$swap_state/worker_process_markers")" == \
  "$swap_generation|5:6|0" ]]

# Current, history, and portable-platform evidence form one closed tuple. A
# replacement while platform evidence is being opened must invalidate the
# whole preflight instead of combining an old history/current snapshot with a
# newer path state.
cat > "$TEST_ROOT/tuple-swap-hook" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == before-open && "$2" == */worker_process_marker_platform ]] || exit 0
mv "$TUPLE_REPLACEMENT" "$TUPLE_REPLACE_TARGET"
: > "$TUPLE_SWAP_MARKER"
EOF
chmod 700 "$TEST_ROOT/tuple-swap-hook"

cross_history_state="$TEST_ROOT/cross-history-state"
mkdir -p "$cross_history_state"
cross_generation=33333333333333333333333333333333
printf '%s|7:8|198|/gone\n' "$cross_generation" \
  > "$cross_history_state/worker_process_marker"
printf '%s|7:8|0\n' "$cross_generation" \
  > "$cross_history_state/worker_process_markers"
printf 'Darwin:no-exact-process-birth\n' \
  > "$cross_history_state/worker_process_marker_platform"
printf '%s|7:8|123\n' "$cross_generation" \
  > "$cross_history_state/history-replacement"
chmod 600 "$cross_history_state"/*
if SGT_TEST_HOOKS=1 _SGT_OWNED_FILE_HOOK_ROOT="$TEST_ROOT" \
  _SGT_OWNED_FILE_OPEN_HOOK="$TEST_ROOT/tuple-swap-hook" \
  TUPLE_REPLACEMENT="$cross_history_state/history-replacement" \
  TUPLE_REPLACE_TARGET="$cross_history_state/worker_process_markers" \
  TUPLE_SWAP_MARKER="$TEST_ROOT/cross-history-fired" \
  _sgt_worker_process_marker_preflight "$cross_history_state" >/dev/null 2>&1; then
  printf 'cross-snapshot history/platform replacement passed preflight\n' >&2
  exit 1
fi
[[ -e "$TEST_ROOT/cross-history-fired" ]]

cross_current_state="$TEST_ROOT/cross-current-state"
mkdir -p "$cross_current_state"
printf '%s|9:10|198|/gone\n' "$cross_generation" \
  > "$cross_current_state/worker_process_marker"
printf '%s|9:10|0\n' "$cross_generation" \
  > "$cross_current_state/worker_process_markers"
printf 'Darwin:no-exact-process-birth\n' \
  > "$cross_current_state/worker_process_marker_platform"
printf '44444444444444444444444444444444|11:12|198|/other\n' \
  > "$cross_current_state/current-replacement"
chmod 600 "$cross_current_state"/*
if SGT_TEST_HOOKS=1 _SGT_OWNED_FILE_HOOK_ROOT="$TEST_ROOT" \
  _SGT_OWNED_FILE_OPEN_HOOK="$TEST_ROOT/tuple-swap-hook" \
  TUPLE_REPLACEMENT="$cross_current_state/current-replacement" \
  TUPLE_REPLACE_TARGET="$cross_current_state/worker_process_marker" \
  TUPLE_SWAP_MARKER="$TEST_ROOT/cross-current-fired" \
  _sgt_worker_process_marker_preflight "$cross_current_state" >/dev/null 2>&1; then
  printf 'cross-snapshot current/platform replacement passed preflight\n' >&2
  exit 1
fi
[[ -e "$TEST_ROOT/cross-current-fired" ]]
portable_command="$(_sgt_worker_command worker "$portable_state" worktree agent)"
[[ "$portable_command" == exec\ 198\<* ]]

# lsof's open-file identity proves a closed portable generation has no holders,
# so normal retirement and history compaction remain supported without treating
# second-resolution ps output as an exact process identity.
PATH="$TEST_ROOT/bin:$PATH" _sgt_worker_marker_holders "$portable_state" \
  > "$TEST_ROOT/portable-holders"
[[ ! -s "$TEST_ROOT/portable-holders" ]]
PATH="$TEST_ROOT/bin:$PATH" _sgt_retire_worker_marker_holders "$portable_state"
{
  current_marker="$(cat "$portable_state/worker_process_marker")"
  printf '%s|0\n' "${current_marker%|198|*}"
  for generation_number in $(seq 1 63); do
    printf '%032x|1:%s|0\n' "$generation_number" "$generation_number"
  done
} > "$portable_state/worker_process_markers"
chmod 600 "$portable_state/worker_process_markers"
PATH="$TEST_ROOT/bin:$PATH" _sgt_prepare_worker_process_marker "$portable_state"
[[ "$(wc -l < "$portable_state/worker_process_markers")" -eq 1 ]]

# A live portable holder is positive capability evidence. Without a race-free
# process handle on this platform it is preserved and never signalled by PID.
portable_identity="$(cut -d '|' -f2 "$portable_state/worker_process_marker")"
portable_device="${portable_identity%%:*}"
portable_inode="${portable_identity#*:}"
printf -v portable_device_hex '0x%x' "$portable_device"
export LSOF_FIXTURE_OUTPUT="p4242
f198
D$portable_device_hex
i$portable_inode"
holders="$(PATH="$TEST_ROOT/bin:$PATH" \
  _sgt_worker_marker_holders "$portable_state")"
[[ "$holders" == "4242|portable:$portable_identity" ]]
if PATH="$TEST_ROOT/bin:$PATH" \
  _sgt_retire_worker_marker_holders "$portable_state" >/dev/null 2>&1; then
  printf 'portable retirement signalled or waived a live marker holder\n' >&2
  exit 1
fi
printf 'sgt process adapter: ok\n'
