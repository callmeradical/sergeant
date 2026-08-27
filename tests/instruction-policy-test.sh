#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
failures=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

require_file() {
  local path="$1"
  [[ -f "$repo_root/$path" ]] || fail "missing required instruction file: $path"
}

require_text() {
  local path="$1" text="$2"
  grep -Fq -- "$text" "$repo_root/$path" || fail "$path must contain: $text"
}

reject_text() {
  local path="$1" text="$2"
  if grep -Fq -- "$text" "$repo_root/$path"; then
    fail "$path contains prohibited instruction: $text"
  fi
}

require_file "skills/load-project/SKILL.md"
require_file "skills/cross-repo-work/SKILL.md"
require_file "skills/dispatch/SKILL.md"
require_file "skills/wiki/SKILL.md"
require_file "skills/sergeant-help/SKILL.md"

require_file "docs/README.md"
require_file "docs/troubleshooting.md"

# what-is-sergeant.md, getting-started.md, skills.md, and using-sergeant.md
# described the removed v1 sgt-* toolbelt throughout with no v2 procedure to
# substitute in-place; they were archived to docs/archive/v1/ rather than
# rewritten in place, so no live doc at those paths is required or checked
# here.
require_file "docs/archive/v1/what-is-sergeant.md"
require_file "docs/archive/v1/getting-started.md"
require_file "docs/archive/v1/skills.md"
require_file "docs/archive/v1/using-sergeant.md"

require_text "AGENTS.md" "## Procedural skills"
# shellcheck disable=SC2016
require_text "AGENTS.md" '`sergeant-help`'
require_text "AGENTS.md" ".sergeant-intent.md"
require_text "AGENTS.md" "same canonical intent revision"

# v1's "direct mode" (the coordinator implementing one repo's work in-session
# instead of dispatching) is deliberately not part of v2: v2's AGENTS.md
# states its two entry paths (agent-driven MCP, coordinator-driven
# /api/dispatch) and that "adding a third, divergent execution model is a
# bug." Direct mode would be exactly that third model, so v2's AGENTS.md
# must not describe it -- confirmed with the user, not merely omitted.
reject_text "AGENTS.md" "direct executor when requested"
reject_text "AGENTS.md" "direct mode"
reject_text "AGENTS.md" "td context <id> --work-dir"
# Matches skills/wiki/SKILL.md's own "When to use" wording exactly, rather
# than the older "...or change the wiki" phrasing this check used to assert.
require_text "AGENTS.md" "ingest, backfill, regenerate, inspect, update, or change wiki output"
require_text "skills/wiki/SKILL.md" "ingest, backfill, regenerate, inspect, update, or change wiki output"
require_text "AGENTS.md" 'Sergeant-owned procedural skills live at `skills/<name>/SKILL.md`'
require_text "AGENTS.md" "read that repository-local file directly"
require_text "AGENTS.md" "takes precedence over any same-named registry skill"
require_text "AGENTS.md" "Do not ask the owner or stop solely because the registry omits"
require_text "AGENTS.md" "Only stop and report the exact repository-local path"
require_text "AGENTS.md" "absent or unreadable; do not reconstruct a partial"
reject_text "AGENTS.md" "If a required skill cannot be loaded, stop before the procedure"
require_text "README.md" "docs/README.md"
reject_text "README.md" ".sergeant-intent.md"
reject_text "README.md" '--intent-file'
reject_text "README.md" "bin/sgt-"
reject_text "README.md" "tmux new-session"
reject_text "AGENTS.md" "gives one repository as the complete scope"
reject_text "AGENTS.md" "## Project YAML schema (summary)"
reject_text "AGENTS.md" "## td task management integration"
reject_text "AGENTS.md" "## Wiki integration"

reject_text "skills/dispatch/SKILL.md" "Ask for confirmation before dispatching."
reject_text "skills/dispatch/SKILL.md" "remain alive, and wait"
reject_text "AGENTS.md" 'no-mistakes axi run --intent "<the user'
require_text "skills/cross-repo-work/SKILL.md" "If the user requested planning only"

reject_text "skills/dispatch/SKILL.md" "sgt-dispatch"
reject_text "skills/dispatch/SKILL.md" "sgt-watch"
reject_text "skills/dispatch/SKILL.md" "sgt-respond"
reject_text "skills/dispatch/SKILL.md" "treehouse"
require_text "skills/dispatch/SKILL.md" "POST /api/dispatch"
require_text "skills/dispatch/SKILL.md" "POST /api/run-resume"
reject_text "skills/cross-repo-work/SKILL.md" "sgt-context"
reject_text "skills/cross-repo-work/SKILL.md" "sgt-status"
reject_text "skills/cross-repo-work/SKILL.md" "sgt-dispatch"
reject_text "skills/load-project/SKILL.md" "sgt-list"
reject_text "skills/load-project/SKILL.md" "sgt-context"
reject_text "skills/load-project/SKILL.md" "sgt-sync"
reject_text "skills/load-project/SKILL.md" "sgt-graphify"
reject_text "skills/wiki/SKILL.md" "sgt-dispatch"
reject_text "skills/wiki/SKILL.md" "sgt-notify"
reject_text "skills/wiki/SKILL.md" "sgt-cleanup"
reject_text ".agents/skills/to-tickets/SKILL.md" "sgt-td-create"
reject_text ".agents/skills/to-tickets/SKILL.md" "sgt-list"
reject_text ".agents/skills/to-tickets/SKILL.md" "sgt-context"
require_text ".agents/skills/to-tickets/SKILL.md" "read-only export"
reject_text "docs/troubleshooting.md" "sgt-cleanup"
reject_text "docs/troubleshooting.md" "sgt-sync"
reject_text "schema/project.yaml.example" "sgt-graphify"
reject_text "schema/project.yaml.example" "sgt-sync"
reject_text "schema/project.yaml.example" "sgt-dag-run"
reject_text "schema/project.yaml.example" "sgt-watch"

require_text "skills/load-project/SKILL.md" "## Project registration and edits"
require_text "skills/load-project/SKILL.md" "## Project Graphify"
require_text "skills/wiki/SKILL.md" "## When to use"
require_text "skills/sergeant-help/SKILL.md" "## When to use"
require_text "skills/sergeant-help/SKILL.md" "only when the command supports"

for skill in "$repo_root"/skills/*/SKILL.md; do
  if grep -Eiq '(be thorough|write clean code|high[- ]quality|make it readable|best practices|be careful|do it properly|internalize)' "$skill"; then
    fail "${skill#"$repo_root/"} contains vague no-op quality language"
  fi
done

for phrase in "be thorough" "write clean code" "make it readable" "use best practices"; do
  count="$(grep -Fic -- "$phrase" "$repo_root/AGENTS.md" || true)"
  if ((count > 1)); then
    fail "AGENTS.md contains vague no-op directive outside its prohibited examples: $phrase"
  fi
done

if ((failures > 0)); then
  printf '%d instruction policy check(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'instruction policy checks passed\n'
