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
require_file "docs/what-is-sergeant.md"
require_file "docs/getting-started.md"
require_file "docs/skills.md"
require_file "docs/using-sergeant.md"
require_file "docs/troubleshooting.md"
require_text "docs/getting-started.md" "command -v opencode >/dev/null"
require_text "docs/getting-started.md" "command -v claude >/dev/null"
require_text "docs/getting-started.md" "Install OpenCode or Claude Code before using Sergeant."

require_text "AGENTS.md" "## Procedural skills"
require_text "AGENTS.md" "direct executor when requested"
require_text "AGENTS.md" '`sergeant-help`'
require_text "AGENTS.md" "Never edit a default branch in direct mode"
require_text "AGENTS.md" "Open a PR for every direct-mode implementation"
require_text "AGENTS.md" "td context <id> --work-dir <owning-repo-path>"
require_text "AGENTS.md" "ingest, backfill, regenerate, inspect, update, or change the wiki"
require_text "README.md" "docs/README.md"
reject_text "AGENTS.md" "gives one repository as the complete scope"
reject_text "AGENTS.md" "## Project YAML schema (summary)"
reject_text "AGENTS.md" "## td task management integration"
reject_text "AGENTS.md" "## Wiki integration"

reject_text "skills/cross-repo-work/SKILL.md" 'git -C <path> checkout -b'
reject_text "skills/cross-repo-work/SKILL.md" 'git -C <path> push -u origin'
reject_text "skills/cross-repo-work/SKILL.md" 'gh pr create'

reject_text "skills/dispatch/SKILL.md" "Ask for confirmation before dispatching."
reject_text "skills/dispatch/SKILL.md" "remain alive, and wait"
reject_text "skills/dispatch/SKILL.md" 'treehouse return <path> --force'
require_text "skills/dispatch/SKILL.md" 'sgt-watch --sync <task-id>'
require_text "skills/cross-repo-work/SKILL.md" "If the user requested planning only"
reject_text "docs/troubleshooting.md" "follow no-mistakes policy"
require_text "docs/troubleshooting.md" "Do not authorize an in-run fix"
require_text "docs/troubleshooting.md" 'sgt-watch --sync <task-id>'
require_text "docs/troubleshooting.md" "tests/runtime-bash-test.sh"
require_text "docs/troubleshooting.md" "docker.io/library/bash:3.2@sha256:3a13e5da38baa575985778cd09ce8ac736d4b4dafc91a430e71271f6e5311b89"
reject_text "docs/troubleshooting.md" 'Use `sgt-watch <task>`'
require_text "docs/skills.md" "User-invoked orchestrators"
require_text "docs/skills.md" "Model-invoked disciplines"

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
