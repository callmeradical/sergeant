#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

goose_cmd="$(bash -lc 'source "$1"; _sgt_agent_run_cmd goose "initial mission"' _ "$ROOT_DIR/bin/_sgt-lib.sh")"
[[ "$goose_cmd" == *"goose run --output-format json -t"* ]]
[[ "$goose_cmd" == *"initial\\ mission"* ]]

redacted="$(bash -lc 'source "$1"; _sgt_redact "graphify 1.0.0 AWS_SECRET_ACCESS_KEY=supersecret; ordinary-text ghp_secretvalue"' _ "$ROOT_DIR/bin/_sgt-lib.sh")"
[[ "$redacted" == *"AWS_SECRET_ACCESS_KEY=[REDACTED]; ordinary-text"* ]]
[[ "$redacted" == *"[REDACTED]"* ]]
[[ "$redacted" != *"supersecret"* ]]
[[ "$redacted" != *"ghp_secretvalue"* ]]
[[ "$redacted" == *"ordinary-text"* ]]

printf 'sgt-lib agent command builder: ok\n'
