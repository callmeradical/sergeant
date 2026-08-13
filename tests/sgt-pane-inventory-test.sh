#!/usr/bin/env bash
# Exact parser regression for replacement pane inventory snapshots.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
export TMPDIR="$TEST_ROOT"

# shellcheck source=bin/_sgt-response-lock.sh
source "$ROOT_DIR/bin/_sgt-response-lock.sh"

inventory="$TEST_ROOT/inventory"
tmux() {
  [[ "$1" == list-panes ]]
  cat "$inventory"
}
_sgt_replacement_pane_auth() {
  [[ "$1" == %9 ]]
  printf '%%9|123|proc:456|%s|%s\n' "$2" "$3"
}

token=11112222333344445555666677778888
role=worker:inventory

: > "$inventory"
set +e
_sgt_replacement_discover_pane target "$token" "$role" spawning "" "" >/dev/null
status=$?
set -e
[[ "$status" == 1 ]]

for shape in leading interior trailing; do
  case "$shape" in
    leading) printf '\n%%9|target\n' > "$inventory" ;;
    interior) printf '%%8|other\n\n%%9|target\n' > "$inventory" ;;
    trailing) printf '%%9|target\n\n' > "$inventory" ;;
  esac
  set +e
  _sgt_replacement_discover_pane target "$token" "$role" spawning "" "" >/dev/null
  status=$?
  set -e
  [[ "$status" == 2 ]] || {
    printf '%s blank inventory row returned %s, expected 2\n' "$shape" "$status" >&2
    exit 1
  }
done

printf '%%9|target\n' > "$inventory"
[[ "$(_sgt_replacement_discover_pane target "$token" "$role" spawning "" "")" == %9 ]]
if find "$TEST_ROOT" -maxdepth 1 -name 'sgt-pane-inventory.*' -print -quit | grep -q .; then
  printf 'inventory snapshot temporary file leaked\n' >&2
  exit 1
fi

printf 'exact replacement pane inventory parsing: ok\n'
