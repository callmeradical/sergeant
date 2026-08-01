#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$BASH" -n \
  "$ROOT_DIR/bin/_sgt-lib.sh" \
  "$ROOT_DIR/bin/sgt-interactive-worker" \
  "$ROOT_DIR/bin/sgt-watch" \
  "$ROOT_DIR/bin/sgt-respond" \
  "$ROOT_DIR/bin/sgt-recover"

printf 'Sergeant terminal lifecycle parses under Bash 3.2: ok\n'
