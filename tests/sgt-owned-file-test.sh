#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fake_bin="$TEST_ROOT/bin"
mkdir -p "$fake_bin"
real_stat="$(command -v stat)"
real_uname="$(command -v uname)"
if "$real_stat" -c '%a' -- "$ROOT_DIR/bin/_sgt-lib.sh" >/dev/null 2>&1; then
  path_mode_format='%a'
else
  path_mode_format='%Lp'
fi

cat > "$fake_bin/stat" <<'EOF'
#!/usr/bin/env bash
last="${!#}"
if [[ "$last" == /dev/fd/* && -n "${TEST_FD_MODE:-}" && \
  ( "$*" == *'%a'* || "$*" == *'%Lp'* ) ]]; then
  printf '%s\n' "$TEST_FD_MODE"
  exit 0
fi
if [[ "$last" == /dev/fd/* && "$*" == *'%u:%d:%i'* && \
  ( -n "${TEST_FD_UID:-}" || -n "${TEST_FD_INODE:-}" ) ]]; then
  identity="$("$REAL_STAT" -L -c '%u:%d:%i' -- "$last" 2>/dev/null || \
    "$REAL_STAT" -L -f '%u:%d:%i' "$last")" || exit 1
  uid="${identity%%:*}"
  device_inode="${identity#*:}"
  device="${device_inode%:*}"
  inode="${identity##*:}"
  [[ -z "${TEST_FD_UID:-}" ]] || uid="$TEST_FD_UID"
  [[ -z "${TEST_FD_INODE:-}" ]] || inode="$TEST_FD_INODE"
  printf '%s:%s:%s\n' "$uid" "$device" "$inode"
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
  if [[ "$count" -eq 2 ]]; then
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
chmod +x "$fake_bin/stat" "$fake_bin/uname"
export REAL_STAT="$real_stat" REAL_UNAME="$real_uname"
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
