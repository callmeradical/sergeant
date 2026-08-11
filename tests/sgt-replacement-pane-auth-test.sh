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

tmux new-session -d -s "$session" -n base 'sleep 60'
token=11112222333344445555666677778888
role=worker:auth-test
window=replacement-auth
command_line="$(printf '%q %q %q %q %q' "$ROOT_DIR/bin/sgt-replacement-launch" \
  "$token" "$role" /bin/sleep 60)"
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
_sgt_replacement_pane_identity_matches "$identity" "$scanned" "$token" "$role"

# A same-name foreign pane can contain the token in its shell command but lacks
# the pane-local marker and is never authenticated.
foreign="$(tmux new-window -d -P -F '#{pane_id}' -t "$session:" -n "$window" \
  "/bin/sh -c 'exec sleep 60' '$token'")"
foreign_identity="$(_sgt_pane_identity "$foreign")"
if _sgt_replacement_pane_identity_matches "$foreign_identity" "$foreign" "$token" "$role"; then
  printf 'foreign token-substring pane authenticated\n' >&2
  exit 1
fi

printf 'real tmux replacement pane authentication: ok\n'
