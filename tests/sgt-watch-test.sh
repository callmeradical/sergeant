#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
fleet="$TEST_ROOT/fleet"
task="$fleet/task-1"
worktree="$TEST_ROOT/worktree"
repo="$task/app"
fake_bin="$TEST_ROOT/bin"
mkdir -p "$repo" "$worktree" "$fake_bin"
printf '%s\n' "$worktree" > "$repo/worktree"
printf '%%42\n' > "$repo/pane"
printf '0|%%42|4242|123456|sgt-interactive-worker:%s\n' "$repo" > "$repo/pane_identity"
printf 'opencode\n' > "$repo/agent"
chmod 600 "$repo/pane_identity"
printf 'in_progress\n' > "$repo/status"

cat > "$fake_bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  display-message)
    [[ "${PANE_DEAD:-0}" == "0" ]] || exit 1
    printf '%s\n' "${PANE_IDENTITY:-0|%42|4242|123456|sgt-interactive-worker:$EXPECTED_WORKER}"
    ;;
esac
EOF
chmod +x "$fake_bin/tmux"

real_chmod="$(command -v chmod)"
real_stat="$(command -v stat)"
cat > "$fake_bin/chmod" <<'EOF'
#!/usr/bin/env bash
exec "$REAL_CHMOD" "$@"
EOF
chmod +x "$fake_bin/chmod"
export REAL_CHMOD="$real_chmod"
cat > "$fake_bin/stat" <<'EOF'
#!/usr/bin/env bash
last="${!#}"
if [[ "$last" == */pane_identity && -n "${LEGACY_IDENTITY_RACE:-}" && \
  -n "${LEGACY_IDENTITY_RACE_MARKER:-}" ]]; then
  count_file="${LEGACY_IDENTITY_RACE_MARKER}.count"
  count=0
  [[ ! -f "$count_file" ]] || count="$(cat "$count_file")"
  count=$((count + 1))
  printf '%s\n' "$count" > "$count_file"
  if [[ "$count" -eq 3 ]]; then
    case "$LEGACY_IDENTITY_RACE" in
      replace-content)
        printf 'tampered-pane\n' > "$last"
        chmod 664 "$last"
        ;;
      replace-path)
        rm -f "$last"
        printf 'tampered-pane\n' > "$last"
        chmod 664 "$last"
        ;;
    esac
    : > "$LEGACY_IDENTITY_RACE_MARKER"
  fi
fi
exec "$REAL_STAT" "$@"
EOF
chmod +x "$fake_bin/stat"
export REAL_STAT="$real_stat"

printf 'needs_input\n' > "$worktree/.sergeant-status"
printf 'Choose a safe option.\n' > "$worktree/.sergeant-message"
EXPECTED_WORKER="$repo" PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" "$ROOT/bin/sgt-watch" --sync task-1
[[ "$(cat "$repo/status")" == "needs_input" ]]
[[ "$(cat "$repo/message")" == "Choose a safe option." ]]
PANE_DEAD=1 EXPECTED_WORKER="$repo" PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" "$ROOT/bin/sgt-watch" --sync task-1
[[ "$(cat "$repo/status")" == "needs_input" ]]

printf 'in_progress\n' > "$worktree/.sergeant-status"
printf 'in_progress\n' > "$repo/status"
rm -f "$repo/pane_identity"
printf -v legacy_command '%q %q %q %q' \
  "$ROOT/bin/sgt-interactive-worker" "$repo" "$worktree" opencode
legacy_identity="0|%42|4242|123457|$legacy_command"
PANE_IDENTITY="$legacy_identity" EXPECTED_WORKER="$repo" PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$fleet" "$ROOT/bin/sgt-watch" --sync task-1
[[ "$(cat "$repo/status")" == "in_progress" ]]
[[ "$(cat "$repo/pane_identity")" == "$legacy_identity" ]]
[[ "$(cat "$repo/pane_identity_migration")" == "$legacy_identity" ]]

for legacy_mode in 664 640; do
  printf '%s\n' "$legacy_identity" > "$repo/pane_identity"
  chmod "$legacy_mode" "$repo/pane_identity"
  printf 'in_progress\n' > "$worktree/.sergeant-status"
  printf 'in_progress\n' > "$repo/status"
  PANE_IDENTITY="$legacy_identity" EXPECTED_WORKER="$repo" PATH="$fake_bin:$PATH" \
    SERGEANT_FLEET="$fleet" "$ROOT/bin/sgt-watch" --sync task-1
  [[ "$(cat "$repo/status")" == "in_progress" ]]
  [[ "$(cat "$repo/pane_identity")" == "$legacy_identity" ]]
  [[ "$(stat -c '%a' "$repo/pane_identity" 2>/dev/null || stat -f '%Lp' "$repo/pane_identity")" == \
    "600" ]]
done

printf '%s\n' "$legacy_identity" > "$repo/pane_identity"
chmod 664 "$repo/pane_identity"
legacy_race_marker="$TEST_ROOT/legacy-pane-race"
printf 'in_progress\n' > "$worktree/.sergeant-status"
printf 'in_progress\n' > "$repo/status"
LEGACY_IDENTITY_RACE=replace-content LEGACY_IDENTITY_RACE_MARKER="$legacy_race_marker" \
  PANE_IDENTITY="$legacy_identity" EXPECTED_WORKER="$repo" PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$fleet" "$ROOT/bin/sgt-watch" --sync task-1
[[ "$(cat "$repo/pane_identity")" == "$legacy_identity" ]]
[[ "$(stat -c '%a' "$repo/pane_identity" 2>/dev/null || stat -f '%Lp' "$repo/pane_identity")" == \
  "600" ]]
[[ -e "$legacy_race_marker" ]]

printf '%s\n' "$legacy_identity" > "$repo/pane_identity"
chmod 664 "$repo/pane_identity"
legacy_replace_marker="$TEST_ROOT/legacy-pane-replaced"
printf 'in_progress\n' > "$worktree/.sergeant-status"
printf 'in_progress\n' > "$repo/status"
LEGACY_IDENTITY_RACE=replace-path LEGACY_IDENTITY_RACE_MARKER="$legacy_replace_marker" \
  PANE_IDENTITY="$legacy_identity" EXPECTED_WORKER="$repo" PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$fleet" "$ROOT/bin/sgt-watch" --sync task-1
[[ "$(cat "$repo/status")" == "orphaned" ]]
[[ "$(cat "$repo/pane_identity")" == "tampered-pane" ]]
[[ "$(stat -c '%a' "$repo/pane_identity" 2>/dev/null || stat -f '%Lp' "$repo/pane_identity")" == \
  "664" ]]
[[ -e "$legacy_replace_marker" ]]

for forged_command in "wrapper $legacy_command extra" "${legacy_command}-prefix-collision"; do
  rm -f "$repo/pane_identity"
  printf 'in_progress\n' > "$worktree/.sergeant-status"
  printf 'in_progress\n' > "$repo/status"
  PANE_IDENTITY="0|%42|9999|999999|$forged_command" \
    EXPECTED_WORKER="$repo" PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
    "$ROOT/bin/sgt-watch" --sync task-1
  [[ "$(cat "$repo/status")" == "orphaned" ]]
  [[ ! -e "$repo/pane_identity" ]]
done

printf '0|%%42|4242|123456|sgt-interactive-worker:%s\n' "$repo" > "$repo/pane_identity"

printf 'done\n' > "$worktree/.sergeant-status"
rm -f "$worktree/.sergeant-result"
EXPECTED_WORKER="$repo" PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" "$ROOT/bin/sgt-watch" --sync task-1
[[ "$(cat "$repo/status")" == "orphaned" ]]
grep -Fq 'done requires result' "$repo/diagnostic"

printf 'in_progress\n' > "$worktree/.sergeant-status"
printf 'in_progress\n' > "$repo/status"
PANE_DEAD=1 EXPECTED_WORKER="$repo" PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" "$ROOT/bin/sgt-watch" --sync task-1
[[ "$(cat "$repo/status")" == "orphaned" ]]
grep -Fq 'dead or is not the expected worker supervisor' "$repo/diagnostic"

printf 'in_progress\n' > "$worktree/.sergeant-status"
printf 'in_progress\n' > "$repo/status"
PANE_IDENTITY="0|%42|4242|123456|bash sgt-interactive-worker:$repo" \
  EXPECTED_WORKER="$repo" PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  "$ROOT/bin/sgt-watch" --sync task-1
[[ "$(cat "$repo/status")" == "orphaned" ]]

printf 'done\n' > "$worktree/.sergeant-status"
printf 'https://example.invalid/pr/1\n' > "$worktree/.sergeant-result"
printf 'validation\n' > "$repo/stage"
printf 'checks-passed\n' > "$repo/validation_status"
EXPECTED_WORKER="$repo" PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" "$ROOT/bin/sgt-watch" --sync task-1
[[ "$(cat "$repo/status")" == "done" ]]
[[ "$(cat "$repo/result")" == "https://example.invalid/pr/1" ]]
list_output="$(SERGEANT_FLEET="$fleet" "$ROOT/bin/sgt-watch" --list)"
grep -Fq '1 done' <<< "$list_output"
watch_output="$(SERGEANT_WATCH_INTERVAL=0 EXPECTED_WORKER="$repo" PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  "$ROOT/bin/sgt-watch" task-1)"
grep -Fq 'All repos done.' <<< "$watch_output"
grep -Fq '[stage=validation validation=checks-passed]' <<< "$watch_output"

printf 'sgt-watch local fleet sync: ok\n'
