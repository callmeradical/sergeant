#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANONICAL_DIR="$ROOT_DIR/.agents/skills"
CLAUDE_DIR="$ROOT_DIR/.claude/skills"

expected=(
  code-review
  codebase-design
  diagnosing-bugs
  domain-modeling
  grill-with-docs
  grilling
  implement
  no-mistakes
  prototype
  research
  resolving-merge-conflicts
  sergeant-setup
  tdd
  to-spec
  to-tickets
  triage
  wayfinder
)

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

[[ -f "$ROOT_DIR/LICENSE" ]] || fail 'missing project LICENSE'
grep -Fq 'Copyright (c) 2026 Lars Cromley' "$ROOT_DIR/LICENSE"
[[ -f "$CANONICAL_DIR/PROVENANCE.md" ]] || fail 'missing skill provenance'
[[ -f "$CANONICAL_DIR/THIRD_PARTY_NOTICES.md" ]] || fail 'missing third-party notices'

actual=()
for skill_dir in "$CANONICAL_DIR"/*/; do
  [[ -d "$skill_dir" ]] || continue
  skill="$(basename "$skill_dir")"
  actual+=("$skill")
  skill_file="$skill_dir/SKILL.md"
  [[ -f "$skill_file" ]] || fail "missing SKILL.md: $skill"
  [[ "$(sed -n '1p' "$skill_file")" == '---' ]] || fail "invalid frontmatter start: $skill"
  [[ "$(sed -n '2p' "$skill_file")" == "name: $skill" ]] || fail "invalid frontmatter name: $skill"
  [[ "$(sed -n '3p' "$skill_file")" == 'description: '* ]] || fail "missing frontmatter description: $skill"
  awk 'NR > 1 && /^---$/ { found = 1; exit } END { exit !found }' "$skill_file" || \
    fail "invalid frontmatter end: $skill"
done

actual_sorted="$(printf '%s\n' "${actual[@]}" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
expected_sorted="$(printf '%s\n' "${expected[@]}" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
[[ "$actual_sorted" == "$expected_sorted" ]] || fail "canonical inventory drift: ${actual_sorted}"
# no-mistakes is now vendored (coordinator-only, with user-invocable guard stripped)
[[ -e "$CANONICAL_DIR/no-mistakes" ]] || fail 'no-mistakes skill must be vendored'

for skill in "${expected[@]}"; do
  link="$CLAUDE_DIR/$skill"
  [[ -L "$link" ]] || fail "Claude skill is not a symlink: $skill"
  [[ "$(realpath "$link")" == "$CANONICAL_DIR/$skill" ]] || fail "Claude skill link escapes canonical tree: $skill"
done

for skill in load-project cross-repo-work dispatch; do
  skill_file="$ROOT_DIR/skills/$skill/SKILL.md"
  [[ -f "$skill_file" ]] || fail "missing Sergeant procedural skill: $skill"
  [[ "$(sed -n '1p' "$skill_file")" == '---' ]] || fail "invalid procedural frontmatter: $skill"
  [[ "$(sed -n '2p' "$skill_file")" == "name: $skill" ]] || fail "invalid procedural skill name: $skill"
done

python3 - "$ROOT_DIR/opencode.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as config_file:
    config = json.load(config_file)

assert config == {
    "$schema": "https://opencode.ai/config.json",
    "skills": {"paths": [".agents/skills", "skills"]},
}
PY

for skill in codebase-design code-review diagnosing-bugs domain-modeling grilling grill-with-docs \
             implement prototype research resolving-merge-conflicts tdd to-spec triage wayfinder; do
  grep -Fq "\`$skill\`" "$CANONICAL_DIR/THIRD_PARTY_NOTICES.md" || fail "missing notice: $skill"
done
grep -Fq 'Copyright (c) 2026 Matt Pocock' "$CANONICAL_DIR/THIRD_PARTY_NOTICES.md"
grep -Fq 'https://github.com/mattpocock/skills' "$CANONICAL_DIR/THIRD_PARTY_NOTICES.md"
grep -Fq "\`to-tickets\`" "$CANONICAL_DIR/THIRD_PARTY_NOTICES.md"
grep -Fq "\`no-mistakes\`" "$CANONICAL_DIR/THIRD_PARTY_NOTICES.md"
grep -Fq "\`sergeant-setup\`" "$CANONICAL_DIR/THIRD_PARTY_NOTICES.md"
grep -Fq 'no-mistakes' "$CANONICAL_DIR/PROVENANCE.md"

printf 'repo-scoped skill discovery: ok\n'
