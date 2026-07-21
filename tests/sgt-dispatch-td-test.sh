#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
YQ_BIN="$(command -v yq)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/config" "$TEST_ROOT/fake-bin" \
  "$TEST_ROOT/fleet" "$TEST_ROOT/repo"
cp "$ROOT_DIR/bin/sgt-dispatch" "$ROOT_DIR/bin/_sgt-lib.sh" "$TEST_ROOT/bin/"

cat > "$TEST_ROOT/config/test.yaml" <<EOF
name: test
repos:
  - name: app
    path: $TEST_ROOT/repo
EOF

cat > "$TEST_ROOT/bin/sgt-td-create" <<'EOF'
#!/usr/bin/env bash
exit 12
EOF
chmod +x "$TEST_ROOT/bin/sgt-td-create"

cat > "$TEST_ROOT/fake-bin/td" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEST_ROOT/fake-bin/td"

cat > "$TEST_ROOT/fake-bin/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_LOG"
exit 0
EOF
chmod +x "$TEST_ROOT/fake-bin/tmux"

git -C "$TEST_ROOT/repo" init -q
git -C "$TEST_ROOT/repo" config user.name Test
git -C "$TEST_ROOT/repo" config user.email test@example.invalid
touch "$TEST_ROOT/repo/README.md"
git -C "$TEST_ROOT/repo" add README.md
git -C "$TEST_ROOT/repo" commit -qm fixture

set +e
output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
  TMUX_LOG="$TEST_ROOT/tmux.log" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" \
  SGT_WIKI_DISABLED=1 \
  "$TEST_ROOT/bin/sgt-dispatch" test "Track dispatch" --repos app 2>&1)"
status=$?
set -e

[[ "$status" -ne 0 ]] || {
  printf 'dispatch succeeded after td task creation failed\n' >&2
  exit 1
}
[[ "$output" == *"td task creation failed"* ]] || {
  printf 'dispatch did not report td task creation failure:\n%s\n' "$output" >&2
  exit 1
}
[[ ! -s "$TEST_ROOT/tmux.log" ]] || {
  printf 'dispatch spawned tmux after td task creation failed\n' >&2
  exit 1
}

printf 'sgt-dispatch td failure gate: ok\n'

mkdir -p "$TEST_ROOT/api"
git -C "$TEST_ROOT/api" init -q
git -C "$TEST_ROOT/api" config user.name Test
git -C "$TEST_ROOT/api" config user.email test@example.invalid
touch "$TEST_ROOT/api/README.md"
git -C "$TEST_ROOT/api" add README.md
git -C "$TEST_ROOT/api" commit -qm fixture

cat > "$TEST_ROOT/config/test.yaml" <<EOF
name: test
repos:
  - name: app
    path: $TEST_ROOT/repo
  - name: api
    path: $TEST_ROOT/api
EOF
cp "$ROOT_DIR/bin/sgt-td-create" "$TEST_ROOT/bin/sgt-td-create"

cat > "$TEST_ROOT/fake-bin/td" <<'EOF'
#!/usr/bin/env bash
work_dir=""
for ((i=1; i<=$#; i++)); do
  if [[ "${!i}" == "--work-dir" ]]; then
    next=$((i + 1))
    work_dir="${!next}"
  fi
done
case "$1" in
  list) printf '[]\n' ;;
  create)
    repo="$(basename "$work_dir")"
    [[ "$repo" == "repo" ]] && repo="app"
    printf '%s %s\n' "$repo" "$work_dir" >> "$TD_CREATE_LOG"
    printf '{"id":"td-%s-123"}\n' "$repo"
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/td"
: > "$TEST_ROOT/tmux.log"

PATH="$TEST_ROOT/fake-bin:$PATH" \
TMUX_LOG="$TEST_ROOT/tmux.log" \
TD_CREATE_LOG="$TEST_ROOT/td-create.log" \
SERGEANT_CONFIG="$TEST_ROOT/config" \
SERGEANT_FLEET="$TEST_ROOT/fleet" \
SGT_WIKI_DISABLED=1 \
  "$TEST_ROOT/bin/sgt-dispatch" test "Create tracked work" --repos app,api >/dev/null

[[ "$(wc -l < "$TEST_ROOT/td-create.log")" -eq 2 ]]
task_dir="$(printf '%s\n' "$TEST_ROOT"/fleet/create-tracked-work-*)"
for repo in app api; do
  task_id="td-$repo-123"
  repo_state="$task_dir/$repo"
  brief="$(cat "$repo_state/worktree")/.sergeant-brief.md"
  [[ "$(cat "$repo_state/td_task")" == "$task_id" ]]
  grep -Fq "**td task:** $task_id" "$brief"
  grep -Fq "td start $task_id --work-dir ." "$brief"
  grep -Fq 'td log "message" --work-dir .' "$brief"
  grep -Fq "td handoff $task_id --work-dir ." "$brief"
  grep -Fq "td review $task_id --work-dir ." "$brief"
done
[[ "$(grep -c '^new-window ' "$TEST_ROOT/tmux.log")" -eq 2 ]]

printf 'sgt-dispatch generated td tracking: ok\n'

cat > "$TEST_ROOT/bin/sgt-td-create" <<'EOF'
#!/usr/bin/env bash
printf '[{"repo":"app","task_id":"td-app-partial"}]\n'
EOF
chmod +x "$TEST_ROOT/bin/sgt-td-create"
: > "$TEST_ROOT/tmux.log"

set +e
output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
  TMUX_LOG="$TEST_ROOT/tmux.log" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" \
  SGT_WIKI_DISABLED=1 \
  "$TEST_ROOT/bin/sgt-dispatch" test "Reject partial tracking" --repos app,api 2>&1)"
status=$?
set -e

[[ "$status" -ne 0 ]] || {
  printf 'dispatch succeeded with a missing repo td task\n' >&2
  exit 1
}
[[ "$output" == *"missing td task for selected repo: api"* ]] || {
  printf 'dispatch did not identify the repo missing a td task:\n%s\n' "$output" >&2
  exit 1
}
[[ ! -s "$TEST_ROOT/tmux.log" ]] || {
  printf 'dispatch spawned tmux with a missing repo td task\n' >&2
  exit 1
}

printf 'sgt-dispatch partial td gate: ok\n'

cat > "$TEST_ROOT/bin/sgt-td-create" <<'EOF'
#!/usr/bin/env bash
printf '{not-json}\n'
EOF
chmod +x "$TEST_ROOT/bin/sgt-td-create"
: > "$TEST_ROOT/tmux.log"

set +e
output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
  TMUX_LOG="$TEST_ROOT/tmux.log" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" \
  SGT_WIKI_DISABLED=1 \
  "$TEST_ROOT/bin/sgt-dispatch" test "Reject invalid tracking" --repos app,api 2>&1)"
status=$?
set -e

[[ "$status" -ne 0 ]] || {
  printf 'dispatch succeeded after td result injection failed\n' >&2
  exit 1
}
[[ "$output" == *"failed to inject td task results"* ]] || {
  printf 'dispatch did not report td result injection failure:\n%s\n' "$output" >&2
  exit 1
}
[[ ! -s "$TEST_ROOT/tmux.log" ]] || {
  printf 'dispatch spawned tmux after td result injection failed\n' >&2
  exit 1
}

printf 'sgt-dispatch td injection gate: ok\n'

cat > "$TEST_ROOT/bin/sgt-td-create" <<'EOF'
#!/usr/bin/env bash
printf 'sgt-td-create must not run for --td dispatch\n' >&2
exit 99
EOF
chmod +x "$TEST_ROOT/bin/sgt-td-create"
cat > "$TEST_ROOT/fake-bin/td" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list) printf '[{"id":"td-existing","title":"Existing tracked work","description":"Keep existing behavior"}]\n' ;;
  context) printf 'existing td lifecycle context\n' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/td"
: > "$TEST_ROOT/tmux.log"

PATH="$TEST_ROOT/fake-bin:$PATH" \
TMUX_LOG="$TEST_ROOT/tmux.log" \
SERGEANT_CONFIG="$TEST_ROOT/config" \
SERGEANT_FLEET="$TEST_ROOT/fleet" \
SGT_WIKI_DISABLED=1 \
  "$TEST_ROOT/bin/sgt-dispatch" test --td td-existing --repos app >/dev/null

task_dir="$(printf '%s\n' "$TEST_ROOT"/fleet/existing-tracked-work-*)"
repo_state="$task_dir/app"
brief="$(cat "$repo_state/worktree")/.sergeant-brief.md"
[[ "$(cat "$task_dir/td_task")" == 'td-existing' ]]
[[ "$(cat "$repo_state/td_task")" == 'td-existing' ]]
grep -Fq '**td task:** td-existing' "$brief"
grep -Fq 'existing td lifecycle context' "$brief"
[[ "$(grep -c '^new-window ' "$TEST_ROOT/tmux.log")" -eq 1 ]]

printf 'sgt-dispatch existing td compatibility: ok\n'

rm "$TEST_ROOT/fake-bin/td"
ln -s "$YQ_BIN" "$TEST_ROOT/fake-bin/yq"
: > "$TEST_ROOT/tmux.log"

set +e
output="$(PATH="$TEST_ROOT/fake-bin:/usr/bin:/bin" \
  TMUX_LOG="$TEST_ROOT/tmux.log" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" \
  SGT_WIKI_DISABLED=1 \
  "$TEST_ROOT/bin/sgt-dispatch" test "Require task tracking" --repos app 2>&1)"
status=$?
set -e

[[ "$status" -ne 0 ]] || {
  printf 'brief-only dispatch succeeded without td\n' >&2
  exit 1
}
[[ "$output" == *"td is required for brief-only dispatch"* ]] || {
  printf 'dispatch did not report missing td requirement:\n%s\n' "$output" >&2
  exit 1
}
[[ ! -s "$TEST_ROOT/tmux.log" ]] || {
  printf 'dispatch spawned tmux without td tracking\n' >&2
  exit 1
}

printf 'sgt-dispatch missing td gate: ok\n'
