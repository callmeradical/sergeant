#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
forbidden="baby""driver|--""remote|remote-""baby""driver|remote_""project_dir|remote_""session|remote_""window|remote_""td_task|remote_""response_pending"

if grep -R -n -E -- "$forbidden" \
  "$ROOT/AGENTS.md" "$ROOT/README.md" "$ROOT/bin" "$ROOT/mise.toml" \
  "$ROOT/schema" "$ROOT/skills" "$ROOT/tests"; then
  echo "FAIL: obsolete remote execution contract remains" >&2
  exit 1
fi

echo "PASS: distribution has no remote execution contract"
