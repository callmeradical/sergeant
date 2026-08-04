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
export TMUX_LOG="$TEST_ROOT/tmux.log"
export TMUX_STATE="$TEST_ROOT/tmux.state"
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
    target=""
    previous=""
    for argument in "$@"; do
      [[ "$previous" == -t ]] && target="$argument"
      previous="$argument"
    done
    if [[ -n "${RECOVERY_RACE_MARKER:-}" && ! -e "$RECOVERY_RACE_MARKER" &&
          "$target" == "${RECOVERY_RACE_OLD_PANE:-%42}" ]]; then
      old_identity="$(cat "$EXPECTED_WORKER/pane_identity")"
      printf 'launching\n' > "$EXPECTED_WORKER/replacement_phase"
      printf '%s\n' "$RECOVERY_RACE_NEW_IDENTITY" > "$EXPECTED_WORKER/pane_identity"
      chmod 600 "$EXPECTED_WORKER/replacement_phase" "$EXPECTED_WORKER/pane_identity"
      : > "$RECOVERY_RACE_MARKER"
      printf '%s\n' "$old_identity"
      exit 0
    fi
    extra_identity="${EXTRA_PANE_IDENTITY:-}"
    extra_remainder="${extra_identity#*|}"
    extra_pane="${extra_remainder%%|*}"
    if [[ -n "$extra_identity" && "$target" == "$extra_pane" ]]; then
      [[ -z "${EXTRA_TMUX_STATE:-}" || ! -e "$EXTRA_TMUX_STATE" ]] || exit 1
      printf '%s\n' "$extra_identity"
      exit 0
    fi
    [[ ! -e "$TMUX_STATE" ]] || exit 1
    [[ "${PANE_DEAD:-0}" == "0" ]] || exit 1
    case "${!#}" in
      '#{pane_id}')
        printf '%%42\n'
        ;;
      '#{pane_activity}')
        printf '%s\n' "${PANE_ACTIVITY:-0}"
        ;;
      *)
        printf '%s\n' "${PANE_IDENTITY:-$(cat "$EXPECTED_WORKER/pane_identity")}"
        ;;
    esac
    ;;
  list-panes)
    if [[ ! -e "$TMUX_STATE" && "${PANE_DEAD:-0}" == "0" ]]; then
      current_identity="${PANE_IDENTITY:-$(cat "$EXPECTED_WORKER/pane_identity")}"
      if [[ "${!#}" == '#{pane_id}' ]]; then
        current_remainder="${current_identity#*|}"
        printf '%s\n' "${current_remainder%%|*}"
      else
        printf '%s\n' "$current_identity"
      fi
    fi
    if [[ -n "${EXTRA_PANE_IDENTITY:-}" &&
          ( -z "${EXTRA_TMUX_STATE:-}" || ! -e "$EXTRA_TMUX_STATE" ) ]]; then
      if [[ "${!#}" == '#{pane_id}' ]]; then
        extra_remainder="${EXTRA_PANE_IDENTITY#*|}"
        printf '%s\n' "${extra_remainder%%|*}"
      else
        printf '%s\n' "$EXTRA_PANE_IDENTITY"
      fi
    fi
    if [[ -n "${UNRELATED_PANE_IDENTITY:-}" ]]; then
      if [[ "${!#}" == '#{pane_id}' ]]; then
        unrelated_remainder="${UNRELATED_PANE_IDENTITY#*|}"
        printf '%s\n' "${unrelated_remainder%%|*}"
      else
        printf '%s\n' "$UNRELATED_PANE_IDENTITY"
      fi
    fi
    ;;
  kill-pane)
    printf '%s\n' "$*" >> "$TMUX_LOG"
    target="${!#}"
    extra_identity="${EXTRA_PANE_IDENTITY:-}"
    extra_remainder="${extra_identity#*|}"
    extra_pane="${extra_remainder%%|*}"
    if [[ -n "$extra_pane" && "$target" == "$extra_pane" && -n "${EXTRA_TMUX_STATE:-}" ]]; then
      : > "$EXTRA_TMUX_STATE"
    else
      : > "$TMUX_STATE"
    fi
    ;;
esac
EOF
chmod +x "$fake_bin/tmux"

real_chmod="$(command -v chmod)"
real_stat="$(command -v stat)"
cat > "$fake_bin/chmod" <<'EOF'
#!/usr/bin/env bash
last="${!#}"
if [[ "$last" == /dev/fd/9 && -n "${LEGACY_IDENTITY_RACE:-}" &&
      -n "${LEGACY_IDENTITY_RACE_MARKER:-}" &&
      ! -e "$LEGACY_IDENTITY_RACE_MARKER" ]]; then
  case "$LEGACY_IDENTITY_RACE" in
    replace-content)
      printf 'tampered-pane\n' > "$LEGACY_IDENTITY_PATH"
      "$REAL_CHMOD" 664 "$LEGACY_IDENTITY_PATH"
      ;;
    replace-path)
      rm -f "$LEGACY_IDENTITY_PATH"
      printf 'tampered-pane\n' > "$LEGACY_IDENTITY_PATH"
      "$REAL_CHMOD" 664 "$LEGACY_IDENTITY_PATH"
      ;;
  esac
  : > "$LEGACY_IDENTITY_RACE_MARKER"
fi
exec "$REAL_CHMOD" "$@"
EOF
chmod +x "$fake_bin/chmod"
export REAL_CHMOD="$real_chmod"
cat > "$fake_bin/stat" <<'EOF'
#!/usr/bin/env bash
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
  LEGACY_IDENTITY_PATH="$repo/pane_identity" \
  PANE_IDENTITY="$legacy_identity" EXPECTED_WORKER="$repo" PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$fleet" "$ROOT/bin/sgt-watch" --sync task-1
[[ "$(cat "$repo/status")" == "orphaned" ]]
[[ "$(cat "$repo/pane_identity")" == "tampered-pane" ]]
[[ "$(stat -c '%a' "$repo/pane_identity" 2>/dev/null || stat -f '%Lp' "$repo/pane_identity")" == \
  "600" ]]
[[ -e "$legacy_race_marker" ]]

printf '%s\n' "$legacy_identity" > "$repo/pane_identity"
chmod 664 "$repo/pane_identity"
legacy_replace_marker="$TEST_ROOT/legacy-pane-replaced"
printf 'in_progress\n' > "$worktree/.sergeant-status"
printf 'in_progress\n' > "$repo/status"
LEGACY_IDENTITY_RACE=replace-path LEGACY_IDENTITY_RACE_MARKER="$legacy_replace_marker" \
  LEGACY_IDENTITY_PATH="$repo/pane_identity" \
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

printf '%s\n' "$legacy_identity" > "$repo/pane_identity"

# Recovery publishes its journal and new identity before the new pane pointer.
# A sync that observed no journal before this window must not orphan the worker.
recovery_race_marker="$TEST_ROOT/recovery-publication-race"
recovery_new_identity="0|%43|4343|123458|$legacy_command"
printf '%%42\n' > "$repo/pane"
chmod 600 "$repo/pane_identity"
printf 'in_progress\n' > "$worktree/.sergeant-status"
printf 'in_progress\n' > "$repo/status"
RECOVERY_RACE_MARKER="$recovery_race_marker" \
  RECOVERY_RACE_NEW_IDENTITY="$recovery_new_identity" \
  EXPECTED_WORKER="$repo" PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  "$ROOT/bin/sgt-watch" --sync task-1
[[ -e "$recovery_race_marker" ]]
[[ "$(cat "$repo/status")" == "in_progress" ]]
[[ "$(cat "$worktree/.sergeant-status")" == "in_progress" ]]
[[ "$(cat "$repo/replacement_phase")" == "launching" ]]

# Complete the simulated recovery and prove the next coherent observation is live.
printf '%%43\n' > "$repo/pane"
rm -f "$repo/replacement_phase"
PANE_IDENTITY="$recovery_new_identity" EXPECTED_WORKER="$repo" \
  PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  "$ROOT/bin/sgt-watch" --sync task-1
[[ "$(cat "$repo/status")" == "in_progress" ]]

# response-pending is a valid transport phase, not an unreadable replacement.
printf 'blocked\n' > "$worktree/.sergeant-status"
printf 'needs_input\n' > "$repo/status"
printf 'response-pending\n' > "$repo/replacement_phase"
chmod 600 "$repo/replacement_phase"
printf 'worker replacement journal is unreadable; reconciliation required\n' \
  > "$repo/diagnostic"
PANE_IDENTITY="$recovery_new_identity" EXPECTED_WORKER="$repo" \
  PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  "$ROOT/bin/sgt-watch" --sync task-1
[[ "$(cat "$repo/status")" == "needs_input" ]]
[[ "$(cat "$repo/replacement_phase")" == "response-pending" ]]
[[ ! -e "$repo/diagnostic" ]]
rm -f "$repo/replacement_phase"

printf 'unknown-phase\n' > "$repo/replacement_phase"
chmod 600 "$repo/replacement_phase"
PANE_IDENTITY="$recovery_new_identity" EXPECTED_WORKER="$repo" \
  PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  "$ROOT/bin/sgt-watch" --sync task-1
[[ "$(cat "$repo/replacement_phase")" == "unknown-phase" ]]
grep -Fq 'worker replacement journal is unreadable; reconciliation required' \
  "$repo/diagnostic"
rm -f "$repo/replacement_phase" "$repo/diagnostic"

# Restore the original pane fixture for terminal recycling coverage below.
printf '%%42\n' > "$repo/pane"
printf '%s\n' "$legacy_identity" > "$repo/pane_identity"
chmod 600 "$repo/pane_identity"

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
grep -Fq 'kill-pane -t %42' "$TMUX_LOG"
[[ -s "$repo/worker_recycled" ]]
grep -Fq 'pane_identity=0|%42|' "$repo/worker_recycled"

# A prior recycle receipt and stale current pointer must not hide an older live
# pane that owns this exact worker command.
printf 'drained\n' > "$worktree/.sergeant-status"
printf 'drained\n' > "$repo/status"
printf 'drained\n' > "$worktree/.sergeant-drained"
printf '%%99\n' > "$repo/pane"
printf '0|%%99|9999|654321|missing-current-worker\n' > "$repo/pane_identity"
chmod 600 "$repo/pane_identity"
recorded_executable="$TEST_ROOT/old install/bin/sgt-interactive-worker"
printf '%s\n' "$recorded_executable" > "$repo/worker_executable"
printf '9999\n' > "$repo/worker_pid"
printf 'Tue Jan  2 00:00:00 2024\n' > "$repo/worker_process_start"
chmod 600 "$repo/worker_executable" "$repo/worker_pid" "$repo/worker_process_start"

rm -f "$repo/drain_handoff" "$repo/diagnostic"
EXPECTED_WORKER="$repo" PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  "$ROOT/bin/sgt-watch" --sync task-1
grep -Fq 'drained worker lacks durable handoff evidence; refusing recycle' \
  "$repo/diagnostic"

printf 'worker_pid=9999\nworker_start=Tue Jan  2 00:00:00 2024\n' \
  > "$repo/drain_handoff"
chmod 600 "$repo/drain_handoff"
EXPECTED_WORKER="$repo" PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  "$ROOT/bin/sgt-watch" --sync task-1
[[ ! -e "$repo/diagnostic" ]]

printf 'manual reconciliation note\n' > "$repo/diagnostic"
EXPECTED_WORKER="$repo" PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  "$ROOT/bin/sgt-watch" --sync task-1
[[ "$(cat "$repo/diagnostic")" == 'manual reconciliation note' ]]
rm -f "$repo/diagnostic"

printf 'worker_pid=4242\nworker_start=Mon Jan  1 00:00:00 2024\n' \
  > "$repo/drain_handoff"
chmod 600 "$repo/drain_handoff"
printf -v stale_command '%q %q %q %q' \
  "$recorded_executable" "$repo" "$worktree" opencode
tmux_stale_command="${stale_command//\\/\\\\}"
extra_identity="0|%41|4141|123455|\"$tmux_stale_command\""
unrelated_identity="0|%39|3939|123453|/bin/sh -c $stale_command"
EXPECTED_WORKER="$repo" EXTRA_PANE_IDENTITY="$extra_identity" \
  UNRELATED_PANE_IDENTITY="$unrelated_identity" \
  EXTRA_TMUX_STATE="$TEST_ROOT/extra-tmux.state" \
  PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  "$ROOT/bin/sgt-watch" --sync task-1
[[ "$(cat "$repo/status")" == "drained" ]]
[[ ! -e "$TEST_ROOT/extra-tmux.state" ]]
grep -Fq 'drain handoff does not match current worker identity' "$repo/diagnostic"

printf 'worker_pid=9999\nworker_start=Tue Jan  2 00:00:00 2024\n' \
  > "$repo/drain_handoff"
chmod 600 "$repo/drain_handoff"
EXPECTED_WORKER="$repo" EXTRA_PANE_IDENTITY="$extra_identity" \
  UNRELATED_PANE_IDENTITY="$unrelated_identity" \
  EXTRA_TMUX_STATE="$TEST_ROOT/extra-tmux.state" \
  PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  "$ROOT/bin/sgt-watch" --sync task-1
grep -Fq 'kill-pane -t %41' "$TMUX_LOG"
[[ ! -e "$repo/diagnostic" ]]
if grep -Fq 'kill-pane -t %39' "$TMUX_LOG"; then
  printf 'unrelated terminal pane was recycled\n' >&2
  exit 1
fi

for preserved_status in blocked waiting orphaned; do
  rm -f "$TEST_ROOT/preserved-tmux.state"
  printf '%s\n' "$preserved_status" > "$worktree/.sergeant-status"
  printf '%s\n' "$preserved_status" > "$repo/status"
  preserved_identity="0|%40|4040|123454|$legacy_command"
  EXPECTED_WORKER="$repo" EXTRA_PANE_IDENTITY="$preserved_identity" \
    EXTRA_TMUX_STATE="$TEST_ROOT/preserved-tmux.state" \
    PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
    "$ROOT/bin/sgt-watch" --sync task-1
  if grep -Fq 'kill-pane -t %40' "$TMUX_LOG"; then
    printf 'nonterminal %s worker pane was recycled\n' "$preserved_status" >&2
    exit 1
  fi
done

printf 'done\n' > "$worktree/.sergeant-status"
printf 'done\n' > "$repo/status"
printf 'https://example.invalid/pr/1\n' > "$worktree/.sergeant-result"
rm -f "$worktree/.sergeant-drained"
rm -f "$repo/drain_handoff"

incomplete_repo="$fleet/task-incomplete/app"
mkdir -p "$incomplete_repo"
printf 'dispatched\n' > "$incomplete_repo/status"
printf '1\n' > "$incomplete_repo/dispatch_started"
fresh_dispatch_repo="$fleet/task-fresh-dispatch/app"
mkdir -p "$fresh_dispatch_repo"
printf 'dispatched\n' > "$fresh_dispatch_repo/status"
date +%s > "$fresh_dispatch_repo/dispatch_started"
pending_worktree_repo="$fleet/task-pending-worktree/app"
pending_worktree="$TEST_ROOT/pending-worktree"
mkdir -p "$pending_worktree_repo" "$pending_worktree"
printf 'dispatched\n' > "$pending_worktree_repo/status"
printf '%s\n' "$pending_worktree" > "$pending_worktree_repo/worktree"
printf '1\n' > "$pending_worktree_repo/dispatch_started"
fresh_pending_repo="$fleet/task-fresh-pending-worktree/app"
fresh_pending_worktree="$TEST_ROOT/fresh-pending-worktree"
mkdir -p "$fresh_pending_repo" "$fresh_pending_worktree"
printf 'dispatched\n' > "$fresh_pending_repo/status"
printf '%s\n' "$fresh_pending_worktree" > "$fresh_pending_repo/worktree"
date +%s > "$fresh_pending_repo/dispatch_started"
orphan_repo="$fleet/task-orphan/app"
mkdir -p "$orphan_repo"
printf 'orphaned\n' > "$orphan_repo/status"
blocked_repo="$fleet/task-blocked/app"
mkdir -p "$blocked_repo"
printf 'blocked\n' > "$blocked_repo/status"
needs_input_repo="$fleet/task-needs-input/app"
mkdir -p "$needs_input_repo"
printf 'needs_input\n' > "$needs_input_repo/status"
unowned_repo="$fleet/task-unowned/app"
unowned_worktree="$TEST_ROOT/unowned-worktree"
mkdir -p "$unowned_repo" "$unowned_worktree"
printf '%s\n' "$unowned_worktree" > "$unowned_repo/worktree"
printf 'in_progress\n' > "$unowned_repo/status"
printf 'in_progress\n' > "$unowned_worktree/.sergeant-status"
missing_worktree_repo="$fleet/task-missing-worktree/app"
mkdir -p "$missing_worktree_repo"
printf '%s\n' "$TEST_ROOT/missing-worktree" > "$missing_worktree_repo/worktree"
printf 'in_progress\n' > "$missing_worktree_repo/status"
EXPECTED_WORKER="$repo" PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  "$ROOT/bin/sgt-watch" --sync-all
[[ "$(cat "$incomplete_repo/status")" == \
  'failed: dispatch incomplete: no worktree or owned live pane' ]]
grep -Fq 'dispatch never acquired a worktree or owned live pane' "$incomplete_repo/diagnostic"
[[ "$(cat "$fresh_dispatch_repo/status")" == "dispatched" ]]
[[ "$(cat "$pending_worktree_repo/status")" == \
  'failed: dispatch incomplete: no worktree or owned live pane' ]]
grep -Fq 'dispatch never acquired a worktree or owned live pane' "$pending_worktree_repo/diagnostic"
[[ "$(cat "$fresh_pending_repo/status")" == "dispatched" ]]
[[ "$(cat "$orphan_repo/status")" == "orphaned" ]]
[[ "$(cat "$blocked_repo/status")" == "blocked" ]]
[[ "$(cat "$needs_input_repo/status")" == "needs_input" ]]
[[ "$(cat "$unowned_repo/status")" == "orphaned" ]]
grep -Fq 'has no recorded worker pane' "$unowned_repo/diagnostic"
[[ "$(cat "$missing_worktree_repo/status")" == "orphaned" ]]
grep -Fq 'recorded worktree is unavailable' "$missing_worktree_repo/diagnostic"
cat > "$task/notify" <<'EOF'
event=escalation
updated=2026-07-25T00:00:00Z
EOF
list_output="$(SERGEANT_FLEET="$fleet" "$ROOT/bin/sgt-watch" --list)"
grep -Fq '1 done' <<< "$list_output"
grep -Fq 'notify:  escalation' <<< "$list_output"
watch_output="$(SERGEANT_WATCH_INTERVAL=0 EXPECTED_WORKER="$repo" PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  "$ROOT/bin/sgt-watch" task-1)"
grep -Fq 'All repos done.' <<< "$watch_output"
grep -Fq '[stage=validation validation=checks-passed]' <<< "$watch_output"

# === Stall detection tests ===
# Isolated task/worktree so stall tests don't disturb earlier state.
# Reset fake tmux state so the stall tests see a live pane.
rm -f "$TMUX_STATE"
stall_task="$fleet/task-stall"
stall_repo="$stall_task/app"
stall_worktree="$TEST_ROOT/stall-worktree"
mkdir -p "$stall_repo" "$stall_worktree"
printf '%s\n' "$stall_worktree" > "$stall_repo/worktree"
printf '%%42\n' > "$stall_repo/pane"
printf 'opencode\n' > "$stall_repo/agent"
# pane_identity: pane_dead=0, pane_id=%42, pane_pid=4242, created=123456, command=...
printf '0|%%42|4242|123456|sgt-interactive-worker:%s\n' "$stall_repo" > "$stall_repo/pane_identity"
chmod 600 "$stall_repo/pane_identity"
printf 'in_progress\n' > "$stall_repo/status"
printf 'in_progress\n' > "$stall_worktree/.sergeant-status"
# PANE_ACTIVITY is injected via fake tmux #{pane_activity} (default 0 = stale/unavailable)

# --- Test 1: stale progress_ts + stale pane_activity → stall diagnostic ---
# Status stays in_progress; diagnostic is nonterminal.
printf '1000\n' > "$stall_repo/progress_ts"
rm -f "$stall_repo/diagnostic"
SERGEANT_STALL_GRACE_SECONDS=300 SERGEANT_STALL_NOW=1401 \
  EXPECTED_WORKER="$stall_repo" PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$fleet" "$ROOT/bin/sgt-watch" --sync task-stall
[[ "$(cat "$stall_repo/status")" == "in_progress" ]]
grep -Fq 'live worker stalled' "$stall_repo/diagnostic"
grep -Fq '401' "$stall_repo/diagnostic"
grep -Fq 'epoch 1000' "$stall_repo/diagnostic"
# Privacy: diagnostic must not contain message bodies, prompts, or tokens
if grep -qiE 'message|prompt|token|secret' "$stall_repo/diagnostic" 2>/dev/null; then
  printf 'privacy violation: stall diagnostic contains sensitive terms\n' >&2; exit 1
fi

# --- Test 2: recent progress_ts — no stall diagnostic ---
# pane_activity default 0 (stale); progress_ts alone is recent enough
rm -f "$stall_repo/diagnostic"
printf '1090\n' > "$stall_repo/progress_ts"
SERGEANT_STALL_GRACE_SECONDS=300 SERGEANT_STALL_NOW=1100 \
  EXPECTED_WORKER="$stall_repo" PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$fleet" "$ROOT/bin/sgt-watch" --sync task-stall
[[ "$(cat "$stall_repo/status")" == "in_progress" ]]
[[ ! -f "$stall_repo/diagnostic" ]]

# --- Test 3: recent pane_activity → not stalled even with stale progress_ts ---
# Covers tool calls, long-running commands, and streamed continuations: any terminal
# output from the agent keeps pane_activity fresh regardless of progress_ts.
printf '1000\n' > "$stall_repo/progress_ts"
rm -f "$stall_repo/diagnostic"
PANE_ACTIVITY=1390 SERGEANT_STALL_GRACE_SECONDS=300 SERGEANT_STALL_NOW=1401 \
  EXPECTED_WORKER="$stall_repo" PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$fleet" "$ROOT/bin/sgt-watch" --sync task-stall
[[ "$(cat "$stall_repo/status")" == "in_progress" ]]
[[ ! -f "$stall_repo/diagnostic" ]]

# --- Test 4: same elapsed bucket — diagnostic not rewritten (idempotent display) ---
printf '1000\n' > "$stall_repo/progress_ts"
rm -f "$stall_repo/diagnostic"
SERGEANT_STALL_GRACE_SECONDS=300 SERGEANT_STALL_NOW=1401 \
  EXPECTED_WORKER="$stall_repo" PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$fleet" "$ROOT/bin/sgt-watch" --sync task-stall
first_stall_diag="$(cat "$stall_repo/diagnostic")"
# Second sync same STALL_NOW=1401: elapsed=401, bucket unchanged → no rewrite
SERGEANT_STALL_GRACE_SECONDS=300 SERGEANT_STALL_NOW=1401 \
  EXPECTED_WORKER="$stall_repo" PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$fleet" "$ROOT/bin/sgt-watch" --sync task-stall
[[ "$(cat "$stall_repo/diagnostic")" == "$first_stall_diag" ]]
[[ "$(cat "$stall_repo/status")" == "in_progress" ]]
# Advance STALL_NOW within same bucket (bucket=60: elapsed 401→455, both 401/60=455/60=7)
# Use bucket=100 to make the boundary clear: 401/100=4, 499/100=4 same; 500/100=5 different
SERGEANT_STALL_GRACE_SECONDS=300 SERGEANT_STALL_NOW=1499 SERGEANT_STALL_DIAG_BUCKET=100 \
  EXPECTED_WORKER="$stall_repo" PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$fleet" "$ROOT/bin/sgt-watch" --sync task-stall
# Still same bucket (499/100=4): diagnostic not rewritten, still shows "for 401s"
grep -Fq 'for 401s' "$stall_repo/diagnostic"
# Now advance into next bucket (500/100=5): diagnostic rewritten with new elapsed
SERGEANT_STALL_GRACE_SECONDS=300 SERGEANT_STALL_NOW=1500 SERGEANT_STALL_DIAG_BUCKET=100 \
  EXPECTED_WORKER="$stall_repo" PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$fleet" "$ROOT/bin/sgt-watch" --sync task-stall
grep -Fq 'for 500s' "$stall_repo/diagnostic"
[[ "$(cat "$stall_repo/status")" == "in_progress" ]]

# --- Test 5: stall diagnostic clears on needs_input transition ---
printf 'live worker stalled: no progress for 401s (grace=300s); last event at epoch 1000\n' \
  > "$stall_repo/diagnostic"
printf 'needs_input\n' > "$stall_worktree/.sergeant-status"
SERGEANT_STALL_GRACE_SECONDS=300 SERGEANT_STALL_NOW=1401 \
  EXPECTED_WORKER="$stall_repo" PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$fleet" "$ROOT/bin/sgt-watch" --sync task-stall
[[ "$(cat "$stall_repo/status")" == "needs_input" ]]
[[ ! -f "$stall_repo/diagnostic" ]]

# --- Test 6: stall diagnostic clears on blocked transition ---
printf 'live worker stalled: no progress for 401s (grace=300s); last event at epoch 1000\n' \
  > "$stall_repo/diagnostic"
printf 'blocked\n' > "$stall_worktree/.sergeant-status"
SERGEANT_STALL_GRACE_SECONDS=300 SERGEANT_STALL_NOW=1401 \
  EXPECTED_WORKER="$stall_repo" PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$fleet" "$ROOT/bin/sgt-watch" --sync task-stall
[[ "$(cat "$stall_repo/status")" == "blocked" ]]
[[ ! -f "$stall_repo/diagnostic" ]]

# --- Test 7: stall clears when progress_ts updated (pane_activity stays stale) ---
printf 'in_progress\n' > "$stall_worktree/.sergeant-status"
printf 'in_progress\n' > "$stall_repo/status"
printf '1000\n' > "$stall_repo/progress_ts"
rm -f "$stall_repo/diagnostic"
# First sync: stall detected
SERGEANT_STALL_GRACE_SECONDS=300 SERGEANT_STALL_NOW=1401 \
  EXPECTED_WORKER="$stall_repo" PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$fleet" "$ROOT/bin/sgt-watch" --sync task-stall
grep -Fq 'live worker stalled' "$stall_repo/diagnostic"
# Update progress_ts: stall clears on next sync
printf '1350\n' > "$stall_repo/progress_ts"
SERGEANT_STALL_GRACE_SECONDS=300 SERGEANT_STALL_NOW=1401 \
  EXPECTED_WORKER="$stall_repo" PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$fleet" "$ROOT/bin/sgt-watch" --sync task-stall
[[ ! -f "$stall_repo/diagnostic" ]]
[[ "$(cat "$stall_repo/status")" == "in_progress" ]]

# --- Test 8: long-running command with recent terminal output stays in_progress ---
# Recent pane_activity (command producing output) overrides stale progress_ts.
printf 'in_progress\n' > "$stall_worktree/.sergeant-status"
printf 'in_progress\n' > "$stall_repo/status"
printf '1000\n' > "$stall_repo/progress_ts"
rm -f "$stall_repo/diagnostic"
PANE_ACTIVITY=9900 SERGEANT_STALL_GRACE_SECONDS=300 SERGEANT_STALL_NOW=9999 \
  EXPECTED_WORKER="$stall_repo" PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$fleet" "$ROOT/bin/sgt-watch" --sync task-stall
[[ "$(cat "$stall_repo/status")" == "in_progress" ]]
[[ ! -f "$stall_repo/diagnostic" ]]

printf 'sgt-watch stall detection: ok\n'
printf 'sgt-watch local fleet sync: ok\n'

# ── drained worker: sync, list, and watch exit behavior ──────────────────────

drained_fleet="$TEST_ROOT/fleet-drained"
drained_task="$drained_fleet/task-drained"
drained_wt="$TEST_ROOT/drained-wt"
mkdir -p "$drained_task/drainedrepo" "$drained_wt"
printf 'Brief: drained lifecycle test\n' > "$drained_task/brief.md"
printf '%s\n' "$drained_wt" > "$drained_task/drainedrepo/worktree"
printf 'local-tmux\n' > "$drained_task/drainedrepo/backend"
printf 'drained\n' > "$drained_wt/.sergeant-status"
printf 'drained\n' > "$drained_wt/.sergeant-drained"
printf 'worker_pid=4242\nworker_start=Mon Jan  1 00:00:00 2024\n' \
  > "$drained_task/drainedrepo/drain_handoff"
printf '4242\n' > "$drained_task/drainedrepo/worker_pid"
printf 'Mon Jan  1 00:00:00 2024\n' \
  > "$drained_task/drainedrepo/worker_process_start"
chmod 600 "$drained_task/drainedrepo/drain_handoff" \
  "$drained_task/drainedrepo/worker_pid" \
  "$drained_task/drainedrepo/worker_process_start"
# Note: no pane file — drained worker's supervisor has exited

# --sync: drained status propagated to fleet without triggering orphan detector
PATH="$fake_bin:$PATH" SERGEANT_FLEET="$drained_fleet" \
  "$ROOT/bin/sgt-watch" --sync task-drained
[[ "$(cat "$drained_task/drainedrepo/status")" == "drained" ]] || {
  printf 'FAIL sgt-watch drained sync: expected drained status\n' >&2; exit 1; }
[[ ! -f "$drained_task/drainedrepo/diagnostic" ]] || {
  printf 'FAIL sgt-watch drained sync: unexpected diagnostic\n' >&2; exit 1; }

# --list: shows drained count
list_drained_output="$(PATH="$fake_bin:$PATH" SERGEANT_FLEET="$drained_fleet" \
  "$ROOT/bin/sgt-watch" --list)"
[[ "$list_drained_output" == *'1 drained'* ]] || {
  printf 'FAIL sgt-watch --list: expected drained count\n' >&2; exit 1; }

# sgt-watch <task>: all workers drained → exits 0 (not looping forever)
SERGEANT_WATCH_INTERVAL=0.01 PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$drained_fleet" \
  "$ROOT/bin/sgt-watch" task-drained || {
  printf 'FAIL sgt-watch task-drained: expected exit 0 when all drained\n' >&2; exit 1; }

printf 'sgt-watch drained status: ok\n'
