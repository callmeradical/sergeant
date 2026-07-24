#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fleet="$TEST_ROOT/fleet"
repo_state="$fleet/task-1/app"
worktree="$TEST_ROOT/worktree"
fake_bin="$TEST_ROOT/bin"
mkdir -p "$repo_state" "$worktree" "$fake_bin"
git -C "$worktree" init -q
git -C "$worktree" config user.name Test
git -C "$worktree" config user.email test@example.invalid
printf 'fixture\n' > "$worktree/README.md"
git -C "$worktree" add README.md
git -C "$worktree" commit -qm fixture
head_sha="$(git -C "$worktree" rev-parse HEAD)"
printf '%s\n' "$worktree" > "$repo_state/worktree"
printf '%%42\n' > "$repo_state/pane"
printf '0|%%42|4242|123456|worker-command\n' > "$repo_state/pane_identity"
printf '%%11\n' > "$fleet/task-1/primary_pane_id"
printf '0|%%11|1111|111111|coordinator-command\n' > "$fleet/task-1/primary_pane_identity"
printf 'implementation-app-task-1\n' > "$repo_state/window_name"
printf 'implementation\n' > "$repo_state/stage"
printf 'in_progress\n' > "$repo_state/status"
printf 'in_progress\n' > "$worktree/.sergeant-status"
cat > "$fleet/task-1/.sergeant-intent.md" <<'EOF'
## Objective

Validate the interactive worker safely.
EOF
cp "$fleet/task-1/.sergeant-intent.md" "$repo_state/.sergeant-intent.md"
cp "$fleet/task-1/.sergeant-intent.md" "$worktree/.sergeant-intent.md"
revision="$(bash -c 'source "$1"; _sgt_intent_revision "$2"' _ \
  "$ROOT_DIR/bin/_sgt-intent.sh" "$fleet/task-1/.sergeant-intent.md")"
printf '%s\n' "$revision" > "$fleet/task-1/intent_revision"
printf '%s\n' "$revision" > "$repo_state/intent_revision"
cat > "$worktree/.sergeant-validation-ready" <<EOF
intent_revision=$revision
head_sha=$head_sha
standards_review=passed
spec_review=passed
readiness_review=passed
EOF

cat > "$fake_bin/no-mistakes" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$fake_bin/no-mistakes"

cat > "$fake_bin/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_LOG"
command_name="$1"
target=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-t" ]]; then
    target="$2"
    shift 2
    continue
  fi
  shift
done
case "$command_name" in
  display-message)
    case "$target" in
      %77)
        pane_state="$(cat "$TMUX_STATE_DIR/77.state" 2>/dev/null || printf 'live\n')"
        case "$pane_state" in
          live) printf '0|%%77|7777|234567|validation-command\n' ;;
          dead) printf '1|%%77|7777|234567|validation-command\n' ;;
          missing) exit 1 ;;
        esac
        ;;
      %11) printf '0|%%11|1111|111111|coordinator-command\n' ;;
      *) printf '0|%%42|4242|123456|worker-command\n' ;;
    esac
    ;;
  split-window)
    printf 'live\n' > "$TMUX_STATE_DIR/77.state"
    printf '%%77\n'
    ;;
  kill-pane)
    [[ "$target" != "%77" ]] || printf 'missing\n' > "$TMUX_STATE_DIR/77.state"
    ;;
esac
EOF
chmod +x "$fake_bin/tmux"
cat > "$fake_bin/ps" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'-axo pid='*) printf '1111\n4242\n7777\n8888\n' ;;
  *'pgid='*) printf '7777\n' ;;
  *'lstart='*)
    pane_state="$(cat "$TMUX_STATE_DIR/77.state" 2>/dev/null || printf 'live\n')"
    [[ "$pane_state" == "live" ]] || exit 1
    printf 'Thu Jul 23 00:00:00 2026\n'
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$fake_bin/ps"
cat > "$fake_bin/pgrep" <<'EOF'
#!/usr/bin/env bash
state="$(cat "$PGREP_STATE" 2>/dev/null || printf 'clear\n')"
case "$*" in
  *'-g 7777'*)
    [[ "$state" == "detached" ]] || exit 1
    printf '8888\n'
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$fake_bin/pgrep"
cat > "$fake_bin/lsof" <<'EOF'
#!/usr/bin/env bash
state="$(cat "$LSOF_STATE" 2>/dev/null || printf 'clear\n')"
[[ "$state" == "held" ]] || exit 0
printf 'p8888\nn%s\n' "$VALIDATION_CWD"
EOF
chmod +x "$fake_bin/lsof"

mkdir -p "$TEST_ROOT/tmux-state"
printf 'clear\n' > "$TEST_ROOT/pgrep.state"
printf 'clear\n' > "$TEST_ROOT/lsof.state"
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" TMUX_STATE_DIR="$TEST_ROOT/tmux-state" \
  PGREP_STATE="$TEST_ROOT/pgrep.state" LSOF_STATE="$TEST_ROOT/lsof.state" \
  VALIDATION_CWD="$TEST_ROOT/unused-validation-worktree" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" "$ROOT_DIR/bin/sgt-validate" task-1 app >/dev/null

[[ "$(cat "$repo_state/validation_pane")" == "%77" ]]
[[ "$(cat "$repo_state/validation_pane_identity")" == '0|%77|7777|234567|validation-command' ]]
[[ "$(cat "$repo_state/stage")" == "validation" ]]
[[ "$(cat "$repo_state/window_name")" == "validation-app-task-1" ]]
[[ "$(cat "$repo_state/validation_process_group")" == "7777" ]]
[[ "$(cat "$repo_state/validation_pane_pid")" == "7777" ]]
grep -Fq 'rename-window -t %42 validation-app-task-1' "$TEST_ROOT/tmux.log"
grep -Fq 'split-window -P -F #{pane_id} -t %42' "$TEST_ROOT/tmux.log"
grep -Fq "$ROOT_DIR/bin/sgt-validation-worker" "$TEST_ROOT/tmux.log"
grep -Fq "$revision" "$TEST_ROOT/tmux.log"
if grep -Fq 'Validate the interactive worker safely' "$TEST_ROOT/tmux.log" || \
  grep -Fq -- '--yes' "$TEST_ROOT/tmux.log"; then
  printf 'validation launch leaked intent or enabled automatic gates\n' >&2
  exit 1
fi

validation_worktree="$(cat "$repo_state/validation_worktree")"
printf 'stale\n' > "$validation_worktree/stale-marker"
printf 'dead\n' > "$TEST_ROOT/tmux-state/77.state"
printf 'exited:0\n' > "$repo_state/validation_status"
before_lines="$(wc -l < "$TEST_ROOT/tmux.log")"
set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" TMUX_STATE_DIR="$TEST_ROOT/tmux-state" \
  PGREP_STATE="$TEST_ROOT/pgrep.state" LSOF_STATE="$TEST_ROOT/lsof.state" \
  VALIDATION_CWD="$validation_worktree" \
  TMUX_PANE=%12 SERGEANT_FLEET="$fleet" "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *'coordinator pane identity'* ]]
[[ -e "$validation_worktree/stale-marker" ]]
[[ "$(cat "$repo_state/validation_status")" == "exited:0" ]]
[[ "$(wc -l < "$TEST_ROOT/tmux.log")" == "$before_lines" ]]

PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" TMUX_STATE_DIR="$TEST_ROOT/tmux-state" \
  PGREP_STATE="$TEST_ROOT/pgrep.state" LSOF_STATE="$TEST_ROOT/lsof.state" \
  VALIDATION_CWD="$validation_worktree" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" "$ROOT_DIR/bin/sgt-validate" task-1 app >/dev/null
[[ "$(cat "$repo_state/validation_pane")" == "%77" ]]
[[ "$(cat "$repo_state/validation_status")" == "launched" ]]
[[ ! -e "$validation_worktree/stale-marker" ]]
[[ "$(wc -l < "$TEST_ROOT/tmux.log")" -gt "$before_lines" ]]

validation_worktree="$(cat "$repo_state/validation_worktree")"
printf 'stale\n' > "$validation_worktree/stale-marker"
printf 'dead\n' > "$TEST_ROOT/tmux-state/77.state"
printf 'exited:1\n' > "$repo_state/validation_status"
printf 'detached\n' > "$TEST_ROOT/pgrep.state"
before_lines="$(wc -l < "$TEST_ROOT/tmux.log")"
set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" TMUX_STATE_DIR="$TEST_ROOT/tmux-state" \
  PGREP_STATE="$TEST_ROOT/pgrep.state" LSOF_STATE="$TEST_ROOT/lsof.state" \
  VALIDATION_CWD="$validation_worktree" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *'unverified detached descendants'* ]]
[[ -e "$validation_worktree/stale-marker" ]]
[[ "$(cat "$repo_state/validation_status")" == "exited:1" ]]
printf 'clear\n' > "$TEST_ROOT/pgrep.state"

PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" TMUX_STATE_DIR="$TEST_ROOT/tmux-state" \
  PGREP_STATE="$TEST_ROOT/pgrep.state" LSOF_STATE="$TEST_ROOT/lsof.state" \
  VALIDATION_CWD="$validation_worktree" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" "$ROOT_DIR/bin/sgt-validate" task-1 app >/dev/null
[[ "$(cat "$repo_state/validation_pane")" == "%77" ]]
[[ "$(cat "$repo_state/validation_status")" == "launched" ]]
[[ ! -e "$validation_worktree/stale-marker" ]]
[[ "$(wc -l < "$TEST_ROOT/tmux.log")" -gt "$before_lines" ]]

printf 'live\n' > "$TEST_ROOT/tmux-state/77.state"
printf 'running\n' > "$repo_state/validation_status"
before_lines="$(wc -l < "$TEST_ROOT/tmux.log")"
set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" TMUX_STATE_DIR="$TEST_ROOT/tmux-state" \
  PGREP_STATE="$TEST_ROOT/pgrep.state" LSOF_STATE="$TEST_ROOT/lsof.state" \
  VALIDATION_CWD="$validation_worktree" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *'Validation pane is already recorded'* ]]
[[ "$(wc -l < "$TEST_ROOT/tmux.log")" -gt "$before_lines" ]]

rm "$repo_state/validation_pane" "$repo_state/validation_pane_identity" \
  "$repo_state/validation_pane_pid" "$repo_state/validation_process_group" \
  "$repo_state/validation_process_start" \
  "$repo_state/validation-intent.md" "$repo_state/validation-release" \
  "$repo_state/validation_status" "$repo_state/validation_worktree" \
  "$repo_state/validation_head" "$worktree/.sergeant-validation-ready"
rm -rf "$validation_worktree"
before_lines="$(wc -l < "$TEST_ROOT/tmux.log")"
set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" TMUX_STATE_DIR="$TEST_ROOT/tmux-state" \
  PGREP_STATE="$TEST_ROOT/pgrep.state" LSOF_STATE="$TEST_ROOT/lsof.state" \
  VALIDATION_CWD="$validation_worktree" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *'validation-ready marker'* ]]
[[ "$(wc -l < "$TEST_ROOT/tmux.log")" == "$before_lines" ]]

cat > "$worktree/.sergeant-validation-ready" <<EOF
intent_revision=$revision
head_sha=$head_sha
standards_review=passed
spec_review=passed
readiness_review=passed
EOF
before_lines="$(wc -l < "$TEST_ROOT/tmux.log")"
set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" TMUX_STATE_DIR="$TEST_ROOT/tmux-state" \
  PGREP_STATE="$TEST_ROOT/pgrep.state" LSOF_STATE="$TEST_ROOT/lsof.state" \
  VALIDATION_CWD="$validation_worktree" \
  TMUX_PANE=%12 SERGEANT_FLEET="$fleet" "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *'coordinator pane identity'* ]]
[[ "$(wc -l < "$TEST_ROOT/tmux.log")" == "$before_lines" ]]

cat > "$worktree/.sergeant-validation-ready" <<EOF
intent_revision=$revision
head_sha=0000000000000000000000000000000000000000
standards_review=passed
spec_review=passed
readiness_review=passed
EOF
before_lines="$(wc -l < "$TEST_ROOT/tmux.log")"
set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" TMUX_STATE_DIR="$TEST_ROOT/tmux-state" \
  PGREP_STATE="$TEST_ROOT/pgrep.state" LSOF_STATE="$TEST_ROOT/lsof.state" \
  VALIDATION_CWD="$validation_worktree" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *'HEAD or review evidence'* ]]
[[ "$(wc -l < "$TEST_ROOT/tmux.log")" == "$before_lines" ]]

cat > "$worktree/.sergeant-validation-ready" <<EOF
intent_revision=$revision
head_sha=$head_sha
standards_review=passed
spec_review=passed
readiness_review=passed
EOF
printf '\nDrift.\n' >> "$worktree/.sergeant-intent.md"
before_lines="$(wc -l < "$TEST_ROOT/tmux.log")"
set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" TMUX_STATE_DIR="$TEST_ROOT/tmux-state" \
  PGREP_STATE="$TEST_ROOT/pgrep.state" LSOF_STATE="$TEST_ROOT/lsof.state" \
  VALIDATION_CWD="$validation_worktree" \
  TMUX_PANE=%11 SERGEANT_FLEET="$fleet" "$ROOT_DIR/bin/sgt-validate" task-1 app 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *'canonical intent revision mismatch'* ]]
[[ "$(wc -l < "$TEST_ROOT/tmux.log")" == "$before_lines" ]]

printf 'sgt-validate split-pane launch: ok\n'
