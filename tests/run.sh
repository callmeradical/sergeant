#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for test_file in "$ROOT"/tests/*_test.sh; do
  echo "==> $(basename "$test_file")"
  bash "$test_file"
done
