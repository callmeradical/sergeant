#!/usr/bin/env bash
# GH #201 regression at the public command seam.  The installed command is a
# two-hop symlink into a complete Sergeant distribution; collaborators at the
# process boundary are deterministic fixtures, while sgt-dispatch, its helpers,
# template renderer, git worktree operations, and durable fleet writes are real.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
HOST_PATH="$PATH"

DIST="$TEST_ROOT/distribution"
PREFIX="$TEST_ROOT/prefix"
HOP="$TEST_ROOT/hop"
FAKE_BIN="$TEST_ROOT/fake-bin"
CONFIG="$TEST_ROOT/config"
FLEET="$TEST_ROOT/fleet"
REPO="$TEST_ROOT/app"
API_REPO="$TEST_ROOT/api"
mkdir -p "$DIST" "$PREFIX/bin" "$HOP" "$FAKE_BIN" "$CONFIG" "$FLEET" "$REPO" "$API_REPO"
chmod 700 "$FLEET"
cp -R "$ROOT_DIR/bin" "$ROOT_DIR/templates" "$DIST/"

ln -s "$DIST/bin/sgt-dispatch" "$HOP/sgt-dispatch"
ln -s "$HOP/sgt-dispatch" "$PREFIX/bin/sgt-dispatch"
for command_path in "$DIST/bin"/sgt-*; do
  command_name="$(basename "$command_path")"
  [[ "$command_name" == sgt-dispatch ]] && continue
  ln -s "$command_path" "$PREFIX/bin/$command_name"
done

cat > "$CONFIG/test.yaml" <<EOF
name: test
repos:
  - name: app
    path: $REPO
  - name: api
    path: $API_REPO
EOF

cat > "$FAKE_BIN/opencode" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$FAKE_BIN/td" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${TD_LOG:?}"
if [[ "${1:-}" == --version ]]; then
  printf 'td version v0.51.2\n'
  exit 0
fi
if [[ "${1:-}" == create && "${2:-}" == --help ]]; then
  printf '%s\n' 'Usage: td create TITLE --description TEXT --priority P1 --json --work-dir DIR'
  exit 0
fi
args=()
work_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-dir|-w) work_dir="$2"; shift 2 ;;
    --json|--force) shift ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"
case "${1:-}" in
  list) printf '[]\n' ;;
  create) printf '{"id":"td-installed-%s"}\n' "$(basename "$work_dir")" ;;
  delete)
    if [[ "${2:-}" == "${TD_DELETE_FAIL_ID:-}" ]]; then
      printf 'forced delete failure for %s\n' "$2" >&2
      exit 19
    fi
    printf '{"id":"%s","deleted":true}\n' "${2:-}"
    ;;
  *) exit 1 ;;
esac
EOF

cat > "$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  has-session|new-session|list-sessions|list-panes|kill-pane) exit 0 ;;
  display-message)
    for repo_state in "$SERGEANT_FLEET"/*/*; do
      [[ -d "$repo_state" && -f "$repo_state/notification_id" ]] || continue
      nonce="$(cat "$repo_state/notification_target" 2>/dev/null || true)"
      notification_id="$(cat "$repo_state/notification_id" 2>/dev/null || true)"
      [[ "$nonce" =~ ^[a-f0-9]{32}$ && -n "$notification_id" ]] || continue
      target_dir="$repo_state/notifications/$notification_id/targets/$nonce"
      token="$notification_id|$nonce"
      printf '%s\n' "$token" > "$target_dir/accepted"
      printf '%s\n' "$token" > "$target_dir/delivered"
    done
    if [[ "$*" == *'#{session_name}'* ]]; then
      printf 'sgt:0.0\n'
    elif [[ "$*" == *'-t %11'* ]]; then
      printf '0|%%11|1111|111111|coordinator-command\n'
    else
      printf '0|%%42|4242|123456|fixture-worker-command\n'
    fi
    ;;
  new-window)
    for repo_state in "$SERGEANT_FLEET"/*/*; do
      [[ -d "$repo_state" && -f "$repo_state/notification_id" && -f "$repo_state/worktree" ]] || continue
      notification_id="$(cat "$repo_state/notification_id")"
      worktree="$(cat "$repo_state/worktree")"
      printf '%s|0|%%42|4242|123456|fixture-worker-command\n' "$notification_id" \
        > "$worktree/.sergeant-notification-ack"
      printf '%s|0|%%42|4242|123456|fixture-worker-command\n' "$notification_id" \
        > "$worktree/.sergeant-notification-accept"
      printf '0|%%42|4242|123456|fixture-worker-command\n' \
        > "$repo_state/notification_delivered_pane_identity"
      printf '%s\n' "$notification_id" > "$repo_state/notification_delivered"
    done
    printf '%%42\n'
    ;;
  send-keys|set-option|kill-window) exit 0 ;;
esac
EOF

REAL_DD="$(command -v dd)"
cat > "$FAKE_BIN/dd" <<EOF
#!/usr/bin/env bash
if [[ " \$* " == *' bs=32 '* ]]; then
  exec "$REAL_DD" if=/dev/zero bs=32 count=1
fi
exec "$REAL_DD" "\$@"
EOF

REAL_DATE="$(command -v date)"
cat > "$FAKE_BIN/date" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == +%s && -n "\${REMOVE_TEMPLATE_ON_REPO_STATE:-}" ]]; then
  rm -f "\$REMOVE_TEMPLATE_ON_REPO_STATE"
fi
exec "$REAL_DATE" "\$@"
EOF
chmod +x "$FAKE_BIN"/*

git -C "$REPO" init -q
git -C "$REPO" config user.name Test
git -C "$REPO" config user.email test@example.invalid
printf 'fixture\n' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -qm fixture
git -C "$REPO" remote add origin git@github.com:org/test.git
git -C "$API_REPO" init -q
git -C "$API_REPO" config user.name Test
git -C "$API_REPO" config user.email test@example.invalid
printf 'fixture\n' > "$API_REPO/README.md"
git -C "$API_REPO" add README.md
git -C "$API_REPO" commit -qm fixture
git -C "$API_REPO" remote add origin git@github.com:org/api.git

run_dispatch() {
  local brief="$1"
  shift
  TMUX=fixture TMUX_PANE=%11 PATH="$FAKE_BIN:$PREFIX/bin:$HOST_PATH" \
    TD_LOG="$TEST_ROOT/td.log" SERGEANT_CONFIG="$CONFIG" SERGEANT_FLEET="$FLEET" \
    SERGEANT_DRAIN_DIR="$TEST_ROOT/drain" SGT_WIKI_DISABLED=1 \
    "$PREFIX/bin/sgt-dispatch" test "$brief" --repos app "$@"
}

# A complete dispatch reaches template rendering and worker launch through the
# installed two-hop symlink.  This is intentionally stronger than --help or a
# direct call to a resolver helper.
run_dispatch 'Installed dispatch success' >/dev/null
success_state="$FLEET/installed-dispatch-succe-000000/app"
[[ "$(cat "$success_state/status")" == in_progress ]]
success_worktree="$(cat "$success_state/worktree")"
grep -Fq 'Installed dispatch success' "$success_worktree/.sergeant-brief.md"
git -C "$REPO" worktree remove --force "$success_worktree"
git -C "$REPO" branch -D feat/installed-dispatch-success >/dev/null
rm -rf "$FLEET/installed-dispatch-succe-000000"

# A template that disappears after preflight but before rendering fails after
# worktree/fleet creation.  The command must roll back everything it created,
# including its generated td task, without touching unrelated fleet evidence.
printf 'preexisting\n' > "$FLEET/operator-sentinel"
cp "$ROOT_DIR/templates/worker-brief.md" "$DIST/templates/worker-brief.md"
set +e
late_output="$(REMOVE_TEMPLATE_ON_REPO_STATE="$DIST/templates/worker-brief.md" \
  run_dispatch 'Late template failure' 2>&1)"
late_status=$?
set -e
[[ "$late_status" -ne 0 && "$late_output" == *'worker brief template'* ]]
[[ ! -e "$FLEET/late-template-failure-000000" ]]
[[ ! -e "$(dirname "$REPO")/app-sgt-late-template-failure-000000" ]]
[[ ! -e "$REPO/.git/refs/heads/feat/late-template-failure" ]]
[[ "$(cat "$FLEET/operator-sentinel")" == preexisting ]]
grep -Fq 'delete td-installed-app' "$TEST_ROOT/td.log"

# Reusing a preexisting worktree must never make rollback delete that worktree
# or its user-owned files.  Only files introduced by this failed invocation may
# be removed.
cp "$ROOT_DIR/templates/worker-brief.md" "$DIST/templates/worker-brief.md"
preexisting_worktree="$(dirname "$REPO")/app-sgt-preserve-existing-state-000000"
git -C "$REPO" worktree add -q -b feat/preserve-existing-state "$preexisting_worktree"
printf 'user-owned\n' > "$preexisting_worktree/user-sentinel"
printf 'original intent bytes without newline' > "$preexisting_worktree/.sergeant-intent.md"
printf 'original brief bytes\n' > "$preexisting_worktree/.sergeant-brief.md"
chmod 640 "$preexisting_worktree/.sergeant-intent.md"
cp -a "$preexisting_worktree/.sergeant-intent.md" "$TEST_ROOT/original-intent"
cp -a "$preexisting_worktree/.sergeant-brief.md" "$TEST_ROOT/original-brief"
set +e
preserve_output="$(REMOVE_TEMPLATE_ON_REPO_STATE="$DIST/templates/worker-brief.md" \
  run_dispatch 'Preserve existing state' 2>&1)"
preserve_status=$?
set -e
[[ "$preserve_status" -ne 0 && "$preserve_output" == *'worker brief template'* ]]
[[ -d "$preexisting_worktree" ]]
[[ "$(cat "$preexisting_worktree/user-sentinel")" == user-owned ]]
cmp "$TEST_ROOT/original-intent" "$preexisting_worktree/.sergeant-intent.md"
cmp "$TEST_ROOT/original-brief" "$preexisting_worktree/.sergeant-brief.md"
[[ "$(stat -c %a "$preexisting_worktree/.sergeant-intent.md")" == 640 ]]
[[ ! -e "$FLEET/preserve-existing-state-000000" ]]

# A signal at the first instruction after git reports worktree success must find
# a durable ownership journal and remove that exact worktree and new branch.
cp "$ROOT_DIR/templates/worker-brief.md" "$DIST/templates/worker-brief.md"
set +e
interrupt_output="$(SGT_TEST_HOOKS=1 \
  SGT_DISPATCH_FAIL_POINT=dispatch-git-worktree-acquired \
  run_dispatch 'Interrupt after worktree' 2>&1)"
interrupt_status=$?
set -e
[[ "$interrupt_status" -ne 0 ]]
[[ ! -e "$FLEET/interrupt-after-worktree-000000" ]]
[[ ! -e "$(dirname "$REPO")/app-sgt-interrupt-after-worktree-000000" ]]
[[ ! -e "$REPO/.git/refs/heads/feat/interrupt-after-worktree" ]]

# The td creator's post-success interruption boundary must still durably expose
# the just-created ID to rollback before dispatch can mutate fleet/worktrees.
: > "$TEST_ROOT/td.log"
set +e
td_interrupt_output="$(SGT_TEST_HOOKS=1 \
  SGT_TD_CREATE_FAIL_POINT=after-create-success \
  run_dispatch 'Interrupt after td create' 2>&1)"
td_interrupt_status=$?
set -e
[[ "$td_interrupt_status" -ne 0 ]]
grep -Fq 'create Interrupt after td create' "$TEST_ROOT/td.log"
grep -Fq 'delete td-installed-app' "$TEST_ROOT/td.log"
[[ ! -e "$FLEET/interrupt-after-td-create-000000" ]]

# Rollback is best-effort across all owned resources: failure deleting the
# first generated td task must not skip the second deletion or fleet cleanup.
: > "$TEST_ROOT/td.log"
cp "$ROOT_DIR/templates/worker-brief.md" "$DIST/templates/worker-brief.md"
set +e
aggregate_output="$(TD_DELETE_FAIL_ID=td-installed-app \
  REMOVE_TEMPLATE_ON_REPO_STATE="$DIST/templates/worker-brief.md" \
  TMUX=fixture TMUX_PANE=%11 PATH="$FAKE_BIN:$PREFIX/bin:$HOST_PATH" \
  TD_LOG="$TEST_ROOT/td.log" SERGEANT_CONFIG="$CONFIG" SERGEANT_FLEET="$FLEET" \
  SERGEANT_DRAIN_DIR="$TEST_ROOT/drain" SGT_WIKI_DISABLED=1 \
  "$PREFIX/bin/sgt-dispatch" test 'Aggregate rollback' --repos app,api 2>&1)"
aggregate_status=$?
set -e
[[ "$aggregate_status" -ne 0 && "$aggregate_output" == *'td-installed-app'* ]]
grep -Fq 'delete td-installed-app' "$TEST_ROOT/td.log"
grep -Fq 'delete td-installed-api' "$TEST_ROOT/td.log"
[[ ! -e "$FLEET/aggregate-rollback-000000" ]]
[[ ! -e "$(dirname "$REPO")/app-sgt-aggregate-rollback-000000" ]]

# Bundled resources that are broken or escape the canonical distribution root
# are rejected during bootstrap, before td, fleet, worktree, or tmux mutation.
git -C "$REPO" worktree remove --force "$preexisting_worktree"
git -C "$REPO" branch -D feat/preserve-existing-state >/dev/null
rm -f "$FLEET/operator-sentinel"
: > "$TEST_ROOT/td.log"
mkdir -p "$TEST_ROOT/outside"
cp "$ROOT_DIR/templates/worker-brief.md" "$TEST_ROOT/outside/worker-brief.md"
mkdir -p "$DIST/templates"
ln -s "$TEST_ROOT/outside/worker-brief.md" "$DIST/templates/worker-brief.md"
set +e
escape_output="$(run_dispatch 'Escaped template' 2>&1)"
escape_status=$?
set -e
[[ "$escape_status" -ne 0 && "$escape_output" == *'outside canonical Sergeant distribution'* ]]
[[ -z "$(find "$FLEET" -mindepth 1 -print -quit)" ]]
[[ ! -s "$TEST_ROOT/td.log" ]]

rm "$DIST/templates/worker-brief.md"
ln -s missing-template.md "$DIST/templates/worker-brief.md"
set +e
broken_output="$(run_dispatch 'Broken template' 2>&1)"
broken_status=$?
set -e
[[ "$broken_status" -ne 0 && "$broken_output" == *'broken bundled resource'* ]]
[[ -z "$(find "$FLEET" -mindepth 1 -print -quit)" ]]
[[ ! -s "$TEST_ROOT/td.log" ]]

rm "$DIST/templates/worker-brief.md"
ln -s cycle-b.md "$DIST/templates/worker-brief.md"
ln -s worker-brief.md "$DIST/templates/cycle-b.md"
set +e
cycle_output="$(run_dispatch 'Cyclic template' 2>&1)"
cycle_status=$?
set -e
[[ "$cycle_status" -ne 0 && "$cycle_output" == *'cyclic bundled resource'* ]]
[[ -z "$(find "$FLEET" -mindepth 1 -print -quit)" ]]
[[ ! -s "$TEST_ROOT/td.log" ]]

# A real executable named sgt-dispatch outside the distribution's canonical
# bin/ layout is invalid even when every installed symlink hop itself resolves.
rm "$DIST/templates/worker-brief.md" "$DIST/templates/cycle-b.md"
cp "$ROOT_DIR/templates/worker-brief.md" "$DIST/templates/worker-brief.md"
mkdir -p "$TEST_ROOT/invalid-layout"
cp "$ROOT_DIR/bin/sgt-dispatch" "$TEST_ROOT/invalid-layout/sgt-dispatch"
ln -sfn "$TEST_ROOT/invalid-layout/sgt-dispatch" "$HOP/sgt-dispatch"
set +e
invalid_output="$(run_dispatch 'Invalid distribution layout' 2>&1)"
invalid_status=$?
set -e
[[ "$invalid_status" -ne 0 && \
  "$invalid_output" == *'invalid canonical Sergeant distribution'* ]]
[[ -z "$(find "$FLEET" -mindepth 1 -print -quit)" ]]
[[ ! -s "$TEST_ROOT/td.log" ]]

printf 'sgt-dispatch installed-symlink transaction: ok\n'
