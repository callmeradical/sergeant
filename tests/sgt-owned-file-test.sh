#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fake_bin="$TEST_ROOT/bin"
mkdir -p "$fake_bin"
real_stat="$(command -v stat)"
real_uname="$(command -v uname)"
real_chmod="$(command -v chmod)"
real_python="$(command -v python3)"
if "$real_stat" -c '%a' -- "$ROOT_DIR/bin/_sgt-lib.sh" >/dev/null 2>&1; then
  path_mode_format='%a'
else
  path_mode_format='%Lp'
fi

cat > "$fake_bin/stat" <<'EOF'
#!/usr/bin/env bash
last="${!#}"
if [[ "$last" == /dev/fd/* && "${TEST_DARWIN_FD_MODE:-}" == 1 && \
  ( "$*" == *'%a'* || "$*" == *'%Lp'* ) ]]; then
  mode="$("$REAL_STAT" -L -c '%a' -- "$last" 2>/dev/null || \
    "$REAL_STAT" -L -f '%Lp' "$last")" || exit 1
  case "$mode" in
    600) mode=400 ;;
    640|660) mode=440 ;;
    644|664) mode=444 ;;
  esac
  printf '%s\n' "$mode"
  exit 0
fi
if [[ "$last" == /dev/fd/* && -n "${TEST_FD_MODE:-}" && \
  ( "$*" == *'%a'* || "$*" == *'%Lp'* ) ]]; then
  printf '%s\n' "$TEST_FD_MODE"
  exit 0
fi
if [[ -n "${TEST_PATH_UID:-}" && "$last" == "${TEST_OWNER_PATH:-}" && \
  "$*" == *'%u:%d:%i'* ]]; then
  identity="$("$REAL_STAT" -c '%u:%d:%i' -- "$last" 2>/dev/null || \
    "$REAL_STAT" -f '%u:%d:%i' "$last")" || exit 1
  printf '%s:%s\n' "$TEST_PATH_UID" "${identity#*:}"
  exit 0
fi
if [[ -n "${TEST_RACE_PATH:-}" && "$last" == "$TEST_RACE_PATH" && \
  "$*" == *"$TEST_PATH_MODE_FORMAT"* ]]; then
  count=0
  [[ ! -f "$TEST_RACE_COUNTER" ]] || count="$(cat "$TEST_RACE_COUNTER")"
  count=$((count + 1))
  printf '%s\n' "$count" > "$TEST_RACE_COUNTER"
  if [[ "$count" -eq "${TEST_RACE_TRIGGER:-2}" ]]; then
    output="$("$REAL_STAT" "$@")" || exit 1
    rm -f "$last"
    mv "$TEST_RACE_REPLACEMENT" "$last"
    printf '%s\n' "$output"
    exit 0
  fi
fi
exec "$REAL_STAT" "$@"
EOF
cat > "$fake_bin/uname" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${TEST_SYSTEM:-Linux}"
EOF
cat > "$fake_bin/python3" <<'EOF'
#!/usr/bin/env bash
identity="$("$REAL_PYTHON" "$@")" || exit 1
uid="${identity%%:*}"
device_inode="${identity#*:}"
device="${device_inode%:*}"
inode="${identity##*:}"
[[ -z "${TEST_FD_UID:-}" ]] || uid="$TEST_FD_UID"
[[ -z "${TEST_FD_DEVICE:-}" ]] || device="$TEST_FD_DEVICE"
[[ -z "${TEST_FD_INODE:-}" ]] || inode="$TEST_FD_INODE"
if [[ -n "${TEST_FD_RACE_COUNTER:-}" ]]; then
  count=0
  [[ ! -f "$TEST_FD_RACE_COUNTER" ]] || count="$(cat "$TEST_FD_RACE_COUNTER")"
  count=$((count + 1))
  printf '%s\n' "$count" > "$TEST_FD_RACE_COUNTER"
  if [[ "$count" -eq "${TEST_FD_RACE_TRIGGER:-2}" ]]; then
    rm -f "$TEST_FD_RACE_PATH"
    mv "$TEST_FD_RACE_REPLACEMENT" "$TEST_FD_RACE_PATH"
  fi
fi
printf '%s:%s:%s\n' "$uid" "$device" "$inode"
EOF
cat > "$fake_bin/chmod" <<'EOF'
#!/usr/bin/env bash
last="${!#}"
if [[ "$last" == /dev/fd/* && -n "${TEST_CHMOD_RACE_PATH:-}" ]]; then
  rm -f "$TEST_CHMOD_RACE_PATH"
  printf 'replacement-value\n' > "$TEST_CHMOD_RACE_PATH"
  "$REAL_CHMOD" 664 "$TEST_CHMOD_RACE_PATH"
  identity="$("$REAL_STAT" -c '%u:%d:%i' -- "$TEST_CHMOD_RACE_PATH" 2>/dev/null || \
    "$REAL_STAT" -f '%u:%d:%i' "$TEST_CHMOD_RACE_PATH")" || exit 1
  printf '%s\n' "$identity" > "$TEST_CHMOD_RACE_IDENTITY"
  : > "$TEST_CHMOD_RACE_MARKER"
fi
exec "$REAL_CHMOD" "$@"
EOF
chmod +x "$fake_bin/stat" "$fake_bin/uname" "$fake_bin/python3" "$fake_bin/chmod"
export REAL_STAT="$real_stat" REAL_UNAME="$real_uname" REAL_CHMOD="$real_chmod"
export REAL_PYTHON="$real_python"
export TEST_PATH_MODE_FORMAT="$path_mode_format"

owned="$TEST_ROOT/owned"
printf 'owned-value\n' > "$owned"
chmod 600 "$owned"

output="$(PATH="$fake_bin:$PATH" TEST_SYSTEM=Darwin TEST_FD_MODE=400 \
  bash -c 'source "$1"; _sgt_read_owned_file "$2"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$owned")"
[[ "$output" == 'owned-value' ]]

for fd_mode in 000 200 401 440 444 640 777; do
  if PATH="$fake_bin:$PATH" TEST_SYSTEM=Darwin TEST_FD_MODE="$fd_mode" \
    bash -c 'source "$1"; _sgt_read_owned_file "$2"' _ \
    "$ROOT_DIR/bin/_sgt-lib.sh" "$owned" >/dev/null 2>&1; then
    printf 'accepted unsafe Darwin descriptor mode: %s\n' "$fd_mode" >&2
    exit 1
  fi
done

if PATH="$fake_bin:$PATH" TEST_SYSTEM=Linux TEST_FD_MODE=400 \
  bash -c 'source "$1"; _sgt_read_owned_file "$2"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$owned" >/dev/null 2>&1; then
  printf 'accepted Darwin descriptor mode on non-Darwin system\n' >&2
  exit 1
fi

if PATH="$fake_bin:$PATH" TEST_SYSTEM=Darwin TEST_FD_MODE=400 TEST_FD_INODE=0 \
  bash -c 'source "$1"; _sgt_read_owned_file "$2"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$owned" >/dev/null 2>&1; then
  printf 'accepted mismatched descriptor inode\n' >&2
  exit 1
fi

owned_identity="$("$real_stat" -c '%u:%d:%i' -- "$owned" 2>/dev/null || \
  "$real_stat" -f '%u:%d:%i' "$owned")"
owned_device_inode="${owned_identity#*:}"
foreign_device=$((${owned_device_inode%:*} + 1))
if PATH="$fake_bin:$PATH" TEST_SYSTEM=Darwin TEST_FD_MODE=400 \
  TEST_FD_DEVICE="$foreign_device" \
  bash -c 'source "$1"; _sgt_read_owned_file "$2"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$owned" >/dev/null 2>&1; then
  printf 'accepted mismatched descriptor device\n' >&2
  exit 1
fi

owned_link="$TEST_ROOT/owned-link"
ln -s "$owned" "$owned_link"
if PATH="$fake_bin:$PATH" TEST_SYSTEM=Darwin TEST_FD_MODE=400 \
  bash -c 'source "$1"; _sgt_read_owned_file "$2"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$owned_link" >/dev/null 2>&1; then
  printf 'accepted symlinked owned-file path\n' >&2
  exit 1
fi

foreign_uid=$((EUID + 1))
if PATH="$fake_bin:$PATH" TEST_SYSTEM=Darwin TEST_FD_MODE=400 \
  TEST_PATH_UID="$foreign_uid" TEST_OWNER_PATH="$owned" \
  bash -c 'source "$1"; _sgt_read_owned_file "$2"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$owned" >/dev/null 2>&1; then
  printf 'accepted path metadata owned by another user\n' >&2
  exit 1
fi

if PATH="$fake_bin:$PATH" TEST_SYSTEM=Darwin TEST_FD_MODE=400 \
  TEST_FD_UID="$foreign_uid" \
  bash -c 'source "$1"; _sgt_read_owned_file "$2"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$owned" >/dev/null 2>&1; then
  printf 'accepted descriptor metadata owned by another user\n' >&2
  exit 1
fi

legacy="$TEST_ROOT/legacy-owned"
printf 'legacy-value\n' > "$legacy"
chmod 664 "$legacy"
output="$(PATH="$fake_bin:$PATH" TEST_SYSTEM=Darwin TEST_DARWIN_FD_MODE=1 \
  bash -c 'source "$1"; _sgt_read_matching_legacy_pane_identity "$2" "$3"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$legacy" legacy-value)"
[[ "$output" == 'legacy-value' ]]
legacy_mode="$("$real_stat" -c '%a' -- "$legacy" 2>/dev/null || \
  "$real_stat" -f '%Lp' "$legacy")"
[[ "$legacy_mode" == 600 ]]

printf 'legacy-value\n' > "$legacy"
chmod 664 "$legacy"
chmod_race_marker="$TEST_ROOT/chmod-race-marker"
chmod_race_identity="$TEST_ROOT/chmod-race-identity"
if PATH="$fake_bin:$PATH" TEST_SYSTEM=Darwin TEST_DARWIN_FD_MODE=1 \
  TEST_CHMOD_RACE_PATH="$legacy" TEST_CHMOD_RACE_MARKER="$chmod_race_marker" \
  TEST_CHMOD_RACE_IDENTITY="$chmod_race_identity" \
  bash -c 'source "$1"; _sgt_read_matching_legacy_pane_identity "$2" "$3"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$legacy" legacy-value >/dev/null 2>&1; then
  printf 'legacy migration overwrote a publication-boundary replacement\n' >&2
  exit 1
fi
[[ -e "$chmod_race_marker" && "$(cat "$legacy")" == 'replacement-value' ]]
legacy_mode="$("$real_stat" -c '%a' -- "$legacy" 2>/dev/null || \
  "$real_stat" -f '%Lp' "$legacy")"
legacy_identity="$("$real_stat" -c '%u:%d:%i' -- "$legacy" 2>/dev/null || \
  "$real_stat" -f '%u:%d:%i' "$legacy")"
[[ "$legacy_mode" == 664 && "$legacy_identity" == "$(cat "$chmod_race_identity")" ]]
for candidate in "$legacy".tmp.*; do
  [[ ! -e "$candidate" ]]
done

printf 'legacy-value\n' > "$legacy"
chmod 664 "$legacy"
final_replacement="$TEST_ROOT/final-reread-replacement"
printf 'legacy-value\n' > "$final_replacement"
chmod 600 "$final_replacement"
final_replacement_identity="$("$real_stat" -c '%u:%d:%i' -- "$final_replacement" 2>/dev/null || \
  "$real_stat" -f '%u:%d:%i' "$final_replacement")"
final_race_counter="$TEST_ROOT/final-reread-race-counter"
if PATH="$fake_bin:$PATH" TEST_SYSTEM=Darwin TEST_DARWIN_FD_MODE=1 \
  TEST_FD_RACE_PATH="$legacy" TEST_FD_RACE_REPLACEMENT="$final_replacement" \
  TEST_FD_RACE_COUNTER="$final_race_counter" TEST_FD_RACE_TRIGGER=2 \
  bash -c 'source "$1"; _sgt_read_matching_legacy_pane_identity "$2" "$3"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$legacy" legacy-value >/dev/null 2>&1; then
  printf 'legacy migration accepted a replacement during its final reread\n' >&2
  exit 1
fi
legacy_mode="$("$real_stat" -c '%a' -- "$legacy" 2>/dev/null || \
  "$real_stat" -f '%Lp' "$legacy")"
legacy_identity="$("$real_stat" -c '%u:%d:%i' -- "$legacy" 2>/dev/null || \
  "$real_stat" -f '%u:%d:%i' "$legacy")"
[[ "$(cat "$legacy")" == 'legacy-value' && "$legacy_mode" == 600 ]]
[[ "$legacy_identity" == "$final_replacement_identity" ]]

race_path="$TEST_ROOT/race-owned"
race_replacement="$TEST_ROOT/race-replacement"
race_counter="$TEST_ROOT/race-counter"
printf 'original\n' > "$race_path"
printf 'replacement\n' > "$race_replacement"
chmod 600 "$race_path" "$race_replacement"
if PATH="$fake_bin:$PATH" TEST_SYSTEM=Darwin TEST_FD_MODE=400 \
  TEST_RACE_PATH="$race_path" TEST_RACE_REPLACEMENT="$race_replacement" \
  TEST_RACE_COUNTER="$race_counter" \
  bash -c 'source "$1"; _sgt_read_owned_file "$2"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$race_path" >/dev/null 2>&1; then
  printf 'accepted path replacement during owned-file read\n' >&2
  exit 1
fi
[[ "$(cat "$race_path")" == 'replacement' ]]

release="$TEST_ROOT/release"
release_owner="$TEST_ROOT/release-owner"
printf 'paired-release\n' > "$release"
chmod 600 "$release"
ln "$release" "$release_owner"

output="$(PATH="$fake_bin:$PATH" TEST_SYSTEM=Darwin TEST_FD_MODE=400 \
  bash -c 'source "$1"; _sgt_read_same_owned_files "$2" "$3"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$release" "$release_owner")"
[[ "$output" == 'paired-release' ]]

distinct="$TEST_ROOT/distinct-release"
printf 'paired-release\n' > "$distinct"
chmod 600 "$distinct"
if PATH="$fake_bin:$PATH" TEST_SYSTEM=Darwin TEST_FD_MODE=400 \
  bash -c 'source "$1"; _sgt_read_same_owned_files "$2" "$3"' _ \
  "$ROOT_DIR/bin/_sgt-lib.sh" "$release" "$distinct" >/dev/null 2>&1; then
  printf 'accepted equal content from distinct files\n' >&2
  exit 1
fi

printf 'sgt owned-file descriptor validation: ok\n'
