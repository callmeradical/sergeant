# Product Requirements: v2-Native Skills and Docs

Status: Draft, awaiting explicit human PRD approval

Extends: the v1 shell-toolbelt removal already landed on `v2` this session,
which deliberately left this exact gap for a follow-up (flagged then as
"out of scope for a code-removal pass").

## Summary

`bin/sgt-*`, `_sgt-*.sh`, and the legacy `sergeant-mcp` proxy no longer exist
on `v2` — but `skills/dispatch/SKILL.md`, `skills/cross-repo-work/SKILL.md`,
`skills/load-project/SKILL.md`, `skills/wiki/SKILL.md`,
`skills/sergeant-help/SKILL.md`, `.agents/skills/to-tickets/SKILL.md`,
`docs/troubleshooting.md`, and `schema/project.yaml.example` still instruct
an operator or agent to run those now-deleted commands
(`sgt-watch --sync <task-id>`, `sgt-dispatch`, `sgt-notify`,
`sgt-td-create`, `sgt-graphify`, and others). This PRD rewrites those files
to describe v2's actual surface — the HTTP API (`POST /api/dispatch`,
`/api/run-resume`, `/api/bullets`, `/api/create-pr`) and the MCP tools
(`sergeant_get_brief`, `sergeant_run_gates`, `sergeant_run_status`,
`sergeant_run_wait`) — instead.

## Problem

Anyone or anything (human operator, or an agent following these skills as
written) that follows the current text on `v2` is told to run commands that
do not exist in the checkout it's reading them from. This is not a
cosmetic inconsistency: `AGENTS.md` decision D7 explicitly forbids v2 from
depending on v1, and these files are the operational instructions a
dispatched agent or a human operator actually reads to know what to do —
exactly the surface where that gap is most consequential.

Compounding this: `tests/instruction-policy-test.sh` currently *requires*
several of the v1-specific strings this PRD would remove (for example,
`require_text "skills/dispatch/SKILL.md" 'sgt-watch --sync <task-id>'`).
That test enforces today's (v1-describing) content is unchanged; rewriting
the skills without also updating the test's assertions would either fail
the test or require silently weakening it. This PRD's implementation must
treat the test's assertions as also needing to change to match the new,
v2-correct required text — not as a pre-existing constraint the rewrite
has to route around.

## Proposal

Rewrite each of the following to describe v2's actual dispatch, review, and
task-tracking model instead of v1 CLI commands:

- `skills/dispatch/SKILL.md` — replace `sgt-dispatch`/`sgt-watch` instructions
  with the `POST /api/dispatch` / `/api/run-resume` / `/api/runs` flow.
- `skills/cross-repo-work/SKILL.md` — replace any v1 multi-repo fleet
  instructions with the Project → Intent → Bullet model already in
  AGENTS.md.
- `skills/load-project/SKILL.md` — replace v1 project-registration
  instructions with v2's project YAML (`internal/config`) conventions.
- `skills/wiki/SKILL.md` — audit for v1 references (`wiki-daily-digest`
  itself was explicitly kept on `v2`; only remove references to deleted
  fleet-dispatch commands, not the wiki tool itself).
- `skills/sergeant-help/SKILL.md` — update its command reference to v2's
  actual commands/API surface.
- `.agents/skills/to-tickets/SKILL.md` — replace `sgt-list`/`sgt-context`/
  `sgt-td-*`/`sgt-dispatch` references with v2 equivalents, or note
  explicitly where v2 has no equivalent yet (e.g., task-tracking export is
  read-only per D4 — this skill cannot assume a v2 command that creates
  tasks in an external tracker).
- `docs/troubleshooting.md` — remove v1-specific troubleshooting steps
  (`sgt-watch <task>`, the Bash 3.2 Docker test suite) that no longer apply.
- `schema/project.yaml.example` — remove comments referencing `sgt-graphify`/
  `sgt-sync`/`sgt-dag-run`/`sgt-watch`; document the fields `internal/config`
  actually reads today.
- `tests/instruction-policy-test.sh` — update its `require_text`/
  `reject_text` assertions to match the new content, in the same change,
  so the test continues to enforce the (now v2-correct) required text
  rather than being weakened or left checking for deleted commands.

## Out of scope

- **Rewriting historical/dated documents** (`docs/audit-2026-07.md`,
  `docs/adr-oc-inject-deletion.md`, `docs/dead-code-2026-07.md`, PRDs,
  openspec archived changes, research docs). These are historical record;
  editing them to remove v1 references would be revisionist, matching the
  decision already made during the v1-removal work.
- **`AGENTS.md` itself.** Already correctly describes v2 (confirmed during
  the v1-removal work); this PRD does not revisit it.
- **Adding new v2 capabilities to close a gap a rewritten skill reveals**
  (for example, if `to-tickets` needs a v2 command that doesn't exist yet).
  Where v2 has no equivalent, the rewritten skill says so explicitly and
  stops there — closing that capability gap is separate, future scope.

## Open questions

- Should these become one OpenSpec change or several (e.g., one per skill
  file, one for `docs/troubleshooting.md` + `schema/project.yaml.example`,
  one for the test)? Given they share one purpose (removing dead v1
  references) but touch independent files with no ordering dependency
  between them, left to OpenSpec's `design.md`/`tasks.md` to decide.
