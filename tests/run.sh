#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

shopt -s nullglob
for test_file in "$ROOT"/tests/*_test.sh "$ROOT"/tests/*-test.sh; do
  echo "==> $(basename "$test_file")"
  bash "$test_file"
done
shopt -u nullglob
