#!/usr/bin/env bash
# Tests for drain admission in sgt-dispatch — additional coverage beyond sgt-drain-test.sh
# Focuses on: project field in fleet state, and unrelated-project admit.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

drain_dir="$TEST_ROOT/drains"
mkdir -p "$TEST_ROOT/config" "$TEST_ROOT/fleet" "$TEST_ROOT/fake-bin" \
  "$TEST_ROOT/repo" "$drain_dir"

cat > "$TEST_ROOT/config/test.yaml" <<EOF
name: test
repos:
  - name: app
    path: $TEST_ROOT/repo
EOF

cat > "$TEST_ROOT/config/other.yaml" <<EOF
name: other
repos:
  - name: svc
    path: $TEST_ROOT/repo
EOF

cat > "$TEST_ROOT/fake-bin/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TMUX_LOG:-/dev/null}"
case "$1" in
  has-session) exit 0 ;;
  new-session) exit 0 ;;
  new-window)  printf '%%42\n' ;;
  display-message) printf '0|fake-agent\n' ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/tmux"

cat > "$TEST_ROOT/fake-bin/td" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then printf 'td version v0.51.0\n'; exit 0; fi
if [[ "${1:-}" == "create" && "${2:-}" == "--help" ]]; then
  printf '%s\n' '--description --json --work-dir'; exit 0
fi
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in --work-dir|-w) shift 2 ;; --json) shift ;; *) args+=("$1"); shift ;; esac
done
set -- "${args[@]:-}"
case "${1:-}" in
  list)   printf '[]\n' ;;
  create) printf '{"id":"td-app-1"}\n' ;;
  delete) printf '{"id":"td-app-1","deleted":true}\n' ;;
  *) printf '[]\n' ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/td"

git -C "$TEST_ROOT/repo" init -q
git -C "$TEST_ROOT/repo" config user.name Test
git -C "$TEST_ROOT/repo" config user.email test@example.invalid
touch "$TEST_ROOT/repo/README.md"
git -C "$TEST_ROOT/repo" add README.md
git -C "$TEST_ROOT/repo" commit -qm fixture
git -C "$TEST_ROOT/repo" remote add origin git@github.com:org/test.git

_dispatch() {
  TMUX="fake" TMUX_PANE="%42" \
  PATH="$TEST_ROOT/fake-bin:$ROOT_DIR/bin:$PATH" \
  TMUX_LOG="$TEST_ROOT/tmux.log" \
    SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
    SERGEANT_DRAIN_DIR="$drain_dir" SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-dispatch" "$@"
}

_drain() {
  SERGEANT_DRAIN_DIR="$drain_dir" "$ROOT_DIR/bin/sgt-drain" "$@"
}

_undrain() {
  SERGEANT_DRAIN_DIR="$drain_dir" "$ROOT_DIR/bin/sgt-undrain" "$@"
}

_fleet_count() {
  find "$TEST_ROOT/fleet" -mindepth 2 -name status 2>/dev/null | wc -l | tr -d ' '
}

# ── 1. Dispatch stores project name in fleet state ─────────────────────────────

_dispatch test 'Project field test' --repos app >/dev/null
found=false
for d in "$TEST_ROOT/fleet"/*/; do
  [[ -d "$d/app" ]] || continue
  if [[ -f "$d/app/project" ]]; then
    proj_val="$(cat "$d/app/project")"
    [[ "$proj_val" == "test" ]] && found=true
  fi
done
$found || { echo "project field not written to fleet state"; exit 1; }

# ── 2. Unrelated project is admitted while test project is drained ─────────────

count_before="$(_fleet_count)"
_drain test --reason "scoped drain test" --actor "test"

set +e
output="$(_dispatch test 'Drain blocked dispatch' --repos app 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 ]] || { echo "drained project should be rejected; got 0"; exit 1; }
[[ "$output" == *"drain"* || "$output" == *"rejected"* ]] || \
  { echo "expected drain rejection message; got: $output"; exit 1; }
[[ "$(_fleet_count)" -eq "$count_before" ]] || \
  { echo "fleet count changed despite project drain rejection"; exit 1; }

# Unrelated project must still be admitted
_dispatch other 'Other project dispatch' --repos svc >/dev/null
[[ "$(_fleet_count)" -gt "$count_before" ]] || \
  { echo "unrelated project should not be blocked by test drain"; exit 1; }

_undrain test

# ── 3. Undrain restores admission ─────────────────────────────────────────────

count_before="$(_fleet_count)"
_dispatch test 'Post-drain dispatch' --repos app >/dev/null
[[ "$(_fleet_count)" -gt "$count_before" ]] || \
  { echo "dispatch should succeed after drain cleared"; exit 1; }

printf 'sgt-dispatch drain admission: ok\n'
