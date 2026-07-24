#!/usr/bin/env bash
# sgt-dispatch-identity-test.sh — tests for the identity key feature
#
# Validates that:
#   1. global default_identity is loaded from config.yaml into SGT_DEFAULT_IDENTITY
#   2. dry-run shows resolved identity (project-level, repo-level, global)
#   3. resolution order: repo.identity → project.identity → default_identity → no-op
#   4. failed gh auth switch → fleet status=failed, diagnostic recorded, dispatch aborted

set -euo pipefail
export TMUX=fixture TMUX_PANE=%11

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/config" "$TEST_ROOT/fleet" "$TEST_ROOT/fake-bin" "$TEST_ROOT/repo"

# ── Fake tmux ─────────────────────────────────────────────────────────────────
cat > "$TEST_ROOT/fake-bin/tmux" << 'EOF'
#!/usr/bin/env bash
case "$1" in
  has-session) exit 0 ;;
  display-message)
    for repo_state in "$SERGEANT_FLEET"/*/*; do
      [[ -d "$repo_state" ]] || continue
      nonce="$(cat "$repo_state/notification_target" 2>/dev/null || true)"
      notification_id="$(cat "$repo_state/notification_id" 2>/dev/null || true)"
      [[ "$nonce" =~ ^[a-f0-9]{32}$ && -n "$notification_id" ]] || continue
      target_dir="$repo_state/notifications/$notification_id/targets/$nonce"
      token="$notification_id|$nonce"
      printf '%s\n' "$token" > "$target_dir/accepted"
      printf '%s\n' "$token" > "$target_dir/delivered"
    done
    if [[ "$*" == *'-t %11'* ]]; then
      printf '0|%%11|1111|111111|coordinator-command\n'
    else
      printf '0|%%42|4242|123456|fixture-worker-command\n'
    fi
    ;;
  new-session) ;;
  new-window)
    for repo_state in "$SERGEANT_FLEET"/*/*; do
      [[ -d "$repo_state" ]] || continue
      notification_id="$(cat "$repo_state/notification_id")"
      worktree="$(cat "$repo_state/worktree")"
      printf '%s|0|%%42|4242|123456|fixture-worker-command\n' "$notification_id" \
        > "$worktree/.sergeant-notification-ack"
      printf '%s|0|%%42|4242|123456|fixture-worker-command\n' "$notification_id" \
        > "$worktree/.sergeant-notification-accept"
    done
    printf '%%42\n'
    ;;
  kill-pane) ;;
  *) printf 'TMUX_FAKE_UNEXPECTED: %s\n' "$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/tmux"

# ── Fake td (passes _require_marcus_td gate) ───────────────────────────────────
cat > "$TEST_ROOT/fake-bin/td" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "--version" ]] && { printf 'td version v0.1.0\n'; exit 0; }
[[ "${1:-}" == "create" && "${2:-}" == "--help" ]] && { printf '%s\n' '--description --json --work-dir'; exit 0; }
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in --work-dir|-w) shift 2 ;; --json) shift ;; *) args+=("$1"); shift ;; esac
done
set -- "${args[@]:-}"
case "${1:-}" in
  list)   printf '[]\n' ;;
  create) printf '{"id":"td-app-1"}\n' ;;
  delete) printf '{"id":"td-app-1","deleted":true}\n' ;;
  *)      exit 0 ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/td"

# ── Fake sgt-td-create (returns well-formed JSON so dispatch proceeds) ─────────
cat > "$TEST_ROOT/fake-bin/sgt-td-create" << 'EOF'
#!/usr/bin/env bash
# Minimal fake: skip all real work, emit the JSON that dispatch expects.
shift; shift  # skip project and title
REPOS_ARG=""; JSON_OUT=false
while [[ $# -gt 0 ]]; do
  case "$1" in --repos) REPOS_ARG="$2"; shift 2 ;; --json) JSON_OUT=true; shift ;; *) shift ;; esac
done
$JSON_OUT || exit 0
out="["; first=true
IFS=',' read -ra repos <<< "$REPOS_ARG"
for repo in "${repos[@]}"; do
  $first || out+=","
  first=false
  out+="{\"repo\":\"$repo\",\"task_id\":\"td-${repo}-fixture\",\"title\":\"test\",\"work_dir\":\"/tmp\"}"
done
out+="]"
printf '%s\n' "$out"
EOF
chmod +x "$TEST_ROOT/fake-bin/sgt-td-create"

# ── Fake opencode ─────────────────────────────────────────────────────────────
cat > "$TEST_ROOT/fake-bin/opencode" << 'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEST_ROOT/fake-bin/opencode"

export PATH="$TEST_ROOT/fake-bin:$PATH"
export SERGEANT_CONFIG="$TEST_ROOT/config"
export SERGEANT_FLEET="$TEST_ROOT/fleet"
export SERGEANT_AGENT=opencode

# ── Set up a fake git repo ────────────────────────────────────────────────────
git -C "$TEST_ROOT/repo" init -q
git -C "$TEST_ROOT/repo" config user.email "test@test.com"
git -C "$TEST_ROOT/repo" config user.name "Test"
touch "$TEST_ROOT/repo/README.md"
git -C "$TEST_ROOT/repo" add .
git -C "$TEST_ROOT/repo" commit -q -m "init"
git -C "$TEST_ROOT/repo" remote add origin git@github.com:org/test.git

# ── Helper ────────────────────────────────────────────────────────────────────
_fail() { echo "FAIL: $1"; exit 1; }
_pass() { echo "ok: $1"; }

# ── Test 1: global default_identity is read from config.yaml ─────────────────
cat > "$TEST_ROOT/config/config.yaml" << YAML
dev_root: $TEST_ROOT
default_identity: global-user
YAML

SGT_LIB_LOADED=""
source "$ROOT_DIR/bin/_sgt-lib.sh"
[[ "$SGT_DEFAULT_IDENTITY" == "global-user" ]] || \
  _fail "SGT_DEFAULT_IDENTITY not loaded from config.yaml (got: '${SGT_DEFAULT_IDENTITY:-}')"
_pass "global default_identity loaded from config.yaml"

# ── Test 2: dry-run shows project-level identity ──────────────────────────────
cat > "$TEST_ROOT/config/id-proj.yaml" << YAML
name: id-proj
identity: proj-user
repos:
  - name: app
    path: $TEST_ROOT/repo
YAML
out="$("$ROOT_DIR/bin/sgt-dispatch" id-proj "test brief" --repos app --dry-run 2>&1 || true)"
echo "$out" | grep -q "identity: proj-user" || \
  _fail "dry-run did not show project identity. Output: $out"
_pass "dry-run shows project-level identity"

# ── Test 3: repo-level identity overrides project-level ───────────────────────
cat > "$TEST_ROOT/config/id-proj2.yaml" << YAML
name: id-proj2
identity: proj-user
repos:
  - name: app
    path: $TEST_ROOT/repo
    identity: repo-user
YAML
out="$("$ROOT_DIR/bin/sgt-dispatch" id-proj2 "test brief" --repos app --dry-run 2>&1 || true)"
echo "$out" | grep -q "identity: repo-user" || \
  _fail "repo-level identity did not override project-level. Output: $out"
_pass "repo-level identity overrides project-level"

# ── Test 4: global default_identity shows in dry-run (no project/repo identity) ─
cat > "$TEST_ROOT/config/global-id.yaml" << YAML
name: global-id
repos:
  - name: app
    path: $TEST_ROOT/repo
YAML
out="$("$ROOT_DIR/bin/sgt-dispatch" global-id "test brief" --repos app --dry-run 2>&1 || true)"
echo "$out" | grep -q "identity: global-user" || \
  _fail "global identity not shown in dry-run. Output: $out"
_pass "global default_identity shown in dry-run when no project/repo identity"

# ── Test 5: no identity configured → no identity line in dry-run ──────────────
cat > "$TEST_ROOT/config/config.yaml" << YAML
dev_root: $TEST_ROOT
YAML
cat > "$TEST_ROOT/config/no-id.yaml" << YAML
name: no-id
repos:
  - name: app
    path: $TEST_ROOT/repo
YAML
SGT_LIB_LOADED=""
source "$ROOT_DIR/bin/_sgt-lib.sh"
[[ -z "${SGT_DEFAULT_IDENTITY:-}" ]] || \
  _fail "SGT_DEFAULT_IDENTITY should be empty when not in config (got: '$SGT_DEFAULT_IDENTITY')"
out="$("$ROOT_DIR/bin/sgt-dispatch" no-id "test brief" --repos app --dry-run 2>&1 || true)"
echo "$out" | grep -q "identity:" && \
  _fail "identity should not appear when none configured. Output: $out" || true
_pass "no identity shown when not configured (no regression)"

# ── Test 6: failed gh auth switch → failed status in fleet, dispatch aborted ──
cat > "$TEST_ROOT/fake-bin/gh" << 'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "auth" && "${2:-}" == "switch" ]]; then
  printf 'error: user not found: bad-user\n' >&2; exit 1; fi
exit 0
EOF
chmod +x "$TEST_ROOT/fake-bin/gh"

cat > "$TEST_ROOT/config/config.yaml" << YAML
dev_root: $TEST_ROOT
YAML
cat > "$TEST_ROOT/config/fail-id.yaml" << YAML
name: fail-id
identity: bad-user
repos:
  - name: app
    path: $TEST_ROOT/repo
YAML
SGT_LIB_LOADED=""
source "$ROOT_DIR/bin/_sgt-lib.sh"
rm -rf "$TEST_ROOT/fleet" && mkdir -p "$TEST_ROOT/fleet"

out="$("$ROOT_DIR/bin/sgt-dispatch" fail-id "test brief" --repos app 2>&1 || true)"
echo "$out" | grep -qi "gh auth switch" || \
  _fail "failed auth switch should mention gh auth switch in error output. Got: $out"

status_file="$(find "$TEST_ROOT/fleet" -name "status" -path "*/app/status" 2>/dev/null | head -1)"
[[ -n "$status_file" ]] || _fail "no status file created on auth failure"
status_content="$(cat "$status_file")"
echo "$status_content" | grep -q "failed" || \
  _fail "status should contain 'failed' on auth failure, got: '$status_content'"
_pass "failed gh auth switch writes failed status to fleet state"

diag_file="$(find "$TEST_ROOT/fleet" -name "diagnostic" -path "*/app/diagnostic" 2>/dev/null | head -1)"
[[ -n "$diag_file" ]] || _fail "no diagnostic file created on auth failure"
diag_content="$(cat "$diag_file")"
echo "$diag_content" | grep -q "bad-user" || \
  _fail "diagnostic should mention bad-user, got: '$diag_content'"
_pass "failed gh auth switch writes diagnostic with username to fleet state"

echo ""
echo "All identity tests passed."
