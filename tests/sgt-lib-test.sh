#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

goose_cmd="$(bash -lc 'source "$1"; _sgt_agent_run_cmd goose "initial mission"' _ "$ROOT_DIR/bin/_sgt-lib.sh")"
[[ "$goose_cmd" == *"goose run --output-format json -t"* ]]
[[ "$goose_cmd" == *"initial\\ mission"* ]]

redacted="$(bash -lc 'source "$1"; _sgt_redact "graphify 1.0.0 AWS_SECRET_ACCESS_KEY=supersecret; ordinary-text ghp_secretvalue"' _ "$ROOT_DIR/bin/_sgt-lib.sh")"
[[ "$redacted" == *"AWS_SECRET_ACCESS_KEY=[REDACTED]; ordinary-text"* ]]
[[ "$redacted" == *"[REDACTED]"* ]]
[[ "$redacted" != *"supersecret"* ]]
[[ "$redacted" != *"ghp_secretvalue"* ]]
[[ "$redacted" == *"ordinary-text"* ]]

redacted="$(bash -lc 'source "$1"; _sgt_redact "AWS_SECRET_ACCESS_KEY=supersecret PATH=/usr/bin API_TOKEN=secondsecret"' _ "$ROOT_DIR/bin/_sgt-lib.sh")"
[[ "$redacted" == "AWS_SECRET_ACCESS_KEY=[REDACTED] PATH=/usr/bin API_TOKEN=[REDACTED]" ]]
[[ "$redacted" != *"supersecret"* ]]
[[ "$redacted" != *"secondsecret"* ]]
[[ "$redacted" == *"PATH=/usr/bin"* ]]

redacted="$(bash -lc 'source "$1"; _sgt_redact "API_TOKEN=secret ordinary-text"' _ "$ROOT_DIR/bin/_sgt-lib.sh")"
[[ "$redacted" == "API_TOKEN=[REDACTED] ordinary-text" ]]
[[ "$redacted" != *"secret"* ]]
[[ "$redacted" == *"ordinary-text"* ]]

redacted="$(bash -lc 'source "$1"; _sgt_redact "API_TOKEN=top secret-value"' _ "$ROOT_DIR/bin/_sgt-lib.sh")"
[[ "$redacted" == "API_TOKEN=[REDACTED] secret-value" ]]
[[ "$redacted" != *"top"* ]]
[[ "$redacted" == *"secret-value"* ]]

redacted="$(bash -lc 'source "$1"; _sgt_redact '\''API_TOKEN="top secret-value" ordinary-text PATH=/usr/bin'\''' _ "$ROOT_DIR/bin/_sgt-lib.sh")"
[[ "$redacted" == "API_TOKEN=[REDACTED] ordinary-text PATH=/usr/bin" ]]
[[ "$redacted" != *"top"* ]]
[[ "$redacted" != *"secret-value"* ]]
[[ "$redacted" == *"ordinary-text PATH=/usr/bin"* ]]

redacted="$(bash -lc 'source "$1"; _sgt_redact "API_TOKEN='\''top secret-value'\'' ordinary-text"' _ "$ROOT_DIR/bin/_sgt-lib.sh")"
[[ "$redacted" == "API_TOKEN=[REDACTED] ordinary-text" ]]
[[ "$redacted" != *"top"* ]]
[[ "$redacted" != *"secret-value"* ]]
[[ "$redacted" == *"ordinary-text"* ]]

cat > "$TEST_TMP/python3" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
chmod +x "$TEST_TMP/python3"

redacted="$(PATH="$TEST_TMP:/bin" bash -lc 'source "$1"; _sgt_redact '\''API_TOKEN="top secret-value" ordinary-text AWS_SECRET_ACCESS_KEY=supersecret PATH=/usr/bin'\''' _ "$ROOT_DIR/bin/_sgt-lib.sh")"
[[ "$redacted" == "API_TOKEN=[REDACTED] ordinary-text AWS_SECRET_ACCESS_KEY=[REDACTED] PATH=/usr/bin" ]]
[[ "$redacted" != *"top secret-value"* ]]
[[ "$redacted" != *"secret-value"* ]]
[[ "$redacted" != *"supersecret"* ]]
[[ "$redacted" == *"ordinary-text AWS_SECRET_ACCESS_KEY=[REDACTED] PATH=/usr/bin"* ]]

redacted="$(PATH="$TEST_TMP:/bin" bash -lc 'source "$1"; _sgt_redact '\''API_TOKEN=foo"bar baz"qux PATH=/usr/bin'\''' _ "$ROOT_DIR/bin/_sgt-lib.sh")"
[[ "$redacted" == "API_TOKEN=[REDACTED] PATH=/usr/bin" ]]
[[ "$redacted" != *'foo"bar baz"qux'* ]]
[[ "$redacted" != *'baz"qux'* ]]
[[ "$redacted" == *"PATH=/usr/bin"* ]]

redacted="$(PATH="$TEST_TMP:/bin" bash -lc 'source "$1"; _sgt_redact '\''API_TOKEN="unterminated secret value ordinary-text'\''' _ "$ROOT_DIR/bin/_sgt-lib.sh")"
[[ "$redacted" == "API_TOKEN=[REDACTED]" ]]
[[ "$redacted" != *"unterminated"* ]]
[[ "$redacted" != *"ordinary-text"* ]]

printf 'sgt-lib agent command builder: ok\n'
