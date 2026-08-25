# Proposal — v2-native skills and docs

## Repository

One repository: `sergeant-v2`.

## Requirements served

**`docs/prd-v2-native-skills-and-docs.md`** (this change's originating PRD).

**D7** — "v1 is not a dependency... Where a v1 capability is absent, that is
unimplemented v2 scope." The eight files this change touches instruct a
reader (human operator or dispatched agent) to run `bin/sgt-*` commands that
no longer exist on `v2` — the exact condition D7 exists to prevent, just in
documentation rather than code.

**D4** — "Exporting a read-only copy to a task tracker is optional." Several
of these files (notably `.agents/skills/to-tickets/SKILL.md`) instruct
creating and mutating tasks in an external tracker via `sgt-td-*`. v2 has no
inbound task-tracker integration at all (task-tracking-is-a-readonly-export
is one-way, export-only). This change states that gap explicitly rather than
inventing a v2 command that doesn't exist.

## Problem

`bin/sgt-*`, `_sgt-*.sh`, and the legacy `sergeant-mcp` proxy were deleted
from `v2` (v1 shell-toolbelt removal, this session). Five of the eight files
this change touches (`skills/dispatch/SKILL.md`, `skills/cross-repo-work/
SKILL.md`, `skills/load-project/SKILL.md`, `skills/wiki/SKILL.md`,
`skills/sergeant-help/SKILL.md`) already carry a "V1 ONLY — DO NOT FOLLOW ON
THE `v2` BRANCH" banner redirecting a v2 reader to `AGENTS.md` — so the
original PRD's framing ("anyone who follows the current text is told to run
commands that do not exist") is not quite accurate for these five: a v2
reader is stopped before acting on the stale procedure below the banner.

The real gap is narrower but still real: `AGENTS.md` is a policy document
(domain model, D-numbered decisions, truthfulness rules), not a procedure. A
v2 operator or agent who is redirected there for "how do I dispatch a
cross-repo task" or "how do I load a project" finds no procedural content at
all — only "read AGENTS.md instead," and AGENTS.md doesn't describe *how* to
call `POST /api/dispatch` step by step, what a blocked bullet's actual
resolution path is, or what a project YAML's fields mean for v2. Three files
have no such banner and no v2 counterpart at all:
`.agents/skills/to-tickets/SKILL.md`, `docs/troubleshooting.md`, and
`schema/project.yaml.example` — these three genuinely do instruct a v2
reader to run deleted commands with nothing stopping them first.

## Proposal

For the five banner-carrying skills: remove the "V1 ONLY" banner (it becomes
self-contradictory once the body below it describes v2, not v1) and replace
each v1 procedure with the equivalent v2 one, using the real, already-shipped
v2 surface:

- Dispatch: `POST /api/dispatch` (project, brief, repos, agent, type,
  change_id, request_id) instead of `sgt-dispatch`.
- Monitor: `GET /api/runs` / `GET /api/run-details?id=` instead of
  `sgt-watch`/tmux attach.
- Resolve a blocked bullet: fix the underlying cause, then
  `POST /api/run-resume {"id": "<run-id>"}` — v2's actual, coarser-grained
  equivalent of v1's `sgt-respond` + response-file protocol. There is no
  structured response-message channel in v2; this change states that as the
  real mechanism, not a gap to paper over.
- Reconcile/approve: `GET /api/bullets?run_id=`, `POST /api/create-pr`
  (which itself enforces the sealed-bullet gate and, once every bullet is
  sealed, the shipping gate).
- Cross-repo merge order: the Intent's bullet order (D6), not a `--deps`
  flag — v2 has no dependency-flag equivalent; ordering is a property of how
  the intent was decomposed (D2), not a per-dispatch argument.
- Treehouse/tmux worktree pooling: removed outright, no v2 equivalent and
  none needed — D7 forbids tmux, and `internal/dag/engine.go`'s plain git
  worktree isolation has no pooling concept.

For `.agents/skills/to-tickets/SKILL.md`: replace `sgt-list`/`sgt-context`/
`sgt-td-*`/`sgt-dispatch` references with v2 equivalents where one exists
(dispatch → `POST /api/dispatch`), and an explicit stated gap where none
does (task creation/mutation in an external tracker — v2's task-tracking is
read-only export per D4; this skill cannot create or update external tasks
on v2).

For `docs/troubleshooting.md`: remove entries with no v2 relevance (the
Bash 3.2 Docker test suite, tmux pane diagnostics, `sgt-cleanup`/
`sgt-recover`/`sgt-ack-response` fleet-file troubleshooting); keep and
rewrite entries with a real v2 answer (project registry location, run
status inspection) to point at v2's store/API instead of fleet files.

For `schema/project.yaml.example`: remove comments referencing deleted
commands (`sgt-graphify`, `sgt-sync`, `sgt-dag-run`, `sgt-watch`); keep the
YAML shape itself (repos, groups, graphify, dag, defaults are all still
real `internal/config.Project` fields) and describe what each field is for
in v2 terms.

For `tests/instruction-policy-test.sh`: update only the `require_text`/
`reject_text` lines that name the eight files above, to match their new
content. The test's 15 pre-existing failures (all `AGENTS.md`-related,
confirmed pre-existing/unrelated during the v1-removal work this session)
are untouched and expected to remain — this change does not fix them and
does not claim to.

## Out of scope

- **`AGENTS.md`.** Already correctly describes v2; not revisited.
- **Historical/dated documents** (`docs/audit-2026-07.md`,
  `docs/adr-oc-inject-deletion.md`, `docs/dead-code-2026-07.md`, PRDs,
  openspec archives, research docs).
- **`docs/using-sergeant.md`, `docs/skills.md`, `docs/getting-started.md`,
  `docs/what-is-sergeant.md`, `README.md`, `docs/README.md`.** Not named by
  the originating PRD; several are already part of `instruction-policy-
  test.sh`'s pre-existing (unrelated) failure set and rewriting them is a
  separate scope decision.
- **Fixing `instruction-policy-test.sh`'s 15 pre-existing AGENTS.md
  failures.** Confirmed unrelated to v1 removal or this change; left alone.
- **Adding any new v2 API/MCP capability** to close a gap a rewritten skill
  reveals (e.g., a structured blocked-bullet response channel, or a
  writable task-tracker integration). Stated explicitly, not built here.
