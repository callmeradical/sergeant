#!/usr/bin/env bash
# Public-CLI regression for task-scoped managed coordinator retirement.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"

cleanup_fixture() {
  rm -rf "$TEST_ROOT"
}
trap cleanup_fixture EXIT

mkdir -p "$TEST_ROOT/fake-bin" "$TEST_ROOT/fleet/task-a" \
  "$TEST_ROOT/fleet/task-b" "$TEST_ROOT/fleet/task-user"
printf '%%71\n' > "$TEST_ROOT/fleet/task-a/primary_pane_id"
printf '%%71\n' > "$TEST_ROOT/fleet/task-b/primary_pane_id"
printf '0|%%71|7171|171717|managed-reader\n' \
  > "$TEST_ROOT/fleet/task-a/primary_pane_identity"
printf '0|%%71|7171|171717|managed-reader\n' \
  > "$TEST_ROOT/fleet/task-b/primary_pane_identity"
chmod 600 "$TEST_ROOT/fleet/task-a/primary_pane_identity" \
  "$TEST_ROOT/fleet/task-b/primary_pane_identity"
printf '%%72\n' > "$TEST_ROOT/fleet/task-user/primary_pane_id"
printf '0|%%72|7272|272727|user-shell\n' \
  > "$TEST_ROOT/fleet/task-user/primary_pane_identity"
chmod 600 "$TEST_ROOT/fleet/task-user/primary_pane_identity"
touch "$TEST_ROOT/managed-live" "$TEST_ROOT/user-live"

cat > "$TEST_ROOT/fake-bin/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
command="${1:-}"
shift || true
case "$command" in
  display-message)
    target=""
    format="${!#}"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -t) target="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    if [[ "$target" == '%72' && -f "$USER_LIVE" ]]; then
      if [[ "$format" == '#{@sgt_coordinator}' ]]; then
        exit 0
      elif [[ "$format" == '#{pane_id}' ]]; then
        printf '%%72\n'
      else
        printf '0|%%72|7272|272727|user-shell\n'
      fi
      exit 0
    fi
    [[ "$target" == '%71' && -f "$MANAGED_LIVE" ]] || exit 1
    if [[ "$format" == '#{@sgt_coordinator}' ]]; then
      printf 'sergeant-managed-coordinator\n'
    elif [[ "$format" == '#{pane_id}' ]]; then
      printf '%%71\n'
    else
      printf '0|%%71|7171|171717|managed-reader\n'
    fi
    ;;
  kill-pane)
    [[ "${2:-}" == '%71' ]]
    printf '%s\n' "$*" >> "$KILL_LOG"
    rm -f "$MANAGED_LIVE"
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/tmux"

run_cleanup() {
  PATH="$TEST_ROOT/fake-bin:$PATH" \
    MANAGED_LIVE="$TEST_ROOT/managed-live" KILL_LOG="$TEST_ROOT/kills" \
    USER_LIVE="$TEST_ROOT/user-live" \
    SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-cleanup" "$1" >/dev/null
}

# An explicitly bound user pane has no Sergeant marker and is never retired.
run_cleanup task-user
[[ -f "$TEST_ROOT/user-live" ]]
[[ ! -e "$TEST_ROOT/kills" ]]

# A shared managed pane remains while another fleet task owns the exact identity.
run_cleanup task-a
[[ -f "$TEST_ROOT/managed-live" ]]
[[ ! -e "$TEST_ROOT/kills" ]]

# Cleanup cannot scan past an in-flight owner publication. The publisher holds
# the fleet transaction from managed-pane selection through exact identity.
mkdir -p "$TEST_ROOT/fleet/task-inflight" \
  "$TEST_ROOT/fleet/.coordinator-pane.lock"
printf 'fixture-publisher\n' > "$TEST_ROOT/fleet/.coordinator-pane.lock/owner"
printf '%%71\n' > "$TEST_ROOT/fleet/task-inflight/primary_pane_id"
run_cleanup task-b &
cleanup_pid=$!
sleep 0.1
[[ -f "$TEST_ROOT/managed-live" ]]
printf '0|%%71|7171|171717|managed-reader\n' \
  > "$TEST_ROOT/fleet/task-inflight/primary_pane_identity"
chmod 600 "$TEST_ROOT/fleet/task-inflight/primary_pane_identity"
rm -f "$TEST_ROOT/fleet/.coordinator-pane.lock/owner"
rmdir "$TEST_ROOT/fleet/.coordinator-pane.lock"
wait "$cleanup_pid"
[[ -f "$TEST_ROOT/managed-live" ]]
[[ ! -e "$TEST_ROOT/kills" ]]

# The final published owner retires only that exact Sergeant-marked pane.
run_cleanup task-inflight
if [[ -e "$TEST_ROOT/managed-live" ]]; then
  printf 'last cleaned fleet owner left managed coordinator pane alive\n' >&2
  exit 1
fi
[[ "$(cat "$TEST_ROOT/kills")" == '-t %71' ]]

printf 'sgt process convergence: ok\n'
