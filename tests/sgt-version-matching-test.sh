#!/usr/bin/env bash
# Tests for optimistic version matching (Ruby ~> style) and harness version gating.
#
# Covers:
# 1. _sgt_version_compare (pure Bash 3.2 semver comparison)
# 2. _sgt_version_matches (exact, relational, and Ruby ~> optimistic/pessimistic constraints)
# 3. _require_interactive_agent version gating for opencode, oc alias, and goose

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export SERGEANT_CONFIG="$TEST_ROOT/config"
export SERGEANT_DRAIN_DIR="$TEST_ROOT/drain"
export SERGEANT_FLEET="$TEST_ROOT/fleet"
mkdir -p "$SERGEANT_CONFIG" "$SERGEANT_DRAIN_DIR" "$SERGEANT_FLEET" "$TEST_ROOT/bin"

# shellcheck source=bin/_sgt-lib.sh
source "$ROOT_DIR/bin/_sgt-lib.sh"

PASS=0
FAIL=0
_pass() { PASS=$(( PASS + 1 )); printf 'PASS: %s\n' "$1"; }
_fail() { FAIL=$(( FAIL + 1 )); printf 'FAIL: %s (%s)\n' "$1" "${2:-}" >&2; }

# ── 1. _sgt_version_compare ──────────────────────────────────────────────────

_assert_cmp() {
  local v1="$1" v2="$2" expected="$3" desc="$4"
  local rc=0
  _sgt_version_compare "$v1" "$v2" || rc=$?
  if [[ "$rc" -eq "$expected" ]]; then
    _pass "_sgt_version_compare $desc ($v1 vs $v2 -> $rc)"
  else
    _fail "_sgt_version_compare $desc ($v1 vs $v2)" "got $rc, expected $expected"
  fi
}

_assert_cmp "1.18.18" "1.18.18" 0 "equal versions"
_assert_cmp "1.18" "1.18.0" 0 "equal versions with implicit zero patch"
_assert_cmp "v1.0.0" "1.0" 0 "equal versions with v prefix"
_assert_cmp "1.18.18" "1.18.10" 1 "greater patch"
_assert_cmp "1.18.10" "1.18.18" 2 "lesser patch"
_assert_cmp "2.0.0" "1.99.99" 1 "greater major"
_assert_cmp "0.9.0" "1.0.0" 2 "lesser major"
_assert_cmp "1.10.0" "1.9.0" 1 "numeric comparison, not lexicographic (10 > 9)"
_assert_cmp "1.2.0" "1.18.0" 2 "numeric comparison, not lexicographic (2 < 18)"

# ── 2. _sgt_version_matches ──────────────────────────────────────────────────

_assert_match() {
  local cand="$1" constr="$2" expected="$3"
  local matched=false
  if _sgt_version_matches "$cand" "$constr"; then
    matched=true
  fi
  if [[ "$matched" == "$expected" ]]; then
    _pass "matches: '$cand' vs '$constr' -> $matched"
  else
    _fail "matches: '$cand' vs '$constr'" "got $matched, expected $expected"
  fi
}

# Exact match
_assert_match "1.18.10" "1.18.10" true
_assert_match "1.18.10" "1.18.11" false
_assert_match "1.18.10" "= 1.18.10" true
_assert_match "1.18.10" "== 1.18.10" true

# Standard relational
_assert_match "1.18.0" ">= 1.18.0" true
_assert_match "1.18.18" ">= 1.18.0" true
_assert_match "1.17.9" ">= 1.18.0" false
_assert_match "1.18.1" "> 1.18.0" true
_assert_match "1.18.0" "> 1.18.0" false
_assert_match "1.18.18" "<= 1.18.18" true
_assert_match "1.18.19" "<= 1.18.18" false
_assert_match "1.99.0" "< 2.0.0" true
_assert_match "2.0.0" "< 2.0.0" false

# Ruby ~> 1 (major lock: >= 1.0.0, < 2.0.0)
_assert_match "1.0.0" "~> 1" true
_assert_match "1.18.18" "~> 1" true
_assert_match "1.99.0" "~> 1" true
_assert_match "0.9.9" "~> 1" false
_assert_match "2.0.0" "~> 1" false
_assert_match "2.1.0" "~> 1" false

# Ruby ~> 1.18 (major lock with min minor: >= 1.18.0, < 2.0.0)
_assert_match "1.18.0" "~> 1.18" true
_assert_match "1.18.18" "~> 1.18" true
_assert_match "1.19.0" "~> 1.18" true
_assert_match "1.17.9" "~> 1.18" false
_assert_match "2.0.0" "~> 1.18" false

# Ruby ~> 1.18.10 (minor lock with min patch: >= 1.18.10, < 1.19.0)
_assert_match "1.18.10" "~> 1.18.10" true
_assert_match "1.18.18" "~> 1.18.10" true
_assert_match "1.18.9" "~> 1.18.10" false
_assert_match "1.19.0" "~> 1.18.10" false
_assert_match "2.0.0" "~> 1.18.10" false

# Ruby ~> 1.18.0 (minor lock with min patch 0: >= 1.18.0, < 1.19.0)
_assert_match "1.18.0" "~> 1.18.0" true
_assert_match "1.18.9" "~> 1.18.0" true
_assert_match "1.18.18" "~> 1.18.0" true
_assert_match "1.17.9" "~> 1.18.0" false
_assert_match "1.19.0" "~> 1.18.0" false

# ── 3. _require_interactive_agent gating ──────────────────────────────────────

_make_fake_agent() {
  local name="$1" version="$2" has_session="${3:-true}"
  cat > "$TEST_ROOT/bin/$name" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" ]]; then
  printf '%s %s\n' "$name" "$version"
  exit 0
fi
if [[ "\${1:-}" == "session" && "\${2:-}" == "--help" ]]; then
  if $has_session; then exit 0; else exit 1; fi
fi
exit 0
EOF
  chmod +x "$TEST_ROOT/bin/$name"
}

_test_agent_gate() {
  local cmd="$1" expected_ok="$2" pattern="$3" desc="$4"
  set +e
  local out
  out="$(PATH="$TEST_ROOT/bin:$PATH" SERGEANT_AGENT="$cmd" AGENT_CMD="$cmd" bash -c \
    "source '$ROOT_DIR/bin/_sgt-lib.sh'; _require_interactive_agent" 2>&1)"
  local rc=$?
  set -e
  if [[ "$expected_ok" == true && "$rc" -eq 0 ]]; then
    _pass "_require_interactive_agent: $desc (allowed)"
  elif [[ "$expected_ok" == false && "$rc" -ne 0 ]]; then
    if [[ "$out" == *"$pattern"* ]]; then
      _pass "_require_interactive_agent: $desc (rejected with expected message: '$pattern')"
    else
      _fail "_require_interactive_agent: $desc" "rejected but missing pattern '$pattern': $out"
    fi
  else
    _fail "_require_interactive_agent: $desc" "expected ok=$expected_ok, got rc=$rc, out: $out"
  fi
}

# OpenCode 1.18.10 (known-bad)
_make_fake_agent "opencode" "1.18.10"
_test_agent_gate "opencode" false "known-incompatible" "opencode 1.18.10 rejected as known-incompatible"

# oc alias 1.18.10 (known-bad alias)
_make_fake_agent "oc" "1.18.10"
_test_agent_gate "oc" false "known-incompatible" "oc 1.18.10 rejected as known-incompatible"

# OpenCode 1.18.18 (supported current major)
_make_fake_agent "opencode" "1.18.18"
_test_agent_gate "opencode" true "" "opencode 1.18.18 accepted"

# oc alias 1.18.18 (supported current major)
_make_fake_agent "oc" "1.18.18"
_test_agent_gate "oc" true "" "oc 1.18.18 accepted"

# OpenCode 2.0.0 (unsupported major version)
_make_fake_agent "opencode" "2.0.0"
_test_agent_gate "opencode" false "not supported" "opencode 2.0.0 rejected as unsupported major"

# OpenCode 0.9.0 (unsupported major version)
_make_fake_agent "opencode" "0.9.0"
_test_agent_gate "opencode" false "not supported" "opencode 0.9.0 rejected as unsupported major"

# Goose 1.43.0 (supported current major)
_make_fake_agent "goose" "1.43.0" true
_test_agent_gate "goose" true "" "goose 1.43.0 accepted"

# Goose 2.0.0 (unsupported major version)
_make_fake_agent "goose" "2.0.0" true
_test_agent_gate "goose" false "not supported" "goose 2.0.0 rejected as unsupported major"

# Goose 0.9.0 (unsupported major version)
_make_fake_agent "goose" "0.9.0" true
_test_agent_gate "goose" false "not supported" "goose 0.9.0 rejected as unsupported major"

# Claude 2.1.233 (supported current major)
_make_fake_agent "claude" "2.1.233 (Claude Code)"
_test_agent_gate "claude" true "" "claude 2.1.233 accepted"

# Claude 3.0.0 (unsupported major version)
_make_fake_agent "claude" "3.0.0"
_test_agent_gate "claude" false "not supported" "claude 3.0.0 rejected as unsupported major"

# Claude 1.0.0 (unsupported major version)
_make_fake_agent "claude" "1.0.0"
_test_agent_gate "claude" false "not supported" "claude 1.0.0 rejected as unsupported major"

if real_opencode="$(which opencode 2>/dev/null || command -v opencode 2>/dev/null)"; then
  _test_agent_gate "$real_opencode" true "" "real installed opencode binary passes version gate"
fi

if real_goose="$(which goose 2>/dev/null || command -v goose 2>/dev/null)"; then
  _test_agent_gate "$real_goose" true "" "real installed goose binary passes version gate"
fi

if real_claude="$(which claude 2>/dev/null || command -v claude 2>/dev/null)"; then
  _test_agent_gate "$real_claude" true "" "real installed claude binary passes version gate"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
