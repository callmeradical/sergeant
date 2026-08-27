#!/usr/bin/env bash
# Regression for the shared-mcp-server change: sgt-dispatch had no flag for
# tmux session name (SERGEANT_TMUX_SESSION env-only), so an MCP caller behind
# a shared sergeant-mcp server process had no way to pass a per-invocation
# session name -- the shared process's own inherited environment silently won
# for every connected instance. This adds --tmux-session at
# flag > env > "sgt" default, mirroring --model's existing precedence shape.
#
# Seam under test: the sgt-dispatch CLI. Observations are the durable
# tmux_session fleet record and the tmux commands actually issued.

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
_sgt_coord_pane="${SGT_COORD_PANE:-%79}"
_sgt_coord_flag="${TMUX_LOG:-/tmp/sgt-coord}.coordinator-created"
case "${1:-}" in
  list-sessions) exit 0 ;;
  list-panes)
    if [[ "$*" == *sgt-coordinator* ]]; then
      [[ -f "$_sgt_coord_flag" ]] && printf '%s\n' "$_sgt_coord_pane"
      exit 0
    fi
    ;;
  new-window)
    if [[ "$*" == *sgt-coordinator* ]]; then
      : > "$_sgt_coord_flag"
      printf '%s\n' "$_sgt_coord_pane"
      exit 0
    fi
    ;;
  set-option)
    [[ "$*" == *@sgt_coordinator* ]] && exit 0
    ;;
  display-message)
    if [[ "$*" == *@sgt_coordinator* ]]; then
      printf 'sergeant-managed-coordinator\n'
      exit 0
    fi
    if [[ "$*" == *"-t $_sgt_coord_pane"* ]]; then
      printf '0|%s|7979|797979|sgt-coordinator-reader\n' "$_sgt_coord_pane"
      exit 0
    fi
    ;;
esac
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

ln -s "$ROOT_DIR/bin/sgt-review-findings" "$TEST_ROOT/fake-bin/sgt-review-findings"

cat > "$TEST_ROOT/fake-bin/opencode" <<'EOF'
#!/usr/bin/env bash
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

# _dispatch <log-name> <brief> [env-assignments...] -- [extra sgt-dispatch args...]
# Simpler direct runner: callers prefix env vars via `env`, exactly like the
# --model precedent test does.
_dispatch() {
  local log_name="$1" brief="$2"
  shift 2
  PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/$log_name.log" \
  SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
  SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-dispatch" test "$brief" --repos app "$@"
}

# ── 1. --tmux-session is recorded and used for session/window creation ───────

_dispatch explicit 'Explicit session' --tmux-session custom-session >/dev/null
state="$(printf '%s\n' "$TEST_ROOT"/fleet/explicit-session-*/app)"
[[ "$(cat "$state/tmux_session")" == "custom-session" ]] || {
  printf 'FAIL: tmux_session not recorded (got %q)\n' \
    "$(cat "$state/tmux_session" 2>/dev/null || true)" >&2
  exit 1
}
grep -q -- '-t custom-session:' "$TEST_ROOT/explicit.log" || {
  printf 'FAIL: tmux new-window was not targeted at custom-session\n' >&2
  exit 1
}
grep -q -- '-s custom-session' "$TEST_ROOT/explicit.log" || {
  printf 'FAIL: tmux new-session was not created for custom-session\n' >&2
  exit 1
}

# ── 2. SERGEANT_TMUX_SESSION supplies the name when no flag is given ─────────

env SERGEANT_TMUX_SESSION=env-session \
  PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/env.log" \
  SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
  SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Env session' --repos app >/dev/null
state="$(printf '%s\n' "$TEST_ROOT"/fleet/env-session-*/app)"
[[ "$(cat "$state/tmux_session")" == "env-session" ]] || {
  printf 'FAIL: SERGEANT_TMUX_SESSION was not honored (got %q)\n' \
    "$(cat "$state/tmux_session" 2>/dev/null || true)" >&2
  exit 1
}

# ── 3. --tmux-session overrides SERGEANT_TMUX_SESSION ────────────────────────

env SERGEANT_TMUX_SESSION=env-session \
  PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/precedence.log" \
  SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
  SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Precedence session' --repos app \
  --tmux-session flag-session >/dev/null
state="$(printf '%s\n' "$TEST_ROOT"/fleet/precedence-session-*/app)"
[[ "$(cat "$state/tmux_session")" == "flag-session" ]] || {
  printf 'FAIL: --tmux-session did not override SERGEANT_TMUX_SESSION (got %q)\n' \
    "$(cat "$state/tmux_session" 2>/dev/null || true)" >&2
  exit 1
}

# ── 4. Omitting both preserves today's "sgt" default (regression) ────────────

_dispatch default-session 'Default session' >/dev/null
state="$(printf '%s\n' "$TEST_ROOT"/fleet/default-session-*/app)"
[[ "$(cat "$state/tmux_session")" == "sgt" ]] || {
  printf 'FAIL: default tmux session regressed (got %q)\n' \
    "$(cat "$state/tmux_session" 2>/dev/null || true)" >&2
  exit 1
}

# ── 5. An empty --tmux-session value is rejected before any mutation ─────────

before="$(find "$TEST_ROOT/fleet" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
set +e
empty_output="$(_dispatch empty-session 'Empty session' --tmux-session '' 2>&1)"
empty_status=$?
set -e
after="$(find "$TEST_ROOT/fleet" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
[[ "$empty_status" -ne 0 ]] || {
  printf 'FAIL: an empty --tmux-session value should be rejected\n' >&2
  exit 1
}
[[ "$empty_output" == *'--tmux-session requires a name'* ]] || {
  printf 'FAIL: rejection diagnostic missing expected text, got: %s\n' "$empty_output" >&2
  exit 1
}
[[ "$before" == "$after" ]] || {
  printf 'FAIL: rejected --tmux-session created fleet state before validation\n' >&2
  exit 1
}

printf 'sgt-dispatch tmux session: ok\n'
