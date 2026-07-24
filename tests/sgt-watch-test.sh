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
