#!/usr/bin/env bash
# Regression for the shared harness contract (td-ed15d5 / GH #175).
#
# One registry in bin/_sgt-harness.sh must drive all three things that used to
# diverge inside bin/sgt-interactive-worker: the accepted-harness capability
# gate (was L32-38), the readiness probe (was L148-164), and the launch
# invocation (was L405-409).
#
# The probe must not depend on any single UI presentation string and must work
# for an interpreted harness whose #{pane_current_command} is the interpreter
# rather than the harness name.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS_LIB="$ROOT_DIR/bin/_sgt-harness.sh"
TEST_ROOT="$(mktemp -d)"
TMUX_SESSION="sgt-harness-test-$$"
# Run against a private tmux server.  Sharing the developer's server makes these
# tests contend with every other pane on it — including ones leaked by other
# suites — which turns pane operations slow enough to blow the per-test budget,
# and it leaks panes back the other way.  Child `tmux` calls inside the worker
# follow $TMUX, so they reach this same private server.
export TMUX_TMPDIR="$TEST_ROOT/tmux"
mkdir -p "$TMUX_TMPDIR"

trap 'tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true; rm -rf "$TEST_ROOT"' EXIT

[[ -f "$HARNESS_LIB" ]] || {
  printf 'missing shared harness definition: %s\n' "$HARNESS_LIB" >&2
  exit 1
}

# shellcheck source=bin/_sgt-harness.sh
source "$HARNESS_LIB"

# ── 1. One registry lists every accepted harness ──────────────────────────────

names="$(_sgt_harness_names)"
for expected in opencode oc goose claude; do
  printf '%s\n' "$names" | grep -Fxq "$expected" || {
    printf 'accepted harness missing from the shared registry: %s\n' "$expected" >&2
    exit 1
  }
done

_sgt_harness_is_accepted opencode
_sgt_harness_is_accepted claude
if _sgt_harness_is_accepted definitely-not-a-harness; then
  printf 'registry accepted an unknown harness\n' >&2
  exit 1
fi

# ── 2. The same registry supplies the launch invocation ───────────────────────
# These are the exact argument vectors bin/sgt-interactive-worker used to hard
# code in its own case statement.

launch_args_of() {
  local harness="$1" args
  args="$(_sgt_harness_launch_args "$harness")"
  printf '%s' "$args" | tr '\n' ' ' | sed 's/ *$//'
}

[[ "$(launch_args_of goose)" == "session" ]] || {
  printf 'goose launch args regressed: %s\n' "$(launch_args_of goose)" >&2
  exit 1
}
[[ "$(launch_args_of opencode)" == "--dangerously-skip-permissions" ]] || {
  printf 'opencode launch args regressed: %s\n' "$(launch_args_of opencode)" >&2
  exit 1
}
[[ "$(launch_args_of oc)" == "--dangerously-skip-permissions" ]] || {
  printf 'oc launch args regressed: %s\n' "$(launch_args_of oc)" >&2
  exit 1
}
[[ -z "$(launch_args_of claude)" ]] || {
  printf 'claude must launch with no extra arguments, got: %s\n' "$(launch_args_of claude)" >&2
  exit 1
}
if _sgt_harness_launch_args definitely-not-a-harness >/dev/null 2>&1; then
  printf 'launch args resolved for an unknown harness\n' >&2
  exit 1
fi

# ── 3. Every accepted harness declares a probe; a missing probe fails loudly ──

while IFS= read -r harness; do
  [[ -n "$harness" ]] || continue
  probe="$(_sgt_harness_probe "$harness")"
  [[ -n "$probe" ]] || {
    printf 'accepted harness has no readiness probe: %s\n' "$harness" >&2
    exit 1
  }
done <<EOF
$names
EOF

_sgt_harness_registry_validate

set +e
missing_probe_output="$(SGT_TEST_HOOKS=1 \
  _SGT_HARNESS_REGISTRY_OVERRIDE='opencode:tui:--dangerously-skip-permissions
newharness::' \
  bash -c 'source "$1"; _sgt_harness_registry_validate' _ "$HARNESS_LIB" 2>&1)"
missing_probe_status=$?
set -e
if [[ "$missing_probe_status" -eq 0 ]]; then
  printf 'a harness with no readiness probe was silently accepted\n' >&2
  exit 1
fi
[[ "$missing_probe_output" == *"newharness"* ]] || {
  printf 'registry validation did not name the offending harness:\n%s\n' \
    "$missing_probe_output" >&2
  exit 1
}

set +e
unknown_probe_output="$(SGT_TEST_HOOKS=1 \
  _SGT_HARNESS_REGISTRY_OVERRIDE='newharness:telepathy:' \
  bash -c 'source "$1"; _sgt_harness_registry_validate' _ "$HARNESS_LIB" 2>&1)"
unknown_probe_status=$?
set -e
if [[ "$unknown_probe_status" -eq 0 ]]; then
  printf 'a harness declaring an unimplemented probe was accepted\n' >&2
  exit 1
fi
[[ "$unknown_probe_output" == *"telepathy"* ]] || {
  printf 'registry validation did not name the unknown probe:\n%s\n' \
    "$unknown_probe_output" >&2
  exit 1
}

# ── 4. Readiness of a real pane, with no presentation string at all ───────────
# The pane below never prints "Ask anything..." and its #{pane_current_command}
# is the interpreter (bash), not the harness name — exactly the two conditions
# that made the old probe unable to ever become ready for claude.

command -v tmux >/dev/null 2>&1 || {
  printf 'tmux is required for the harness readiness regression\n' >&2
  exit 1
}

tmux new-session -d -s "$TMUX_SESSION" -n keepalive "while :; do sleep 1; done"

cat > "$TEST_ROOT/interpreted-harness" <<'EOF'
#!/usr/bin/env bash
# Stands in for `claude`, which runs under node: nothing here is named after the
# harness once it is executing, and it prints no recognisable prompt banner.
printf 'ready-without-any-known-banner\n'
while :; do sleep 1; done
EOF
chmod +x "$TEST_ROOT/interpreted-harness"

tmux new-window -d -t "$TMUX_SESSION:" -n interpreted \
  "'$TEST_ROOT/interpreted-harness'"
interpreted_pane="$(tmux display-message -p -t "$TMUX_SESSION:interpreted" '#{pane_id}')"

# Guard the premise: the pane command really is the interpreter, so the old
# `[[ "$pane_command" == "$harness" ]]` fallback could never have matched.
pane_command="$(tmux display-message -p -t "$interpreted_pane" '#{pane_current_command}')"
[[ "$pane_command" != "claude" ]] || {
  printf 'test premise broken: pane command is literally the harness name\n' >&2
  exit 1
}

SGT_HARNESS_SETTLE_SECONDS=0
export SGT_HARNESS_SETTLE_SECONDS
ready=false
for _ in $(seq 1 300); do
  if _sgt_harness_ready claude "$interpreted_pane"; then
    ready=true
    break
  fi
  sleep 0.05
done
$ready || {
  printf 'interpreted harness never became ready:\n%s\n' \
    "$(tmux capture-pane -p -t "$interpreted_pane" 2>&1 || true)" >&2
  exit 1
}

# The probe must not have consulted any presentation string: prove readiness is
# still reported when the legacy OpenCode banner is explicitly set to text the
# pane does not contain.
SGT_OPENCODE_READY_TEXT='this text is nowhere on the pane' \
  _sgt_harness_ready opencode "$interpreted_pane" || {
  printf 'readiness still depends on a UI presentation string\n' >&2
  exit 1
}

# ── 5. A pane that has rendered nothing is not ready ──────────────────────────

tmux new-window -d -t "$TMUX_SESSION:" -n silent \
  "exec sh -c 'while :; do sleep 1; done'"
silent_pane="$(tmux display-message -p -t "$TMUX_SESSION:silent" '#{pane_id}')"
if _sgt_harness_ready claude "$silent_pane"; then
  printf 'a pane that rendered nothing was reported ready\n' >&2
  exit 1
fi

# ── 6. A dead pane is never ready ─────────────────────────────────────────────

tmux new-window -d -t "$TMUX_SESSION:" -n dying "printf 'drawn\n'"
dying_pane="$(tmux display-message -p -t "$TMUX_SESSION:dying" '#{pane_id}')"
for _ in $(seq 1 300); do
  [[ "$(tmux display-message -p -t "$dying_pane" '#{pane_dead}' 2>/dev/null || echo 1)" == "1" ]] && break
  sleep 0.05
done
if _sgt_harness_ready claude "$dying_pane" 2>/dev/null; then
  printf 'a dead pane was reported ready\n' >&2
  exit 1
fi

# ── 7. An unknown harness is never ready ──────────────────────────────────────

if _sgt_harness_ready definitely-not-a-harness "$interpreted_pane" 2>/dev/null; then
  printf 'an unregistered harness was reported ready\n' >&2
  exit 1
fi

# ── 8. A drawn pane is never ready on its first sighting ──────────────────────
# A TUI that has only just painted its first frame may not have installed its
# input handlers, so keystrokes could be dropped.

tmux new-window -d -t "$TMUX_SESSION:" -n firstsight \
  "'$TEST_ROOT/interpreted-harness'"
firstsight_pane="$(tmux display-message -p -t "$TMUX_SESSION:firstsight" '#{pane_id}')"
for _ in $(seq 1 300); do
  [[ -n "$(tmux capture-pane -p -t "$firstsight_pane" 2>/dev/null | tr -d ' \n')" ]] && break
  sleep 0.05
done
_SGT_HARNESS_READY_PANE=""
_SGT_HARNESS_READY_SINCE=""
if _sgt_harness_ready claude "$firstsight_pane"; then
  printf 'a pane was reported ready on its first drawn sighting\n' >&2
  exit 1
fi
_sgt_harness_ready claude "$firstsight_pane" || {
  printf 'a pane drawn on two consecutive probes was still not ready\n' >&2
  exit 1
}

# ── 9. The optional wall-clock settle minimum is honoured on top ──────────────

tmux new-window -d -t "$TMUX_SESSION:" -n settle \
  "'$TEST_ROOT/interpreted-harness'"
settle_pane="$(tmux display-message -p -t "$TMUX_SESSION:settle" '#{pane_id}')"
for _ in $(seq 1 300); do
  [[ -n "$(tmux capture-pane -p -t "$settle_pane" 2>/dev/null | tr -d ' \n')" ]] && break
  sleep 0.05
done
_SGT_HARNESS_READY_PANE=""
_SGT_HARNESS_READY_SINCE=""
# First sighting registers the pane; the second would be ready but for the
# wall-clock minimum.
SGT_HARNESS_SETTLE_SECONDS=600 _sgt_harness_ready claude "$settle_pane" || true
if SGT_HARNESS_SETTLE_SECONDS=600 _sgt_harness_ready claude "$settle_pane"; then
  printf 'the readiness settle window was ignored\n' >&2
  exit 1
fi

printf 'shared harness contract: ok\n'
