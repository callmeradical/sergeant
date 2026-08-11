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
printf 'sgt process adapter: ok\n'
