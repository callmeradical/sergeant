#!/usr/bin/env bash
# Regression: sgt-interactive-worker passes the pinned provider/model tuple to
# the persistent interactive harness and records launch evidence that matches
# what the harness process actually received (GH #177).
#
# Seam under test: the sgt-interactive-worker CLI.  The harness is a fake binary
# that reports its own argv and its own tuple-relevant environment into a file,
# so "what actually ran" is observed from the harness side, never from the
# worker's internals.  Every assertion compares that independent observation
# against the durable launch_record.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v tmux >/dev/null 2>&1 || {
  printf 'sgt-interactive-worker model tuple: skipped (tmux unavailable)\n'
  exit 0
}
TEST_ROOT="$(mktemp -d)"
TMUX_SESSION="sgt-worker-model-tuple-test-$$"
trap 'tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true; rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/fake-bin"

# Fake harness: records the argv it was given and the tuple-relevant
# environment it inherited, then applies its ambient default only when the
# launcher pinned nothing.  OBSERVED_MODEL is what the harness would really run.
cat > "$TEST_ROOT/fake-bin/opencode" <<'EOF'
#!/usr/bin/env bash
observed=""
prev=""
for arg in "$@"; do
  [[ "$prev" == "--model" ]] && observed="$arg"
  prev="$arg"
done
if [[ -z "$observed" && -n "${GOOSE_MODEL:-}" ]]; then
  observed="${GOOSE_PROVIDER:-}/${GOOSE_MODEL}"
fi
[[ -n "$observed" ]] || observed="${AMBIENT_DEFAULT_MODEL:-ambient-default}"
{
  printf 'argc=%s\n' "$#"
  printf 'argv=%s\n' "$*"
  printf 'goose_provider=%s\n' "${GOOSE_PROVIDER:-}"
  printf 'goose_model=%s\n' "${GOOSE_MODEL:-}"
  printf 'observed_model=%s\n' "$observed"
} > "$OBSERVED_LOG"
printf 'done\n' > .sergeant-status
printf 'https://example.invalid/pr/1\n' > .sergeant-result
EOF
chmod +x "$TEST_ROOT/fake-bin/opencode"
ln -s opencode "$TEST_ROOT/fake-bin/goose"
ln -s opencode "$TEST_ROOT/fake-bin/claude"

tmux new-session -d -s "$TMUX_SESSION" -n keepalive "while :; do sleep 1; done"

# _launch <case> <harness> <pinned-tuple-or-empty> <source>
# Prepares fleet state for one worker, runs it to completion in its own tmux
# window, and leaves $TEST_ROOT/<case>/observed plus the fleet launch_record
# for the caller to compare.
_launch() {
  local name="$1" harness="$2" tuple="$3" source="$4"
  local state="$TEST_ROOT/$name/state" worktree="$TEST_ROOT/$name/worktree"
  mkdir -p "$state" "$worktree"
  if [[ -n "$tuple" ]]; then
    printf '%s\n' "$tuple" > "$state/agent_model"
    printf '%s\n' "$source" > "$state/agent_model_source"
  fi
  tmux new-window -d -t "$TMUX_SESSION:" -n "$name" \
    "env OBSERVED_LOG='$TEST_ROOT/$name/observed' \
    AMBIENT_DEFAULT_MODEL=anthropic/claude-haiku-4-5 \
    '$ROOT_DIR/bin/sgt-interactive-worker' '$state' '$worktree' \
    '$TEST_ROOT/fake-bin/$harness'"
  local _
  for _ in $(seq 1 300); do
    [[ -f "$state/result" ]] && return 0
    sleep 0.02
  done
  printf 'FAIL: %s worker never reached terminal completion\n' "$name" >&2
  [[ ! -f "$state/diagnostic" ]] || cat "$state/diagnostic" >&2
  exit 1
}

_field() { sed -n "s/^$2=//p" "$1"; }

# _assert_evidence_matches <case>
# The single invariant this file exists for: the model the harness actually ran
# equals the model recorded in durable launch evidence.
_assert_evidence_matches() {
  local name="$1"
  local observed recorded
  observed="$(_field "$TEST_ROOT/$name/observed" observed_model)"
  recorded="$(_field "$TEST_ROOT/$name/state/launch_record" model)"
  if [[ "$observed" != "$recorded" ]]; then
    printf 'FAIL: %s launch evidence %q does not match the model the harness ran %q\n' \
      "$name" "$recorded" "$observed" >&2
    exit 1
  fi
}

# ── 1. opencode receives the pinned tuple as a qualified --model argument ─────

_launch pinned-opencode opencode anthropic/claude-opus-5 flag
observed="$TEST_ROOT/pinned-opencode/observed"
record="$TEST_ROOT/pinned-opencode/state/launch_record"
[[ "$(_field "$observed" argv)" == "--dangerously-skip-permissions --model anthropic/claude-opus-5" ]] || {
  printf 'FAIL: opencode argv was %q\n' "$(_field "$observed" argv)" >&2
  exit 1
}
_assert_evidence_matches pinned-opencode
[[ "$(_field "$record" harness)" == "opencode" ]]
[[ "$(_field "$record" provider)" == "anthropic" ]]
[[ "$(_field "$record" model_id)" == "claude-opus-5" ]]
[[ "$(_field "$record" variant)" == "" ]]
[[ "$(_field "$record" model_source)" == "flag" ]]
[[ "$(_field "$record" model_transport)" == "argv-qualified" ]]

# The pinned model, not the harness's ambient default, is what ran.
[[ "$(_field "$observed" observed_model)" != "anthropic/claude-haiku-4-5" ]] || {
  printf 'FAIL: opencode inherited its ambient default despite an explicit pin\n' >&2
  exit 1
}

# ── 2. goose receives the tuple through its environment ──────────────────────
# "goose session" has no model or provider flag, so the environment is the only
# launch-time selector; argv must stay exactly the session invocation.

_launch pinned-goose goose openai/gpt-5.2 env
observed="$TEST_ROOT/pinned-goose/observed"
record="$TEST_ROOT/pinned-goose/state/launch_record"
[[ "$(_field "$observed" argv)" == "session" ]] || {
  printf 'FAIL: goose argv was %q\n' "$(_field "$observed" argv)" >&2
  exit 1
}
[[ "$(_field "$observed" goose_provider)" == "openai" ]]
[[ "$(_field "$observed" goose_model)" == "gpt-5.2" ]]
_assert_evidence_matches pinned-goose
[[ "$(_field "$record" model_transport)" == "env-goose" ]]
[[ "$(_field "$record" model_source)" == "env" ]]

# ── 3. claude receives a bare model name within its only provider scope ───────
# Claude Code never receives a provider on the command line, so the recorded
# provider is only truthful because the contract restricts the pin to the one
# provider its bare model namespace addresses.

_launch pinned-claude claude anthropic/claude-opus-5 flag
observed="$TEST_ROOT/pinned-claude/observed"
record="$TEST_ROOT/pinned-claude/state/launch_record"
[[ "$(_field "$observed" argv)" == "--model claude-opus-5" ]] || {
  printf 'FAIL: claude argv was %q\n' "$(_field "$observed" argv)" >&2
  exit 1
}
[[ "$(_field "$record" model_transport)" == "argv-bare" ]]
# The model the harness ran is the recorded model_id, and the recorded provider
# is the only one this transport can address.
[[ "$(_field "$observed" observed_model)" == "$(_field "$record" model_id)" ]]
[[ "$(_field "$record" provider)" == "anthropic" ]]

# ── 4. An unpinned worker inherits the ambient default and records that ───────

_launch unpinned opencode unpinned unpinned
observed="$TEST_ROOT/unpinned/observed"
record="$TEST_ROOT/unpinned/state/launch_record"
[[ "$(_field "$observed" argv)" == "--dangerously-skip-permissions" ]] || {
  printf 'FAIL: unpinned opencode argv was %q\n' "$(_field "$observed" argv)" >&2
  exit 1
}
[[ "$(_field "$observed" observed_model)" == "anthropic/claude-haiku-4-5" ]]
[[ "$(_field "$record" model)" == "unpinned" ]]
[[ "$(_field "$record" model_source)" == "unpinned" ]]
[[ "$(_field "$record" provider)" == "" ]]

# ── 5. Fleet state with no tuple at all is treated as unpinned ───────────────
# Fleet directories created before this contract existed must keep launching.

_launch legacy opencode '' ''
[[ "$(_field "$TEST_ROOT/legacy/observed" argv)" == "--dangerously-skip-permissions" ]]
[[ "$(_field "$TEST_ROOT/legacy/state/launch_record" model)" == "unpinned" ]]

# ── 6. The launch record carries no ambient environment ──────────────────────
# Evidence is built only from the validated tuple, so a credential in the
# launcher's environment can never reach it.

if grep -qiE 'secret|token|password|api[_-]?key' \
  "$TEST_ROOT"/*/state/launch_record; then
  printf 'FAIL: launch evidence contains a secret-shaped field\n' >&2
  exit 1
fi

# ── 7. A tuple the harness cannot honor fails closed before the harness runs ──
# The coordinator validates at dispatch time, but a hand-edited or replayed
# fleet record must not silently drop the pin and inherit the ambient default.

# _reject_launch <case> <harness> <tuple> <expected-diagnostic-substring>
_reject_launch() {
  local name="$1" harness="$2" tuple="$3" expected="$4"
  local state="$TEST_ROOT/$name/state" worktree="$TEST_ROOT/$name/worktree"
  mkdir -p "$state" "$worktree"
  printf '%s\n' "$tuple" > "$state/agent_model"
  printf 'flag\n' > "$state/agent_model_source"
  tmux new-window -d -t "$TMUX_SESSION:" -n "$name" \
    "env OBSERVED_LOG='$TEST_ROOT/$name/observed' \
    '$ROOT_DIR/bin/sgt-interactive-worker' '$state' '$worktree' \
    '$TEST_ROOT/fake-bin/$harness'"
  local _
  for _ in $(seq 1 300); do
    [[ -f "$state/diagnostic" ]] && break
    sleep 0.02
  done
  [[ -f "$state/diagnostic" ]] || {
    printf 'FAIL: %s recorded no diagnostic for an unhonorable tuple\n' "$name" >&2
    exit 1
  }
  [[ ! -e "$TEST_ROOT/$name/observed" ]] || {
    printf 'FAIL: %s launched the harness despite an unhonorable pinned tuple\n' "$name" >&2
    exit 1
  }
  grep -Fq "$expected" "$state/diagnostic" || {
    printf 'FAIL: %s diagnostic missing %q; got:\n%s\n' "$name" "$expected" \
      "$(cat "$state/diagnostic")" >&2
    exit 1
  }
  [[ ! -e "$state/launch_record" ]] || {
    printf 'FAIL: %s recorded launch evidence for a harness it never launched\n' "$name" >&2
    exit 1
  }
  # A worker that cannot honor its pin is terminally failed, not orphaned, so
  # the coordinator re-dispatches instead of resuming the same broken pin.
  [[ "$(cat "$state/status")" == "failed: cannot honor pinned model tuple $tuple" ]] || {
    printf 'FAIL: %s status was %q\n' "$name" "$(cat "$state/status")" >&2
    exit 1
  }
  [[ "$(cat "$worktree/.sergeant-status")" == "$(cat "$state/status")" ]]
}

_reject_launch reject-variant opencode anthropic/claude-opus-5:high \
  'cannot pin a model variant at launch'
_reject_launch reject-provider claude openai/gpt-5.2 \
  'can only be pinned to provider anthropic, not openai'
_reject_launch reject-malformed opencode 'claude-opus-5' \
  'model must be provider/model'

printf 'sgt-interactive-worker model tuple: ok\n'
