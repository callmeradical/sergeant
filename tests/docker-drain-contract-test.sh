#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
TEST_BASH="${BASH:-$(command -v bash)}"
trap 'rm -rf "$TEST_ROOT"' EXIT

grep -Eq '^[[:space:]]+python3([[:space:]\\]|$)' "$ROOT_DIR/Dockerfile.test" || {
  printf 'Dockerfile.test does not install python3\n' >&2
  exit 1
}
grep -Fq 'command -v python3' "$ROOT_DIR/Dockerfile.test" || {
  printf 'Dockerfile.test does not verify python3 availability\n' >&2
  exit 1
}
grep -Fq 'apk add --no-cache python3' "$ROOT_DIR/mise.toml" || {
  printf 'Bash 3.2 Docker pass does not install python3\n' >&2
  exit 1
}
grep -Eq 'apk add --no-cache python3.*command -v python3' "$ROOT_DIR/mise.toml" || {
  printf 'Bash 3.2 Docker pass does not verify python3 availability\n' >&2
  exit 1
}
mkdir -p "$TEST_ROOT/bin"
ln -s "$(command -v dirname)" "$TEST_ROOT/bin/dirname"
set +e
missing_output="$(PATH="$TEST_ROOT/bin" "$TEST_BASH" \
  "$ROOT_DIR/tests/run-drain-tests.sh" 2>&1)"
missing_status=$?
set -e
if [[ "$missing_status" -eq 0 ||
      "$missing_output" != *'Required test tool is unavailable: python3'* ]]; then
  printf 'drain runner did not fail explicitly when python3 was unavailable\n' >&2
  exit 1
fi

printf 'Docker drain Python contract: ok\n'
