#!/usr/bin/env bash
# GH #204 regression at the public installed-command seam.  Dispatch and the
# review router are selected through installed symlinks; only process-boundary
# collaborators are fixtures.

set -euo pipefail
export TMUX=fixture TMUX_PANE=%11

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
HOST_PATH="/usr/local/bin:/usr/bin:/bin"
DIST="$TEST_ROOT/distribution"
PREFIX="$TEST_ROOT/prefix"
FAKE_BIN="$TEST_ROOT/fake-bin"
CONFIG="$TEST_ROOT/config"
FLEET="$TEST_ROOT/fleet"
REPO="$TEST_ROOT/app"
mkdir -p "$DIST" "$PREFIX/bin" "$FAKE_BIN" "$CONFIG" "$FLEET" "$REPO"
chmod 700 "$FLEET"
cp -R "$ROOT_DIR/bin" "$ROOT_DIR/templates" "$DIST/"
ln -s "$DIST/bin/sgt-dispatch" "$PREFIX/bin/sgt-dispatch"

cat > "$CONFIG/test.yaml" <<EOF
name: test
repos:
  - name: app
    path: $REPO
EOF

cat > "$FAKE_BIN/opencode" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$FAKE_BIN/td" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${TD_LOG:?}"
if [[ "${1:-}" == --version ]]; then printf 'td version v0.51.2\n'; exit 0; fi
if [[ "${1:-}" == create && "${2:-}" == --help ]]; then
  printf '%s\n' 'Usage: td create TITLE --description TEXT --priority P1 --json --work-dir DIR'
  exit 0
fi
args=(); work_dir=""
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
  create) printf '{"id":"td-router-%s"}\n' "$(basename "$work_dir")" ;;
  delete) printf '{"id":"%s","deleted":true}\n' "${2:-}" ;;
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
chmod +x "$FAKE_BIN"/*

git -C "$REPO" init -q
git -C "$REPO" config user.name Test
git -C "$REPO" config user.email test@example.invalid
printf 'fixture\n' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -qm fixture
git -C "$REPO" remote add origin git@github.com:org/test.git

run_dispatch() {
  local brief="$1"
  TMUX=fixture TMUX_PANE=%11 PATH="$FAKE_BIN:$PREFIX/bin:$HOST_PATH" \
    TD_LOG="$TEST_ROOT/td.log" SERGEANT_CONFIG="$CONFIG" SERGEANT_FLEET="$FLEET" \
    SERGEANT_DRAIN_DIR="$TEST_ROOT/drain" SGT_WIKI_DISABLED=1 \
    "$PREFIX/bin/sgt-dispatch" test "$brief" --repos app
}

assert_rejected_without_mutation() {
  local expected="$1" brief="$2" output status
  : > "$TEST_ROOT/td.log"
  set +e
  output="$(run_dispatch "$brief" 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 && "$output" == *"$expected"* ]] || {
    printf 'dispatch was not rejected (%s): status=%s output=%s\n' \
      "$expected" "$status" "$output" >&2
    exit 1
  }
  [[ ! -e "$FLEET/${brief// /-}" ]]
  [[ "$(find "$FLEET" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" == 0 ]]
  [[ "$(find "$TEST_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'app-sgt-*' | wc -l | tr -d ' ')" == 0 ]]
  ! grep -q '^create ' "$TEST_ROOT/td.log"
}

# The installed router exposes a closed, versioned, machine-readable contract.
ln -s "$DIST/bin/sgt-review-findings" "$PREFIX/bin/sgt-review-findings"
contract="$(PATH="$PREFIX/bin:$HOST_PATH" sgt-review-findings --capabilities)"
python3 - "$contract" <<'PY'
import json
import sys

doc = json.loads(sys.argv[1])
assert set(doc) == {
    "schema", "contract_revision", "artifact_schema_revision", "axes",
    "canonical_severities", "severity_aliases", "argv",
}, doc
assert doc["schema"] == "sergeant.review-router-capabilities/v1"
assert doc["contract_revision"] == "sergeant.review-router-contract/v1"
assert doc["artifact_schema_revision"] == "sergeant.review-findings/v1"
assert doc["axes"] == ["standards", "spec", "readiness", "accessibility"]
assert doc["canonical_severities"] == ["error", "warning", "info"]
assert doc["severity_aliases"]["informational"] == "info"
for option in ("--input", "--axis", "--source", "--retry",
               "--require-contract-revision", "--require-executable-identity"):
    assert option in doc["argv"], (option, doc)
PY

# No PATH-selected installed router is an installation error, even though the
# dispatch distribution itself happens to contain a sibling router.
rm "$PREFIX/bin/sgt-review-findings"
assert_rejected_without_mutation 'review-router preflight: sgt-review-findings is not installed on PATH' 'Absent router'

# An older/mixed router cannot impersonate compatibility with prose in --help.
cat > "$TEST_ROOT/old-router" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --capabilities ]]; then
  printf '%s\n' '{"schema":"sergeant.review-router-capabilities/v1","contract_revision":"sergeant.review-router-contract/v0","artifact_schema_revision":"sergeant.review-findings/v0","axes":["standards"],"canonical_severities":["error","warning","info"],"severity_aliases":{},"argv":["--input","--axis"]}'
  exit 0
fi
printf 'Usage: sgt-review-findings standards spec readiness accessibility error warning info informational\n'
exit 1
EOF
chmod +x "$TEST_ROOT/old-router"
ln -s "$TEST_ROOT/old-router" "$PREFIX/bin/sgt-review-findings"
assert_rejected_without_mutation 'review-router contract mismatch' 'Mixed router'
rm "$PREFIX/bin/sgt-review-findings"

# A router that changes its executable after answering the capability probe is
# rejected before dispatch creates td, worktree, or fleet state.
cat > "$TEST_ROOT/tampering-router" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"schema":"sergeant.review-router-capabilities/v1","contract_revision":"sergeant.review-router-contract/v1","artifact_schema_revision":"sergeant.review-findings/v1","axes":["standards","spec","readiness","accessibility"],"canonical_severities":["error","warning","info"],"severity_aliases":{"error":"error","blocker":"error","critical":"error","high":"error","warning":"warning","major":"warning","medium":"warning","info":"info","minor":"info","low":"info","informational":"info"},"argv":["--capabilities","--input","--axis","--source","--branch","--head-sha","--parent-task","--task-id","--worktree","--retry","--require-contract-revision","--require-executable-identity"]}'
printf '#!/usr/bin/env bash\nexit 0\n' > "$0.changed"
chmod +x "$0.changed"
mv "$0.changed" "$0"
EOF
chmod +x "$TEST_ROOT/tampering-router"
ln -s "$TEST_ROOT/tampering-router" "$PREFIX/bin/sgt-review-findings"
assert_rejected_without_mutation 'review-router executable changed during preflight' 'Tampered router'
rm "$PREFIX/bin/sgt-review-findings"

# Matching installed revisions dispatch successfully, persist the verified
# canonical executable identity and contract revision, and pin the exact router
# plus runtime guards into the worker brief.
ln -s "$DIST/bin/sgt-review-findings" "$PREFIX/bin/router-alias"
ln -s "$PREFIX/bin/router-alias" "$PREFIX/bin/sgt-review-findings"
run_dispatch 'Matching router' >/dev/null
task_dir="$FLEET/matching-router-000000"
repo_state="$task_dir/app"
worktree="$(cat "$repo_state/worktree")"
canonical_router="$DIST/bin/sgt-review-findings"
[[ "$(cat "$task_dir/review_router_executable")" == "$canonical_router" ]]
[[ "$(cat "$task_dir/review_router_contract_revision")" == 'sergeant.review-router-contract/v1' ]]
identity="$(cat "$task_dir/review_router_executable_identity")"
[[ "$identity" =~ ^[0-9]+:[0-9]+:[a-f0-9]{64}$ ]]
cmp "$task_dir/review_router_executable" "$repo_state/review_router_executable"
cmp "$task_dir/review_router_executable_identity" "$repo_state/review_router_executable_identity"
grep -Fq "$canonical_router" "$worktree/.sergeant-brief.md"
grep -Fq -- "--require-contract-revision sergeant.review-router-contract/v1" "$worktree/.sergeant-brief.md"
grep -Fq -- "--require-executable-identity $identity" "$worktree/.sergeant-brief.md"
if grep -Fq 'Route each axis separately with `sgt-review-findings ' "$worktree/.sergeant-brief.md"; then
  printf 'worker brief still invokes an unpinned bare router\n' >&2
  exit 1
fi

# A compatible router whose bytes change after dispatch cannot honor the pinned
# runtime invocation; it fails closed before parsing or retaining an artifact.
printf '\n# changed after dispatch\n' >> "$canonical_router"
cat > "$TEST_ROOT/runtime-findings.json" <<'EOF'
{"findings":[{"id":"runtime-1","severity":"warning","disposition":"actionable","summary":"Runtime mismatch","evidence":"router bytes changed","paths":["bin/sgt-review-findings"],"acceptance_criteria":"reject the changed executable","recommendation":"reinstall the matching router"}]}
EOF
set +e
changed_output="$(PATH="$FAKE_BIN:$HOST_PATH" TD_LOG="$TEST_ROOT/runtime-td.log" \
  SERGEANT_CONFIG="$CONFIG" SERGEANT_FLEET="$FLEET" \
  "$canonical_router" test app --input "$TEST_ROOT/runtime-findings.json" \
  --axis standards --source runtime-check --branch feat/matching-router \
  --head-sha abc1234 --parent-task td-router-app --task-id runtime-1 \
  --worktree "$worktree" \
  --require-contract-revision sergeant.review-router-contract/v1 \
  --require-executable-identity "$identity" 2>&1)"
changed_status=$?
set -e
[[ "$changed_status" -ne 0 && "$changed_output" == *'review-router executable identity mismatch'* ]]
artifact="$worktree/.sergeant-review-artifacts/standards-runtime-check"
[[ -s "$artifact/findings" && -s "$artifact/meta" ]]
grep -Fq "Sanitized findings retained at $artifact" "$worktree/.sergeant-message"

git -C "$REPO" worktree remove --force "$worktree"
git -C "$REPO" branch -D feat/matching-router >/dev/null
printf 'sgt-dispatch-review-router-preflight: ok\n'
