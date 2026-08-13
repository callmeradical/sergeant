#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fleet="$TEST_ROOT/fleet"
state="$fleet/platform-only/app"
worktree="$TEST_ROOT/worktree"
fake_bin="$TEST_ROOT/bin"
mkdir -p "$state" "$worktree" "$fake_bin"
printf 'done\n' > "$state/status"
printf 'result\n' > "$state/result"
printf '%s\n' "$worktree" > "$state/worktree"
printf 'Darwin:no-exact-process-birth\n' > "$state/worker_process_marker_platform"
chmod 600 "$state/worker_process_marker_platform"

cat > "$fake_bin/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MUTATION_LOG"
exit 1
EOF
cat > "$fake_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MUTATION_LOG"
exit 1
EOF
chmod +x "$fake_bin/tmux" "$fake_bin/systemctl"

find "$state" -type f -print0 | sort -z | xargs -0 sha256sum \
  > "$TEST_ROOT/state.before"
set +e
PATH="$fake_bin:$PATH" MUTATION_LOG="$TEST_ROOT/mutations" \
  SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" platform-only > "$TEST_ROOT/cleanup.out" 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]]
grep -Fq 'worker process marker evidence is torn' "$TEST_ROOT/cleanup.out"
[[ ! -e "$TEST_ROOT/mutations" ]]
[[ -d "$state" && -d "$worktree" ]]
find "$state" -type f -print0 | sort -z | xargs -0 sha256sum \
  > "$TEST_ROOT/state.after"
cmp "$TEST_ROOT/state.before" "$TEST_ROOT/state.after"

printf 'sgt-cleanup rejects partial marker tuples before mutation: ok\n'
