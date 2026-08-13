#!/usr/bin/env bash
# Regression: sgt-dispatch pins an explicit provider/model/variant tuple and
# records it as durable non-secret launch evidence (GH #177).
#
# Seam under test: the sgt-dispatch CLI.  Observations are its exit status,
# its stderr, and the durable fleet files it writes.  Nothing inspects
# sgt-dispatch internals.
#
# Validation must run BEFORE any mutation, so every rejection case asserts
# that no new fleet task directory and no tmux log were created.

set -euo pipefail
export TMUX=fixture TMUX_PANE=%11

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/config" "$TEST_ROOT/fleet" "$TEST_ROOT/fake-bin" "$TEST_ROOT/repo"
chmod 700 "$TEST_ROOT/fleet"

cat > "$TEST_ROOT/config/test.yaml" <<EOF
name: test
repos:
  - name: app
    path: $TEST_ROOT/repo
EOF

cat > "$TEST_ROOT/fake-bin/tmux" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "display-message" ]] || printf '%s\n' "$*" >> "$TMUX_LOG"
case "$1" in
  has-session) exit 0 ;;
  display-message)
    for repo_state in "$SERGEANT_FLEET"/*/*; do
      [[ -d "$repo_state" ]] || continue
      [[ -f "$repo_state/notification_id" && -f "$repo_state/worktree" ]] || continue
      nonce="$(cat "$repo_state/notification_target" 2>/dev/null || true)"
      notification_id="$(cat "$repo_state/notification_id" 2>/dev/null || true)"
      [[ "$nonce" =~ ^[a-f0-9]{32}$ && -n "$notification_id" ]] || continue
      target_dir="$repo_state/notifications/$notification_id/targets/$nonce"
      token="$notification_id|$nonce"
      printf '%s\n' "$token" > "$target_dir/accepted"
      printf '%s\n' "$token" > "$target_dir/delivered"
    done
    if [[ "$*" == *'-t %11'* ]]; then
      printf '0|%%11|1111|111111|coordinator-command\n'
    else
      printf '0|%%42|4242|123456|fixture-worker-command\n'
    fi
    ;;
  new-window) printf '%%42\n' ;;
  send-keys) ;;
  kill-pane) ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/tmux"

cat > "$TEST_ROOT/fake-bin/td" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then printf 'td version v0.1.0\n'; exit 0; fi
if [[ "${1:-}" == "create" && "${2:-}" == "--help" ]]; then
  printf '%s\n' '--description --json --work-dir'; exit 0
fi
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-dir|-w) shift 2 ;;
    --json) shift ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"
case "${1:-}" in
  list) printf '[]\n' ;;
  create) printf '{"id":"td-app-1"}\n' ;;
  delete) printf '{"id":"td-app-1","deleted":true}\n' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/td"

cat > "$TEST_ROOT/fake-bin/sgt-review-findings" <<'EOF'
#!/usr/bin/env bash
printf 'Usage: sgt-review-findings --axis standards|spec|readiness --severity error|warning|info\n' >&2
exit 2
EOF
chmod +x "$TEST_ROOT/fake-bin/sgt-review-findings"

cat > "$TEST_ROOT/fake-bin/opencode" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "models" ]]; then
  provider="${2:-}"
  cat <<MODELS
$provider/claude-opus-5
{
  "id": "claude-opus-5",
  "providerID": "$provider",
  "variants": {
    $(if [[ "${OPENCODE_TEST_NO_MEDIUM:-}" == 1 ]]; then printf '"low": {}'; else printf '"medium": {}'; fi),
    "high": {}
  }
}
MODELS
  exit 0
fi
if [[ "${1:-}" == "debug" && "${2:-}" == "agent" ]]; then
  [[ "${OPENCODE_TEST_UNVERIFIABLE:-}" != 1 ]] || exit 1
  model="$(sed -n 's/.*"model": "\([^"]*\)".*/\1/p' "$OPENCODE_CONFIG")"
  variant="$(sed -n 's/.*"variant": "\([^"]*\)".*/\1/p' "$OPENCODE_CONFIG")"
  variant="${OPENCODE_TEST_RUNTIME_VARIANT:-$variant}"
  provider="${model%%/*}"
  model_id="${model#*/}"
  printf '{"model":{"providerID":"%s","modelID":"%s"},"variant":"%s"}\n' \
    "$provider" "$model_id" "$variant"
  exit 0
fi
exit 0
EOF
chmod +x "$TEST_ROOT/fake-bin/opencode"
for agent in goose claude; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_ROOT/fake-bin/$agent"
  chmod +x "$TEST_ROOT/fake-bin/$agent"
done

git -C "$TEST_ROOT/repo" init -q
git -C "$TEST_ROOT/repo" config user.name Test
git -C "$TEST_ROOT/repo" config user.email test@example.invalid
touch "$TEST_ROOT/repo/README.md"
git -C "$TEST_ROOT/repo" add README.md
git -C "$TEST_ROOT/repo" commit -qm fixture
git -C "$TEST_ROOT/repo" remote add origin git@github.com:org/test.git

_fleet_task_count() {
  find "$TEST_ROOT/fleet" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '
}

# _dispatch <log-name> <brief> [extra sgt-dispatch args...]
# Runs sgt-dispatch with the fixture environment.  Extra env is passed through
# the caller's environment, so callers wrap with `env` when they need it.
_dispatch() {
  local log_name="$1" brief="$2"
  shift 2
  PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/$log_name.log" \
  SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
  SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-dispatch" test "$brief" --repos app "$@"
}

# _dispatch_output <log-name> <brief> [args...]
# Runs a dispatch expected to fail and prints its combined output.
_dispatch_output() {
  local log_name="$1" brief="$2"
  shift 2
  set +e
  _dispatch "$log_name" "$brief" "$@" 2>&1
  set -e
}

# _reject <log-name> <brief> <expected-stderr-substring> [extra args...]
# Asserts sgt-dispatch fails, says why, and mutates nothing.
_reject() {
  local log_name="$1" brief="$2" expected="$3"
  shift 3
  local before after status output
  before="$(_fleet_task_count)"
  rm -f "$TEST_ROOT/$log_name.log"
  set +e
  output="$(_dispatch "$log_name" "$brief" "$@" 2>&1)"
  status=$?
  set -e
  after="$(_fleet_task_count)"
  if [[ "$status" -eq 0 ]]; then
    printf 'FAIL: expected rejection for %s but dispatch succeeded\n' "$log_name" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected"* ]]; then
    printf 'FAIL: %s diagnostic missing %q; got:\n%s\n' "$log_name" "$expected" "$output" >&2
    exit 1
  fi
  if [[ "$before" != "$after" ]]; then
    printf 'FAIL: %s created fleet state before validation (%s -> %s)\n' \
      "$log_name" "$before" "$after" >&2
    exit 1
  fi
  if [[ -e "$TEST_ROOT/$log_name.log" ]]; then
    printf 'FAIL: %s reached tmux before validation\n' "$log_name" >&2
    exit 1
  fi
}

# ── 1. An explicit tuple is accepted and recorded ─────────────────────────────

_dispatch explicit 'Explicit tuple' --model anthropic/claude-opus-5 >/dev/null
state="$(printf '%s\n' "$TEST_ROOT"/fleet/explicit-tuple-*/app)"
[[ "$(cat "$state/agent_model")" == "anthropic/claude-opus-5" ]] || {
  printf 'FAIL: agent_model not recorded (got %q)\n' \
    "$(cat "$state/agent_model" 2>/dev/null || true)" >&2
  exit 1
}
[[ "$(cat "$state/agent_model_source")" == "flag" ]] || {
  printf 'FAIL: agent_model_source not "flag" (got %q)\n' \
    "$(cat "$state/agent_model_source" 2>/dev/null || true)" >&2
  exit 1
}
# The executable record is preserved alongside the new tuple record.
[[ "$(cat "$state/agent")" == "${SERGEANT_AGENT:-opencode}" ]]

# ── 2. SERGEANT_MODEL supplies the tuple when no flag is given ────────────────

env SERGEANT_MODEL=anthropic/claude-sonnet-5 \
  PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/env.log" \
  SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
  SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Env tuple' --repos app >/dev/null
state="$(printf '%s\n' "$TEST_ROOT"/fleet/env-tuple-*/app)"
[[ "$(cat "$state/agent_model")" == "anthropic/claude-sonnet-5" ]]
[[ "$(cat "$state/agent_model_source")" == "env" ]]

# ── 3. --model overrides SERGEANT_MODEL ───────────────────────────────────────

env SERGEANT_MODEL=anthropic/claude-sonnet-5 \
  PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/precedence.log" \
  SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
  SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Precedence tuple' --repos app \
  --model openai/gpt-5.2 >/dev/null
state="$(printf '%s\n' "$TEST_ROOT"/fleet/precedence-tuple-*/app)"
[[ "$(cat "$state/agent_model")" == "openai/gpt-5.2" ]]
[[ "$(cat "$state/agent_model_source")" == "flag" ]]

# ── 4. No pin records an explicit unpinned tuple, never an empty file ─────────

_dispatch unpinned 'Unpinned tuple' >/dev/null
state="$(printf '%s\n' "$TEST_ROOT"/fleet/unpinned-tuple-*/app)"
[[ "$(cat "$state/agent_model")" == "unpinned" ]]
[[ "$(cat "$state/agent_model_source")" == "unpinned" ]]

# ── 5. Malformed tuples are rejected before any mutation ─────────────────────

_reject missing-provider 'Missing provider' \
  'model must be provider/model' --model claude-opus-5
_reject empty-provider 'Empty provider' \
  'model must be provider/model' --model /claude-opus-5
_reject empty-model 'Empty model' \
  'model must be provider/model' --model anthropic/
_reject shell-metachar 'Shell metachar' \
  'model must be provider/model' --model 'anthropic/claude;rm -rf /'
_reject empty-value 'Empty value' \
  '--model requires provider/model' --model ''

# ── 6. A variant is pinned where the harness supports it ─────────────────────
# opencode has no --variant flag, but it accepts "--agent <name>" at launch and
# its agent definitions carry a first-class variant field, so a pinned variant is
# reachable.  Measured, not assumed: see the launch-side assertions in
# tests/sgt-worker-model-tuple-test.sh.

_dispatch opencode-variant 'Opencode variant' \
  --model anthropic/claude-opus-5:high >/dev/null
state="$(printf '%s\n' "$TEST_ROOT"/fleet/opencode-variant-*/app)"
[[ "$(cat "$state/agent_model")" == "anthropic/claude-opus-5:high" ]] || {
  printf 'FAIL: a pinned variant was not recorded (got %q)\n' \
    "$(cat "$state/agent_model" 2>/dev/null || true)" >&2
  exit 1
}
[[ "$(cat "$state/agent_model_source")" == "flag" ]]

# The harness resolver is authoritative, not the generated definition. A
# mismatch must fail before dispatch creates fleet state or reaches tmux.
before="$(_fleet_task_count)"
set +e
mismatch_output="$(OPENCODE_TEST_RUNTIME_VARIANT=xhigh \
  _dispatch mismatch-variant 'Mismatched variant' \
  --model anthropic/claude-opus-5:medium 2>&1)"
mismatch_status=$?
set -e
[[ "$mismatch_status" -ne 0 ]] || {
  printf 'FAIL: dispatch accepted a runtime variant mismatch\n' >&2
  exit 1
}
[[ "$mismatch_output" == *"resolved variant xhigh, not requested medium"* ]] || {
  printf 'FAIL: mismatch diagnostic was not actionable: %s\n' "$mismatch_output" >&2
  exit 1
}
[[ "$(_fleet_task_count)" == "$before" ]]
[[ ! -e "$TEST_ROOT/mismatch-variant.log" ]]

for failure in unsupported unverifiable; do
  before="$(_fleet_task_count)"
  set +e
  if [[ "$failure" == unsupported ]]; then
    failure_output="$(OPENCODE_TEST_NO_MEDIUM=1 \
      _dispatch "$failure-variant" 'Unsupported variant' \
      --model anthropic/claude-opus-5:medium 2>&1)"
    failure_status=$?
    expected='does not report variant :medium'
  else
    failure_output="$(OPENCODE_TEST_UNVERIFIABLE=1 \
      _dispatch "$failure-variant" 'Unverifiable variant' \
      --model anthropic/claude-opus-5:medium 2>&1)"
    failure_status=$?
    expected='refuses an unverifiable explicit variant'
  fi
  set -e
  [[ "$failure_status" -ne 0 && "$failure_output" == *"$expected"* ]] || {
    printf 'FAIL: %s runtime probe did not fail closed: %s\n' \
      "$failure" "$failure_output" >&2
    exit 1
  }
  [[ "$(_fleet_task_count)" == "$before" ]]
  [[ ! -e "$TEST_ROOT/$failure-variant.log" ]]
done

# ── 7. A variant fails closed only where the transport is genuinely unknown ───
# goose exposes no launch-time variant selector, so the diagnostic must name goose
# and that reason rather than making a blanket claim about all harnesses.

_reject goose-variant 'Goose variant' \
  'goose has no known launch-time variant selector' \
  --agent goose --model openai/gpt-5.2:high
# The model itself is still pinnable on goose, through its environment.
_dispatch goose-model 'Goose model' \
  --agent goose --model openai/gpt-5.2 >/dev/null
state="$(printf '%s\n' "$TEST_ROOT"/fleet/goose-model-*/app)"
[[ "$(cat "$state/agent_model")" == "openai/gpt-5.2" ]]

# An unmeasured harness surface fails closed as UNMEASURED, which is a different
# statement from "this harness cannot do it" and must not be asserted as one.
_reject claude-unmeasured 'Claude unmeasured' \
  'Sergeant has not measured claude launch-time model pinning' \
  --agent claude --model anthropic/claude-opus-5
if [[ "$(_dispatch_output claude-unmeasured-wording 'Claude wording' \
  --agent claude --model anthropic/claude-opus-5)" == *"cannot pin a model variant"* ]]; then
  printf 'FAIL: an unmeasured harness was described as incapable\n' >&2
  exit 1
fi
# An unpinned dispatch on that harness is unaffected.
_dispatch claude-unpinned 'Claude unpinned' --agent claude >/dev/null
state="$(printf '%s\n' "$TEST_ROOT"/fleet/claude-unpinned-*/app)"
[[ "$(cat "$state/agent_model")" == "unpinned" ]]

# The internal unpinned sentinel is not an accepted user value.
_reject sentinel 'Sentinel value' \
  'model must be provider/model' --model unpinned

# ── 8. Recorded tuples never carry a secret ──────────────────────────────────
# The charset that validation enforces is the guarantee, so a credential-shaped
# tuple is rejected rather than sanitized.

_reject secret-shaped 'Secret shaped' \
  'model must be provider/model' --model 'anthropic/claude api_key=sk-live-000'
if grep -qiE 'secret|token|password|api[_-]?key' \
  "$TEST_ROOT"/fleet/*/app/agent_model "$TEST_ROOT"/fleet/*/app/agent_model_source; then
  printf 'FAIL: recorded tuple evidence contains a secret-shaped field\n' >&2
  exit 1
fi

printf 'sgt-dispatch model tuple: ok\n'
