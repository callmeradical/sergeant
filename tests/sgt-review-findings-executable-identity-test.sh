#!/usr/bin/env bash
# Regression for GH #204: sgt-review-findings's own
# --require-executable-identity comparison must use the exact same
# dev:ino:sha256:runtime_sha256 algorithm and runtime dependency set that
# bin/sgt-dispatch's _sgt_review_router_executable_identity computes and
# persists to .sergeant-task/review_router_executable_identity. Before the
# fix, sgt-review-findings computed a different 3-part dev:ino:sha256 value
# (router bytes only), so the flag could never succeed against the value
# dispatch actually persists, even for a genuinely unchanged executable.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
export SERGEANT_FLEET="$TEST_ROOT/fleet"
mkdir -p "$SERGEANT_FLEET"
trap 'rm -rf "$TEST_ROOT"' EXIT

REPO="$TEST_ROOT/app"
WORKTREE="$TEST_ROOT/worktree"
INSTALLED_BIN="$TEST_ROOT/installed-bin"
mkdir -p "$TEST_ROOT/config" "$TEST_ROOT/fake-bin" "$REPO" "$WORKTREE" "$INSTALLED_BIN"
git -C "$REPO" init -q

cat >"$TEST_ROOT/config/test.yaml" <<EOF
name: test
repos:
  - name: app
    path: $REPO
EOF

# ── Fixture install: every RUNTIME_FILES dependency, as real regular files
# (not symlinks) so the "byte changes" case below can mutate one in place
# without touching the real repository checkout. ────────────────────────────
RUNTIME_FILES=(
	sgt-review-findings _sgt-lib.sh _sgt-response-lock.sh _sgt-review-axes.sh
	_sgt-bash-version.sh _sgt-process-identity.sh _sgt-drain.sh _sgt-process.sh
	_sgt-response-lock-transition.py _sgt-process-token.py sgt-callback
)
for f in "${RUNTIME_FILES[@]}"; do
	cp "$ROOT_DIR/bin/$f" "$INSTALLED_BIN/$f"
	chmod +x "$INSTALLED_BIN/$f"
done
# The shared helper sgt-review-findings' own fix delegates to. Not part of
# RUNTIME_FILES (it is not a review-router runtime dependency; it only
# computes the identity), but must exist alongside the fixture router.
cp "$ROOT_DIR/bin/_sgt-review-router-identity.py" "$INSTALLED_BIN/_sgt-review-router-identity.py"
chmod +x "$INSTALLED_BIN/_sgt-review-router-identity.py"
# sgt-notify's content is hashed as a runtime dependency too, but this suite
# never needs the real notify infrastructure (tmux, fleet callbacks). A fixed
# stub is fine: identity is content-and-path based, not "must be genuine".
cat >"$INSTALLED_BIN/sgt-notify" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${NOTIFY_LOG:-/dev/null}"
EOF
chmod +x "$INSTALLED_BIN/sgt-notify"

# ── Independent oracle: the exact function body bin/sgt-dispatch defines as
# _sgt_review_router_executable_identity, extracted verbatim from the real
# file text (not our fix, not a hand-copied duplicate) so this test fails if
# either side ever drifts. ───────────────────────────────────────────────────
DISPATCH_IDENTITY_FN="$TEST_ROOT/dispatch-identity-fn.sh"
awk '/^_sgt_review_router_executable_identity\(\) \{/,/^}/' \
	"$ROOT_DIR/bin/sgt-dispatch" >"$DISPATCH_IDENTITY_FN"
[[ -s "$DISPATCH_IDENTITY_FN" ]] || {
	printf 'could not extract _sgt_review_router_executable_identity from sgt-dispatch\n' >&2
	exit 1
}
# shellcheck disable=SC1090
source "$DISPATCH_IDENTITY_FN"

EXPECTED_IDENTITY="$(_sgt_review_router_executable_identity "$INSTALLED_BIN/sgt-review-findings")"
[[ "$EXPECTED_IDENTITY" =~ ^[0-9]+:[0-9]+:[a-f0-9]{64}:[a-f0-9]{64}$ ]] || {
	printf 'dispatch-derived identity is not the expected 4-part shape: %s\n' "$EXPECTED_IDENTITY" >&2
	exit 1
}

cat >"$TEST_ROOT/fake-bin/td" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  --version) printf 'td version 1.0.0\n'; exit 0 ;;
  create) [[ "${2:-}" != "--help" ]] || { printf 'Usage: td create ... --description <text> --json --work-dir <path>\n'; exit 0; } ;;
esac
case "$1" in
  list) printf '%s\n' '[]' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/td"

cat >"$TEST_ROOT/fake-bin/yq" <<EOF
#!/usr/bin/env bash
case "\$1" in
  '.repos | length') printf '1\n' ;;
  '.repos[0].name') printf 'app\n' ;;
  '.repos[0].path') printf '%s\n' "$REPO" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/yq"

printf '{"findings":[]}\n' >"$TEST_ROOT/empty-findings.json"

run_router() {
	local identity="$1"
	rm -f "$WORKTREE"/.sergeant-{status,message,gate-generation,review-gates.lock}
	rm -rf "$WORKTREE/.sergeant-review-gates" "$WORKTREE/.sergeant-review-artifacts"
	set +e
	output="$(PATH="$TEST_ROOT/fake-bin:$PATH" SERGEANT_CONFIG="$TEST_ROOT/config" \
		NOTIFY_LOG="$TEST_ROOT/notify.log" \
		"$INSTALLED_BIN/sgt-review-findings" test app \
		--input "$TEST_ROOT/empty-findings.json" --axis standards --source identity-check \
		--branch fix/identity --head-sha abc1234 --parent-task td-parent \
		--task-id fleet1 --worktree "$WORKTREE" \
		--require-contract-revision sergeant.review-router-contract/v1 \
		--require-executable-identity "$identity" 2>&1)"
	status=$?
	set -e
}

# ── RED/GREEN case 1: the dispatch-derived identity for the genuinely
# unchanged fixture router must be accepted, not reported as a mismatch. ─────
run_router "$EXPECTED_IDENTITY"
if [[ "$status" -ne 0 || "$output" == *'identity mismatch'* || "$output" == *'could not verify review-router executable identity'* ]]; then
	printf 'FAIL: matching dispatch-derived identity was rejected: status=%s output=%s\n' "$status" "$output" >&2
	exit 1
fi
[[ "$output" == *'no actionable findings'* ]] || {
	printf 'FAIL: matching-identity run did not reach the success path: %s\n' "$output" >&2
	exit 1
}

# ── Case 2: a one-byte change to a runtime dependency (not the router file
# itself) must be detected and fail closed, proving the identity actually
# covers the runtime dependency set and not just the router's own bytes. ────
cp "$INSTALLED_BIN/_sgt-review-axes.sh" "$TEST_ROOT/_sgt-review-axes.sh.orig"
printf '\n# one byte changed\n' >>"$INSTALLED_BIN/_sgt-review-axes.sh"
run_router "$EXPECTED_IDENTITY"
cp "$TEST_ROOT/_sgt-review-axes.sh.orig" "$INSTALLED_BIN/_sgt-review-axes.sh"
[[ "$status" -ne 0 && "$output" == *'review-router executable identity mismatch'* ]] || {
	printf 'FAIL: changed runtime dependency was not rejected as an identity mismatch: status=%s output=%s\n' "$status" "$output" >&2
	exit 1
}

printf 'sgt-review-findings-executable-identity: ok\n'
