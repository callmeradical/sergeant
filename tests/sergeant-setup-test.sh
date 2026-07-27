#!/usr/bin/env bash
# Tests for the sergeant-setup Agent Skill.
#
# Safety invariants checked here:
#   - Skill never instructs writes to global agent configuration paths
#   - td, Graphify, and Treehouse initialization require explicit consent
#   - Skill covers the required installation and repair checklist phases

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$REPO/.agents/skills/sergeant-setup/SKILL.md"
failures=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

require_file() {
  [[ -f "$1" ]] || { fail "missing file: $1"; return; }
}

require_text() {
  local file="$1" text="$2"
  grep -Fq -- "$text" "$file" || fail "$file must contain: $text"
}

reject_text() {
  local file="$1" text="$2"
  if grep -Fq -- "$text" "$file"; then
    fail "$file must not contain: $text"
  fi
}

# ── Existence ────────────────────────────────────────────────────────────────

require_file "$SKILL"

# ── Frontmatter ──────────────────────────────────────────────────────────────

[[ "$(sed -n '1p' "$SKILL")" == '---' ]] || fail "invalid frontmatter start"
[[ "$(sed -n '2p' "$SKILL")" == 'name: sergeant-setup' ]] || fail "invalid frontmatter name"
[[ "$(sed -n '3p' "$SKILL")" == 'description: '* ]] || fail "missing frontmatter description"
awk 'NR > 1 && /^---$/ { found = 1; exit } END { exit !found }' "$SKILL" \
  || fail "invalid frontmatter end"

# ── Required sections ────────────────────────────────────────────────────────

require_text "$SKILL" "## When to use"
require_text "$SKILL" "## Safety constraints"
require_text "$SKILL" "## Failure behavior"

# ── Global path prohibition ───────────────────────────────────────────────────
# The skill must explicitly prohibit writes to every major agent config path.
# Tildes below are intentional literal strings for grep, not shell expansions.
# shellcheck disable=SC2088
require_text "$SKILL" 'Never write to'
# shellcheck disable=SC2088
require_text "$SKILL" '~/.config/opencode/'
# shellcheck disable=SC2088
require_text "$SKILL" '~/.claude/'
# shellcheck disable=SC2088
require_text "$SKILL" '~/.codex/'
# shellcheck disable=SC2088
require_text "$SKILL" '~/.goose/'
require_text "$SKILL" 'AGENTS.md'

# ── No implicit initialization ───────────────────────────────────────────────
# td, Graphify, and Treehouse each require an explicit confirmation prompt.

require_text "$SKILL" 'explicit confirmation'
require_text "$SKILL" 'sgt-treehouse-init'
require_text "$SKILL" 'sgt-graphify'

# The skill must not instruct td auto-init without consent.
reject_text "$SKILL" 'td init --work-dir'

# ── Required checklist phases ─────────────────────────────────────────────────

require_text "$SKILL" 'Detect prerequisites'
require_text "$SKILL" 'command links'
require_text "$SKILL" 'Global config'
require_text "$SKILL" 'interview'
require_text "$SKILL" 'Repair existing YAML'
require_text "$SKILL" 'Sync and verification'
require_text "$SKILL" 'treehouse'
require_text "$SKILL" 'Idempotency'

# ── Failure-mode coverage ────────────────────────────────────────────────────
# Verify each required failure mode has a stop condition in the failure table.

require_text "$SKILL" '## Failure behavior'
require_text "$SKILL" 'Required prerequisite missing and not installable'
require_text "$SKILL" 'Consent declined for any write'
require_text "$SKILL" 'YAML parse error on existing file'
require_text "$SKILL" 'Unsupported setup capability needed'
require_text "$SKILL" 'sgt-sync'
require_text "$SKILL" 'Partial setup on exit'

# The failure table must not indicate auto-continue after a failed sync.
reject_text "$SKILL" 'continue past Phase 7'

# ── Consent gate on every mutation ───────────────────────────────────────────

require_text "$SKILL" '[y/N]'
require_text "$SKILL" 'backup'

# ── Vague quality language check ─────────────────────────────────────────────

if grep -Eiq '(be thorough|write clean code|high[- ]quality|make it readable|best practices|be careful|do it properly|internalize)' "$SKILL"; then
  fail "$SKILL contains vague no-op quality language"
fi

# ── No write instructions targeting global agent config paths ────────────────
# Detect any prose that would instruct an agent to write to these paths.
# The skill may list them in prohibition sections; it must not tell the agent
# to create or modify them.
for forbidden_pattern in \
  'write.*opencode\.json' \
  'create.*opencode\.json' \
  'write.*CLAUDE\.md' \
  'create.*CLAUDE\.md' \
  'write.*AGENTS\.md' \
  'modify.*AGENTS\.md'; do
  if grep -Eiq "$forbidden_pattern" "$SKILL"; then
    fail "$SKILL contains a write instruction for a prohibited path: $forbidden_pattern"
  fi
done

# ── Claude symlink ────────────────────────────────────────────────────────────

LINK="$REPO/.claude/skills/sergeant-setup"
[[ -L "$LINK" ]] || fail "Claude skill is not a symlink: sergeant-setup"
[[ "$(realpath "$LINK")" == "$REPO/.agents/skills/sergeant-setup" ]] \
  || fail "Claude skill link escapes canonical tree: sergeant-setup"

if ((failures > 0)); then
  printf '%d sergeant-setup skill check(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'sergeant-setup skill checks: ok\n'
