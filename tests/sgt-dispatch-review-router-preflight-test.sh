#!/usr/bin/env bash
# Regression for GH #204: sgt-dispatch preflights the installed review-router
# contract before creating any worktree, td task, or fleet state.
#
# Seam: _sgt_preflight_review_router in sgt-dispatch reads the router's usage
# output and verifies axes and severities before dispatch proceeds.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
export SERGEANT_CONFIG="$TEST_ROOT/config"
export SERGEANT_FLEET="$TEST_ROOT/fleet"
export SGT_WIKI_DISABLED=1
mkdir -p "$SERGEANT_CONFIG" "$SERGEANT_FLEET"

PASS=0; FAIL=0
_pass() { PASS=$(( PASS + 1 )); printf 'PASS: %s\n' "$1"; }
_fail() { FAIL=$(( FAIL + 1 )); printf 'FAIL: %s\n' "$1" >&2; }

source "$ROOT_DIR/bin/_sgt-review-axes.sh"

# ── Test 1: current router usage lists all required axes ─────────────────────
router="$ROOT_DIR/bin/sgt-review-findings"
router_usage="$("$router" 2>&1 || true)"

all_axes_ok=true
# shellcheck disable=SC2046
for axis in $SGT_REVIEW_AXES_REQUIRED; do
  if ! printf '%s' "$router_usage" | grep -qF "$axis"; then
    _fail "current router missing required axis '$axis' in usage"
    all_axes_ok=false
  fi
done
[[ "$all_axes_ok" == "true" ]] && _pass "current router lists all required axes"

# ── Test 2: current router usage lists all canonical severities ───────────────
all_sev_ok=true
# shellcheck disable=SC2046
for sev in $SGT_REVIEW_SEVERITIES; do
  if ! printf '%s' "$router_usage" | grep -qF "$sev"; then
    _fail "current router missing severity '$sev' in usage"
    all_sev_ok=false
  fi
done
[[ "$all_sev_ok" == "true" ]] && _pass "current router lists all canonical severities"

# ── Test 3: preflight rejects a stale router missing a required axis ──────────
fake_bin="$TEST_ROOT/fake-bin"
mkdir -p "$fake_bin"
# A stale router that knows only 'standards' and not 'spec' or 'readiness'.
cat > "$fake_bin/sgt-review-findings" <<'EOF'
#!/usr/bin/env bash
printf 'Usage: sgt-review-findings <project> <repo> ...\n'
printf 'Accepted --axis values: standards\n'
printf 'Canonical finding severities: error|warning|info\n'
exit 1
EOF
chmod +x "$fake_bin/sgt-review-findings"

# Write a probe script that sources _sgt_preflight_review_router from
# sgt-dispatch and runs it with the stale fake router on PATH.
probe="$TEST_ROOT/probe-stale.sh"
# Extract the preflight function body to a temp file.
preflight_func="$(awk '/^_sgt_preflight_review_router\(\)/{p=1} p{print} p && /^}$/{exit}' \
    "$ROOT_DIR/bin/sgt-dispatch")"
cat > "$probe" <<PROBE
#!/usr/bin/env bash
set -euo pipefail
source '$ROOT_DIR/bin/_sgt-lib.sh' 2>/dev/null
source '$ROOT_DIR/bin/_sgt-review-axes.sh' 2>/dev/null
DRY_RUN=false
SCRIPT_DIR='$fake_bin'

$preflight_func

_sgt_preflight_review_router
PROBE
chmod +x "$probe"

stale_output="$(PATH="$fake_bin:/usr/bin:/bin" bash "$probe" 2>&1 || true)"
if printf '%s' "$stale_output" | grep -qiE 'mismatch|does not list|contract'; then
  _pass "stale router (missing 'spec'): preflight detects and reports mismatch"
else
  _fail "stale router: preflight did not report mismatch (got: $stale_output)"
fi

# ── Test 4: preflight passes for the current installed router ─────────────────
probe4="$TEST_ROOT/probe-current.sh"
cat > "$probe4" <<PROBE4
#!/usr/bin/env bash
set -euo pipefail
source '$ROOT_DIR/bin/_sgt-lib.sh' 2>/dev/null
source '$ROOT_DIR/bin/_sgt-review-axes.sh' 2>/dev/null
DRY_RUN=false
SCRIPT_DIR='$ROOT_DIR/bin'

$preflight_func

_sgt_preflight_review_router && printf 'OK\n'
PROBE4
chmod +x "$probe4"

current_output="$(PATH="$ROOT_DIR/bin:/usr/bin:/bin" bash "$probe4" 2>&1 || true)"
if printf '%s' "$current_output" | grep -qF 'OK'; then
  _pass "current router: preflight passes without error"
else
  _fail "current router: preflight failed (got: $current_output)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
