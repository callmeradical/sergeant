#!/usr/bin/env bash
# Regression: sgt-dispatch can bind a coordinator pane without already living
# inside one, while still refusing every forged, stale, or unreachable identity
# and still requiring a persistent interactive worker (GH #172).
#
# Seam under test: the sgt-dispatch CLI, invoked from a shell with no ambient
# TMUX or TMUX_PANE.  Observations are its exit status, its stderr, the tmux
# commands it issued, and the durable fleet files it wrote.
#
# Every rejection asserts that no fleet task directory was created, because
# preflight must still fail before any intent file, td task, worktree, or fleet
# state exists.

set -euo pipefail

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

# Fake tmux.  SERVER_UP controls reachability.  LIVE_PANES lists the pane ids the
# server admits; DEAD_PANES lists ids it reports as dead; FORGED_PANE reports a
# different pane_id than the one asked for.
cat > "$TEST_ROOT/fake-bin/tmux" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "display-message" ]] || printf '%s\n' "$*" >> "$TMUX_LOG"

_requested_target() {
  local prev=""
  for arg in "$@"; do
    [[ "$prev" == "-t" ]] && { printf '%s\n' "$arg"; return 0; }
    prev="$arg"
  done
  return 1
}

if [[ "${SERVER_UP:-1}" != 1 ]]; then
  printf 'no server running on /tmp/tmux-1000/default\n' >&2
  exit 1
fi

case "$1" in
  list-sessions) printf 'sgt: 1 windows\n' ;;
  has-session) exit 0 ;;
  list-panes)
    # The managed coordinator window exists only once it has been created, or
    # when the test pre-seeds a foreign window with that name.
    if [[ "$*" == *"sgt-coordinator"* ]]; then
      if [[ -n "${AMBIGUOUS_MANAGED_PANES:-}" ]]; then
        printf '%s\n' ${AMBIGUOUS_MANAGED_PANES}
      elif [[ -f "$MANAGED_EXISTS_FLAG" ]]; then
        printf '%s\n' "$MANAGED_PANE_ID"
      elif [[ -n "${FOREIGN_MANAGED_PANE:-}" ]]; then
        printf '%s\n' "$FOREIGN_MANAGED_PANE"
      fi
    fi
    ;;
  display-message)
    target="$(_requested_target "$@" || true)"
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
    if [[ "$*" == *'#{session_name}'* ]]; then
      printf 'sgt:3.0\n'
      exit 0
    fi
    for dead in ${DEAD_PANES:-}; do
      [[ "$target" == "$dead" ]] && { printf '1|%s|9999|999999|dead-command\n' "$target"; exit 0; }
    done
    if [[ -n "${FORGED_PANE:-}" && "$target" == "$FORGED_PANE" ]]; then
      printf '0|%%other|9999|999999|forged-command\n'
      exit 0
    fi
    for live in ${LIVE_PANES:-}; do
      if [[ "$target" == "$live" ]]; then
        printf '0|%s|1111|111111|coordinator-command\n' "$target"
        exit 0
      fi
    done
    if [[ -n "${FOREIGN_MANAGED_PANE:-}" && "$target" == "$FOREIGN_MANAGED_PANE" ]]; then
      printf '0|%s|3333|333333|bash\n' "$target"
      exit 0
    fi
    # Ownership marker lookup. Real tmux prints an empty line for a pane that
    # has no such option set.
    if [[ "$*" == *"@sgt_coordinator"* ]]; then
      if [[ -n "${AMBIGUOUS_MANAGED_PANES:-}" ]]; then
        printf '%s\n' "${SGT_MARKER:-sergeant-managed-coordinator}"
      elif [[ "$target" == "$MANAGED_PANE_ID" && -f "$MANAGED_MARKER_LOG" ]]; then
        cat "$MANAGED_MARKER_LOG"
      else
        printf '\n'
      fi
      exit 0
    fi
    for ambiguous in ${AMBIGUOUS_MANAGED_PANES:-}; do
      if [[ "$target" == "$ambiguous" ]]; then
        printf '0|%s|4444|444444|%s\n' "$target" "$ESCAPED_READER_COMMAND"
        exit 0
      fi
    done
    if [[ "$target" == "$MANAGED_PANE_ID" ]]; then
      # Real tmux renders pane_start_command quoted and backslash-escaped, which
      # is exactly why ownership is not inferred from it.
      printf '0|%s|2222|222222|%s\n' "$target" "$ESCAPED_READER_COMMAND"
      exit 0
    fi
    if [[ "$target" == "%42" ]]; then
      printf '0|%%42|4242|123456|fixture-worker-command\n'
      exit 0
    fi
    printf "can't find pane %s\n" "$target" >&2
    exit 1
    ;;
  new-session) exit 0 ;;
  set-option)
    # Only the managed ownership marker is modelled.
    if [[ "$*" == *"@sgt_coordinator"* ]]; then
      printf '%s\n' "${!#}" > "$MANAGED_MARKER_LOG"
    fi
    ;;
  new-window)
    # A managed coordinator window is created with -n sgt-coordinator; every
    # other new-window call is a worker pane.
    if [[ "$*" == *'-n sgt-coordinator'* ]]; then
      printf '%s\n' "${!#}" > "$MANAGED_COMMAND_LOG"
      printf '%s\n' "${!#}" >> "$MANAGED_CREATE_LOG"
      touch "$MANAGED_EXISTS_FLAG"
      printf '%s\n' "$MANAGED_PANE_ID"
    else
      printf '%%42\n'
    fi
    ;;
  send-keys) ;;
  kill-pane) ;;
  kill-window)
    printf '%s\n' "$*" >> "$KILL_WINDOW_LOG"
    rm -f "$MANAGED_EXISTS_FLAG" "$MANAGED_COMMAND_LOG" "$MANAGED_MARKER_LOG"
    ;;
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
printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_ROOT/fake-bin/opencode"
chmod +x "$TEST_ROOT/fake-bin/opencode"

git -C "$TEST_ROOT/repo" init -q
git -C "$TEST_ROOT/repo" config user.name Test
git -C "$TEST_ROOT/repo" config user.email test@example.invalid
touch "$TEST_ROOT/repo/README.md"
git -C "$TEST_ROOT/repo" add README.md
git -C "$TEST_ROOT/repo" commit -qm fixture
git -C "$TEST_ROOT/repo" remote add origin git@github.com:org/test.git

MANAGED_PANE_ID='%77'
MANAGED_COMMAND_LOG="$TEST_ROOT/managed-command"
MANAGED_EXISTS_FLAG="$TEST_ROOT/managed-exists"
MANAGED_CREATE_LOG="$TEST_ROOT/managed-create.log"
MANAGED_MARKER_LOG="$TEST_ROOT/managed-marker"
# pane_start_command as REAL tmux renders it: quoted and backslash-escaped. The
# fixture must not replay the raw command, or a regression to comparing against
# this field would pass here while failing against a live server.
ESCAPED_READER_COMMAND='"while IFS= read -r sgt_line; do printf \"%s\\n\" \"\$sgt_line\"; done; exec sleep 2147483647"'

# The exact reader command Sergeant creates its managed pane with, read from the
# shared library so the fixture cannot drift from the implementation.
MANAGED_READER_COMMAND="$(
  # shellcheck source=bin/_sgt-lib.sh
  source "$ROOT_DIR/bin/_sgt-lib.sh" >/dev/null 2>&1
  printf '%s' "$SGT_MANAGED_COORDINATOR_COMMAND"
)"
[[ -n "$MANAGED_READER_COMMAND" ]] || {
  printf 'FAIL: could not read the managed coordinator reader command\n' >&2
  exit 1
}
KILL_WINDOW_LOG="$TEST_ROOT/kill-window.log"

_fleet_task_count() {
  find "$TEST_ROOT/fleet" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '
}

# _dispatch_no_tmux <log-name> <brief> [args...]
# Runs sgt-dispatch from a shell with no ambient TMUX or TMUX_PANE.
_dispatch_no_tmux() {
  local log_name="$1" brief="$2"
  shift 2
  env -u TMUX -u TMUX_PANE \
    PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/$log_name.log" \
    MANAGED_PANE_ID="$MANAGED_PANE_ID" \
    MANAGED_COMMAND_LOG="$MANAGED_COMMAND_LOG" \
    MANAGED_EXISTS_FLAG="$MANAGED_EXISTS_FLAG" \
    MANAGED_CREATE_LOG="$MANAGED_CREATE_LOG" KILL_WINDOW_LOG="$KILL_WINDOW_LOG" \
    MANAGED_READER_COMMAND="$MANAGED_READER_COMMAND" \
    MANAGED_MARKER_LOG="$MANAGED_MARKER_LOG" \
    ESCAPED_READER_COMMAND="$ESCAPED_READER_COMMAND" \
    ${FOREIGN_MANAGED_PANE:+FOREIGN_MANAGED_PANE="$FOREIGN_MANAGED_PANE"} \
    ${AMBIGUOUS_MANAGED_PANES:+AMBIGUOUS_MANAGED_PANES="$AMBIGUOUS_MANAGED_PANES"} \
    SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
    SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-dispatch" test "$brief" --repos app "$@"
}

# _reject_no_tmux <log-name> <brief> <expected-stderr-substring> [args...]
_reject_no_tmux() {
  local log_name="$1" brief="$2" expected="$3"
  shift 3
  local before after status output
  before="$(_fleet_task_count)"
  set +e
  output="$(_dispatch_no_tmux "$log_name" "$brief" "$@" 2>&1)"
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
}

# ── 1. A non-tmux shell can create a managed coordinator pane ─────────────────

rm -f "$MANAGED_COMMAND_LOG" "$MANAGED_CREATE_LOG"
_dispatch_no_tmux managed 'Managed coordinator' --managed-coordinator-pane >/dev/null
state="$(printf '%s\n' "$TEST_ROOT"/fleet/managed-coordinator-*/app)"
task_dir="$(dirname "$state")"
[[ "$(cat "$task_dir/primary_pane_id")" == "$MANAGED_PANE_ID" ]] || {
  printf 'FAIL: managed coordinator pane id not recorded (got %q)\n' \
    "$(cat "$task_dir/primary_pane_id" 2>/dev/null || true)" >&2
  exit 1
}
[[ -s "$task_dir/primary_pane_identity" ]]
[[ "$(cat "$task_dir/primary_pane")" == "sgt:3.0" ]]
# The worker still launches as a persistent interactive session.
grep -Fq "$ROOT_DIR/bin/sgt-interactive-worker" "$TEST_ROOT/managed.log"
if grep -Fq 'run --auto' "$TEST_ROOT/managed.log" || \
   grep -Fq -- '--prompt' "$TEST_ROOT/managed.log" || \
   grep -Fq 'goose run' "$TEST_ROOT/managed.log"; then
  printf 'FAIL: managed coordinator path reached a non-interactive worker mode\n' >&2
  exit 1
fi

# The managed pane must not run a shell: an injected notification is displayed,
# never executed.
[[ -s "$MANAGED_CREATE_LOG" ]] || {
  printf 'FAIL: no managed coordinator pane command was created\n' >&2
  exit 1
}
managed_command="$(cat "$MANAGED_CREATE_LOG")"
case "$managed_command" in
  *'read'*) ;;
  *)
    printf 'FAIL: managed coordinator pane command is not a non-executing reader: %q\n' \
      "$managed_command" >&2
    exit 1
    ;;
esac
# Ownership is stamped as a pane option, which is what later adoption checks.
[[ "$(cat "$MANAGED_MARKER_LOG" 2>/dev/null || true)" == "sergeant-managed-coordinator" ]] || {
  printf 'FAIL: the managed coordinator pane was not stamped with its ownership marker\n' >&2
  exit 1
}

# ── 2. A managed coordinator pane is reused, not duplicated ──────────────────
# The managed window is selected when it already exists, so repeated dispatches
# from an API coordinator do not accumulate coordinator panes.

rm -f "$MANAGED_CREATE_LOG"
_dispatch_no_tmux managed-reuse 'Managed reuse' \
  --managed-coordinator-pane >/dev/null
state="$(printf '%s\n' "$TEST_ROOT"/fleet/managed-reuse-*/app)"
[[ "$(cat "$(dirname "$state")/primary_pane_id")" == "$MANAGED_PANE_ID" ]]
if grep -Fq -e '-n sgt-coordinator' "$TEST_ROOT/managed-reuse.log"; then
  printf 'FAIL: a second managed coordinator pane was created instead of reused\n' >&2
  exit 1
fi
[[ ! -e "$MANAGED_CREATE_LOG" ]]

# ── 3. An explicitly supplied live pane identity is accepted ─────────────────

LIVE_PANES='%55' _dispatch_no_tmux explicit 'Explicit coordinator' \
  --coordinator-pane '%55' >/dev/null
state="$(printf '%s\n' "$TEST_ROOT"/fleet/explicit-coordinator-*/app)"
[[ "$(cat "$(dirname "$state")/primary_pane_id")" == '%55' ]]
[[ "$(cat "$(dirname "$state")/primary_pane_identity")" == '0|%55|1111|111111|coordinator-command' ]]

# ── 4. A stale, absent, or forged pane identity fails closed ─────────────────

DEAD_PANES='%56' _reject_no_tmux stale 'Stale coordinator' \
  'could not bind exact coordinator pane identity' --coordinator-pane '%56'
_reject_no_tmux absent 'Absent coordinator' \
  'could not bind exact coordinator pane identity' --coordinator-pane '%57'
FORGED_PANE='%58' _reject_no_tmux forged 'Forged coordinator' \
  'could not bind exact coordinator pane identity' --coordinator-pane '%58'
_reject_no_tmux malformed 'Malformed coordinator' \
  '--coordinator-pane requires a tmux pane id' --coordinator-pane 'sgt:1.0'
_reject_no_tmux injection 'Injection coordinator' \
  '--coordinator-pane requires a tmux pane id' --coordinator-pane '%1 kill-server'

# ── 5. Without a coordinator option a non-tmux shell still fails, actionably ──

_reject_no_tmux no-option 'No coordinator option' \
  '--coordinator-pane'

# ── 6. An unreachable tmux server fails with an actionable diagnostic ─────────

SERVER_UP=0 _reject_no_tmux no-server 'No tmux server' \
  'no reachable tmux server' --managed-coordinator-pane

# ── 7. The two coordinator options are mutually exclusive ────────────────────

_reject_no_tmux both-options 'Both coordinator options' \
  'cannot be combined' --managed-coordinator-pane --coordinator-pane '%55'

# ── 8. Existing in-pane dispatch is unchanged ────────────────────────────────
# An ambient coordinator pane still binds itself with no new option.

LIVE_PANES='%11' TMUX=fixture TMUX_PANE='%11' \
  PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/in-pane.log" \
  MANAGED_PANE_ID="$MANAGED_PANE_ID" MANAGED_COMMAND_LOG="$MANAGED_COMMAND_LOG" \
  MANAGED_EXISTS_FLAG="$MANAGED_EXISTS_FLAG" KILL_WINDOW_LOG="$KILL_WINDOW_LOG" \
  MANAGED_CREATE_LOG="$MANAGED_CREATE_LOG" MANAGED_MARKER_LOG="$MANAGED_MARKER_LOG" \
  ESCAPED_READER_COMMAND="$ESCAPED_READER_COMMAND" \
  SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
  SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'In pane coordinator' --repos app >/dev/null
state="$(printf '%s\n' "$TEST_ROOT"/fleet/in-pane-coordinator-*/app)"
[[ "$(cat "$(dirname "$state")/primary_pane_id")" == '%11' ]]
# No managed coordinator window is created when the caller already owns a pane.
if grep -Fq -e '-n sgt-coordinator' "$TEST_ROOT/in-pane.log"; then
  printf 'FAIL: in-pane dispatch created a managed coordinator pane\n' >&2
  exit 1
fi

# ── 9. An ambient pane that no longer verifies still fails closed ────────────

before="$(_fleet_task_count)"
set +e
output="$(DEAD_PANES='%12' TMUX=fixture TMUX_PANE='%12' \
  PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/dead-ambient.log" \
  MANAGED_PANE_ID="$MANAGED_PANE_ID" MANAGED_COMMAND_LOG="$MANAGED_COMMAND_LOG" \
  MANAGED_EXISTS_FLAG="$MANAGED_EXISTS_FLAG" KILL_WINDOW_LOG="$KILL_WINDOW_LOG" \
  MANAGED_CREATE_LOG="$MANAGED_CREATE_LOG" MANAGED_MARKER_LOG="$MANAGED_MARKER_LOG" \
  ESCAPED_READER_COMMAND="$ESCAPED_READER_COMMAND" \
  SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
  SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Dead ambient coordinator' --repos app 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 ]]
[[ "$output" == *'could not bind exact coordinator pane identity'* ]]
[[ "$before" == "$(_fleet_task_count)" ]]

# ── 10. A window Sergeant did not create is never adopted ────────────────────
# Adoption requires the pane's start command to be Sergeant's non-executing
# reader.  Without that check, any window a user happened to name
# "sgt-coordinator" — a shell, an editor — would become the coordinator target
# and an injected notification would execute in it.

rm -f "$MANAGED_EXISTS_FLAG" "$MANAGED_COMMAND_LOG" "$MANAGED_CREATE_LOG" "$MANAGED_MARKER_LOG"
FOREIGN_MANAGED_PANE='%88' _reject_no_tmux foreign-window 'Foreign coordinator window' \
  'could not create or select the managed coordinator pane' --managed-coordinator-pane
[[ ! -e "$MANAGED_CREATE_LOG" ]] || {
  printf 'FAIL: a foreign coordinator window was replaced instead of reported\n' >&2
  exit 1
}
[[ ! -e "$KILL_WINDOW_LOG" ]] || {
  printf 'FAIL: a window Sergeant did not create was killed\n' >&2
  exit 1
}

# ── 11. An ambiguous managed window name is refused, not duplicated ──────────
# Two windows sharing the managed name must not silently become "create a third".

AMBIGUOUS_MANAGED_PANES='%91 %92' _reject_no_tmux ambiguous-window \
  'Ambiguous coordinator window' \
  'could not create or select the managed coordinator pane' --managed-coordinator-pane
[[ ! -e "$MANAGED_CREATE_LOG" ]] || {
  printf 'FAIL: an ambiguous managed window name created another window\n' >&2
  exit 1
}

# ── 12. A later preflight failure rolls back the window this run created ─────
# Repo validation runs after the pane is bound, so this exercises the rollback
# path GH #172 requires: exactly the window this invocation created is removed,
# and no fleet state survives.

rm -f "$MANAGED_EXISTS_FLAG" "$MANAGED_COMMAND_LOG" "$MANAGED_CREATE_LOG" "$KILL_WINDOW_LOG" "$MANAGED_MARKER_LOG"
before="$(_fleet_task_count)"
set +e
output="$(_dispatch_no_tmux rollback 'Rollback coordinator' \
  --managed-coordinator-pane --repos no-such-repo 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 ]] || {
  printf 'FAIL: dispatch accepted an unknown repo\n' >&2
  exit 1
}
[[ "$output" == *"not found in project"* ]] || {
  printf 'FAIL: rollback case failed for the wrong reason: %s\n' "$output" >&2
  exit 1
}
[[ "$before" == "$(_fleet_task_count)" ]] || {
  printf 'FAIL: rollback case left fleet state behind\n' >&2
  exit 1
}
[[ -s "$MANAGED_CREATE_LOG" ]] || {
  printf 'FAIL: rollback case never created a managed pane to roll back\n' >&2
  exit 1
}
grep -Fq 'sgt-coordinator' "$KILL_WINDOW_LOG" 2>/dev/null || {
  printf 'FAIL: the managed coordinator window this run created was not rolled back\n' >&2
  exit 1
}

# A window Sergeant only selected is never rolled back by a later failure.
rm -f "$KILL_WINDOW_LOG" "$MANAGED_CREATE_LOG"
_dispatch_no_tmux rollback-seed 'Rollback seed' --managed-coordinator-pane >/dev/null
rm -f "$KILL_WINDOW_LOG" "$MANAGED_CREATE_LOG"
set +e
_dispatch_no_tmux rollback-selected 'Rollback selected' \
  --managed-coordinator-pane --repos no-such-repo >/dev/null 2>&1
set -e
[[ ! -e "$MANAGED_CREATE_LOG" ]]
[[ ! -e "$KILL_WINDOW_LOG" ]] || {
  printf 'FAIL: a merely selected managed coordinator window was killed on failure\n' >&2
  exit 1
}

# ── 13. --dry-run creates no tmux state ──────────────────────────────────────

rm -f "$MANAGED_EXISTS_FLAG" "$MANAGED_COMMAND_LOG" "$MANAGED_CREATE_LOG" \
  "$KILL_WINDOW_LOG" "$MANAGED_MARKER_LOG" "$TEST_ROOT/dry-run.log"
before="$(_fleet_task_count)"
if ! _dispatch_no_tmux dry-run 'Dry run coordinator' \
  --managed-coordinator-pane --dry-run >/dev/null 2>&1; then
  printf 'FAIL: --dry-run with a managed coordinator pane did not succeed\n' >&2
  exit 1
fi
[[ "$before" == "$(_fleet_task_count)" ]] || {
  printf 'FAIL: --dry-run created fleet state\n' >&2
  exit 1
}
[[ ! -e "$MANAGED_CREATE_LOG" ]] || {
  printf 'FAIL: --dry-run created a managed coordinator pane\n' >&2
  exit 1
}
if grep -Fq -e '-n sgt-coordinator' "$TEST_ROOT/dry-run.log" 2>/dev/null || \
   grep -Fq 'new-session' "$TEST_ROOT/dry-run.log" 2>/dev/null; then
  printf 'FAIL: --dry-run mutated tmux\n' >&2
  exit 1
fi

printf 'sgt-dispatch coordinator pane: ok\n'
