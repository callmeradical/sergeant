#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export SERGEANT_CONFIG="$TEST_ROOT/config"
export SERGEANT_DRAIN_DIR="$TEST_ROOT/drain"
export SERGEANT_FLEET="$TEST_ROOT/fleet-link"
mkdir -p "$SERGEANT_CONFIG" "$SERGEANT_DRAIN_DIR" "$TEST_ROOT/fake-bin" \
  "$TEST_ROOT/fleet-target"
ln -s "$TEST_ROOT/fleet-target" "$SERGEANT_FLEET"

cat > "$TEST_ROOT/fake-bin/stat" <<'EOF'
#!/usr/bin/env bash
path="${!#}"
[[ -e "$path" ]] || exit 2
if [[ "$*" == *" -c "* && "${FAKE_BSD_STAT:-}" == 1 ]]; then
  exit 1
fi
if [[ " $* " == *" -L "* ]]; then
  printf '200\n'
else
  printf '100\n'
fi
EOF
chmod +x "$TEST_ROOT/fake-bin/stat"
export PATH="$TEST_ROOT/fake-bin:$PATH"

# shellcheck source=bin/_sgt-lib.sh
source "$ROOT_DIR/bin/_sgt-lib.sh"

[[ "$(_path_device "$SERGEANT_FLEET")" == 200 ]]
[[ "$(_path_device "$SERGEANT_FLEET/not-yet-created/child")" == 200 ]]
[[ "$(FAKE_BSD_STAT=1 _path_device "$SERGEANT_FLEET")" == 200 ]]
[[ "$(FAKE_BSD_STAT=1 _path_device "$SERGEANT_FLEET/not-yet-created/child")" == 200 ]]

ln -s "$TEST_ROOT/missing-target" "$TEST_ROOT/dangling-link"
if _path_device "$TEST_ROOT/dangling-link" >/dev/null; then
  printf 'FAIL: dangling symlink produced a device\n' >&2
  exit 1
fi

printf 'PASS: symlink targets determine filesystem device on GNU and BSD stat\n'
