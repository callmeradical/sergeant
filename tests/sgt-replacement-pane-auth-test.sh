#!/usr/bin/env bash
# Real tmux regression for replacement ownership and crash adoption.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v tmux >/dev/null 2>&1 || { printf 'real tmux unavailable: skip\n'; exit 0; }
tmux_version="$(tmux -V | awk '{ print $2 }')"
[[ "$tmux_version" == 3.4* || "$tmux_version" == [4-9].* ]] || {
  printf 'tmux %s lacks tested pane-option contract: skip\n' "$tmux_version"
  exit 0
}

socket="sgt-replacement-auth-$$"
session="sgt-auth-$$"
trap 'tmux -L "$socket" kill-server 2>/dev/null || true' EXIT
tmux() { command tmux -L "$socket" "$@"; }

# The launcher resolves tmux from PATH, so make a private wrapper that binds it
# to this isolated server without changing production code.
TEST_ROOT="$(mktemp -d)"
trap 'command tmux -L "$socket" kill-server 2>/dev/null || true; rm -rf "$TEST_ROOT"' EXIT
cat > "$TEST_ROOT/tmux" <<EOF
#!/usr/bin/env bash
exec /usr/bin/tmux -L $socket "\$@"
EOF
chmod +x "$TEST_ROOT/tmux"
export PATH="$TEST_ROOT:$PATH"

launch_generation=11111111111111111111111111111111
launch_marker_path="$TEST_ROOT/launch-marker"
printf '%s\n' "$launch_generation" > "$launch_marker_path"
chmod 400 "$launch_marker_path"
launch_marker_identity="$(stat -Lc '%d:%i' "$launch_marker_path" 2>/dev/null || \
  stat -f '%d:%i' "$launch_marker_path")"
launch_marker="$launch_generation|$launch_marker_identity|198|$launch_marker_path"

tmux new-session -d -s "$session" -n base 'sleep 60'
token=11112222333344445555666677778888
role=worker:auth-test
window=replacement-auth
command_line="$(printf '%q %q %q %q %q %q' "$ROOT_DIR/bin/sgt-replacement-launch" \
  "$token" "$role" "$launch_marker" /bin/sleep 60)"
pane="$(tmux new-window -d -P -F '#{pane_id}' \
  -t "$session:" -n "$window" "$command_line")"

for _ in $(seq 1 100); do
  marker="$(tmux display-message -p -t "$pane" '#{@sergeant_replacement_token}|#{@sergeant_replacement_role}' 2>/dev/null || true)"
  [[ "$marker" == "$token|$role" ]] && break
  sleep 0.01
done
[[ "$marker" == "$token|$role" ]]

# Source after defining the isolated tmux function: all evidence queries must hit
# the same real server. Forget the returned id and adopt by exact server evidence.
# shellcheck source=bin/_sgt-response-lock.sh
source "$ROOT_DIR/bin/_sgt-lib.sh"
source "$ROOT_DIR/bin/_sgt-response-lock.sh"
scanned="$(tmux list-panes -a -F '#{pane_id}|#{window_name}' | awk -F'|' -v w="$window" '$2 == w { print $1 }')"
[[ "$scanned" == "$pane" ]]
identity="$(_sgt_pane_identity "$scanned")"
_sgt_replacement_pane_identity_matches "$identity" "$scanned" "$token" "$role" >/dev/null
original_auth="$(_sgt_replacement_pane_auth "$scanned" "$token" "$role")"
option_pid="$(tmux display-message -p -t "$scanned" '#{@sergeant_replacement_pid}')"
option_start="$(tmux display-message -p -t "$scanned" '#{@sergeant_replacement_start}')"
[[ "$original_auth" == "$scanned|$option_pid|$option_start|$token|$role" ]]

# tmux preserves pane options across respawn-pane. PID + process birth fencing
# must therefore reject the unrelated replacement even though token/role remain.
tmux respawn-pane -k -t "$scanned" '/bin/sleep 60'
for _ in $(seq 1 100); do
  respawn_pid="$(tmux display-message -p -t "$scanned" '#{pane_pid}')"
  [[ "$respawn_pid" != "$option_pid" ]] && break
  sleep 0.01
done
[[ "$respawn_pid" != "$option_pid" ]]
if _sgt_replacement_pane_auth "$scanned" "$token" "$role" >/dev/null 2>&1; then
  printf 'respawned unrelated process retained replacement ownership\n' >&2
  exit 1
fi
kill -0 "$respawn_pid"

# An authenticated launch that exits immediately is dead evidence, not a pane
# that can be adopted or confused with a later pane id.
tmux set-window-option -g remain-on-exit on
exit_pane="$(tmux new-window -d -P -F '#{pane_id}' -t "$session:" -n immediate-exit \
  "$(printf '%q %q %q %q %q' "$ROOT_DIR/bin/sgt-replacement-launch" \
    99990000111122223333444455556666 worker:exit "$launch_marker" /bin/true)")"
for _ in $(seq 1 100); do
  [[ "$(tmux display-message -p -t "$exit_pane" '#{pane_dead}')" == 1 ]] && break
  sleep 0.01
done
[[ "$(tmux display-message -p -t "$exit_pane" '#{pane_dead}')" == 1 ]]
if _sgt_replacement_pane_auth "$exit_pane" 99990000111122223333444455556666 worker:exit \
    >/dev/null 2>&1; then
  printf 'immediately exited replacement authenticated\n' >&2
  exit 1
fi

# A same-name foreign pane can contain the token in its shell command but lacks
# the pane-local marker and is never authenticated.
foreign="$(tmux new-window -d -P -F '#{pane_id}' -t "$session:" -n "$window" \
  "/bin/sh -c 'exec sleep 60' '$token'")"
foreign_identity="$(_sgt_pane_identity "$foreign")"
if _sgt_replacement_pane_identity_matches "$foreign_identity" "$foreign" "$token" "$role"; then
  printf 'foreign token-substring pane authenticated\n' >&2
  exit 1
fi

# A platform without /proc exact birth tokens authenticates the replacement by
# its stable tmux pane generation plus the exact worker marker capability.  It
# must neither fall back to second-resolution ps identity nor signal a PID/group.
portable_token=abcdefabcdefabcdefabcdefabcdefab
portable_role=worker:portable-auth
portable_generation=1234567890abcdef1234567890abcdef
portable_marker="$TEST_ROOT/portable-marker"
printf '%s\n' "$portable_generation" > "$portable_marker"
chmod 400 "$portable_marker"
portable_identity="$(stat -Lc '%d:%i' "$portable_marker" 2>/dev/null || \
  stat -f '%d:%i' "$portable_marker")"
portable_marker_record="$portable_generation|$portable_identity|198|$portable_marker"
portable_command="$(printf '%q %q %q %q %q %q %q %q %q' env \
  SGT_TEST_HOOKS=1 SGT_TEST_PROCESS_START_UNAVAILABLE=1 \
  "$ROOT_DIR/bin/sgt-replacement-launch" "$portable_token" "$portable_role" \
  "$portable_marker_record" /bin/sleep 60)"
portable_pane="$(tmux new-window -d -P -F '#{pane_id}' \
  -t "$session:" -n portable-replacement "$portable_command")"
for _ in $(seq 1 100); do
  portable_marker_auth="$(tmux display-message -p -t "$portable_pane" \
    '#{@sergeant_replacement_start}' 2>/dev/null || true)"
  [[ "$portable_marker_auth" == "portable:$portable_generation:$portable_identity" ]] && break
  sleep 0.01
done
[[ "$portable_marker_auth" == "portable:$portable_generation:$portable_identity" ]] || {
  printf 'PORTABLE_REPLACEMENT_LAUNCH_DID_NOT_PUBLISH_MARKER_CAPABILITY\n' >&2
  exit 1
}
portable_pane_identity="$(_sgt_pane_identity "$portable_pane")"
portable_auth="$(_sgt_replacement_pane_identity_matches "$portable_pane_identity" \
  "$portable_pane" "$portable_token" "$portable_role")" || {
  printf 'PORTABLE_REPLACEMENT_ADOPTION_REFUSED\n' >&2
  exit 1
}
[[ "$portable_auth" == "$portable_pane|"*"|portable:$portable_generation:$portable_identity|$portable_token|$portable_role" ]]

# The persisted pane identity and replacement marker authentication must bind
# the same pane generation.  A raced-in replacement that is internally valid
# must not authenticate against the caller's older snapshot.
_sgt_pane_identity() {
  printf '0|%%77|2222|222222|new-generation\n'
}
_sgt_replacement_pane_auth() {
  printf '%%77|2222|proc:222222|%s|%s\n' "$token" "$role"
}
if _sgt_replacement_pane_identity_matches \
    '0|%77|1111|111111|old-generation' '%77' "$token" "$role"; then
  printf 'REPLACEMENT_IDENTITY_ARG_IGNORED\n' >&2
  exit 1
fi

printf 'real tmux replacement pane authentication: ok\n'
