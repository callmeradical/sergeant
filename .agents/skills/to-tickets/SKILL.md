---
name: to-tickets
description: Use when the user says "to tickets", "create issues", "create td tasks", "make epics", or asks to break a plan, spec, investigation, findings register, PR, or conversation into dependency-aware tracer-bullet work for Sergeant and td.
---

# To Tickets

Turn a plan, specification, investigation, findings register, PR, or current
conversation into implementation-ready epics and tracer-bullet tickets. Tickets
are narrow, complete tracer bullets with explicit ownership, acceptance criteria,
and blocking edges. Sergeant project configuration is the source of truth for
repository scope.

v2's task-tracking is a read-only export (decision D4): Sergeant has no inbound
integration that creates or mutates tasks in an external tracker. This skill
produces the ticket breakdown and dispatches it through Sergeant's own Intent/
Bullet records; it does not publish to, or otherwise write into, an external
task tracker.

## Principles

- Prefer vertical slices that produce independently verifiable behavior.
- Keep each ticket small enough for one fresh agent context.
- Assign exactly one owning repository to each implementation ticket.
- Represent cross-repository delivery with counterpart tickets and explicit merge
  order, not one ambiguous shared ticket.
- Use expand-migrate-contract for mechanical changes that cannot remain green as a
  vertical slice.
- Create epics for coherent programs, not as substitutes for executable tickets.
- Never duplicate an existing open Sergeant intent or GitHub issue.
- Preserve stable finding IDs such as `RBAC-P1-004` or `DATA-P0-002` in titles.
- A ticket is not ready unless its acceptance criteria are observable and its
  blockers are accurate.

## 1. Load Project Context

When operating through Sergeant:

1. Run `GET /api/projects` or list `~/.config/sergeant/*.yaml` if the project
   name is not already established.
2. Run `GET /api/project-details?name=<project>`, or read the project YAML
   directly.
3. Run `GET /api/runs?project=<name>` and check for an existing open intent
   targeting the same outcome — v2 has no external task list to deduplicate
   against beyond Sergeant's own Intent/Bullet store.
4. For architecture or codebase questions, use the existing Graphify graph
   (`sergeant_graph_query` MCP tool) before reading files individually.
5. Read any referenced issue, PR, specification, ADR, or findings register in full.

## 2. Extract Decisions and Unknowns

Before drafting tickets, identify:

- The user-visible or operational outcome.
- Decisions already approved. Do not reopen them as questions.
- Unknowns that genuinely block implementation.
- Safety constraints, compatibility requirements, persisted data, and rollback
  expectations.
- Repository ownership and cross-repository contracts.
- Existing work, preserved branches, open PRs, and issue IDs.

Create a short investigation ticket only when an unknown cannot be answered from
existing evidence. Investigation tickets must name the decision or artifact they
produce.

## 3. Draft Epics and Tracer Bullets

Group work into a small number of epics. For each ticket define:

- **Repository**: one owning repo.
- **Title**: outcome-oriented; include stable finding ID when present.
- **Priority**: P0 through P4 based on impact and urgency.
- **What it delivers**: one independently demonstrable vertical behavior.
- **Acceptance criteria**: concrete positive, negative, migration, rollback, and
  observability checks as applicable.
- **Blocked by**: only tickets that truly prevent starting or merging this work.
- **Counterparts**: tickets in other repos and required merge order.
- **Preserved state**: branch, commit, PR, or worktree needed to resume work.

### Vertical Slice Rules

- Include every necessary layer for one behavior: storage, API, UI/CLI, tests,
  deployment, and docs only where that slice requires them.
- Do not create separate "write backend", "write frontend", and "add tests"
  horizontal tickets for one behavior.
- A completed ticket must be demoable, testable, or operationally verifiable alone.
- Put prefactoring first only when it materially reduces risk for following slices.

### Wide Refactors

When one mechanical change breaks too many callers to land as a vertical slice:

1. **Expand**: add the new form beside the old.
2. **Migrate**: move callers in bounded, green batches.
3. **Contract**: remove the old form after every migration ticket completes.

Declare all migrate tickets blocked by expand, and contract blocked by every
migration ticket.

## 4. Confirm the Breakdown

Unless the user explicitly said to create or publish tickets immediately, present
the proposed breakdown first. For every ticket show:

1. Title and owning repo.
2. Epic.
3. Blocked by.
4. What it delivers.
5. Acceptance criteria summary.

Ask only whether granularity, ownership, and blocking edges are correct. Do not ask
the user to reconfirm decisions already made.

## 5. Task tracking is a stated gap, not a publish step

v2's task-tracking is a read-only export (decision D4). This skill does not
create, update, or close tasks in an external tracker — there is no v2 command
that does. Once the breakdown is confirmed, its durable record is the Intent and
Bullet rows a dispatch creates in Sergeant's own store (see step 7 below), not an
external ticket.

If the user wants the breakdown recorded in an external tracker as well, that is
a separate, manual step outside this skill and outside Sergeant's current v2
scope. Do not invent a command to do it.

## 6. Validate the Breakdown

Before reporting the breakdown as ready:

1. Confirm each ticket has one owning repository and one parent epic.
2. Confirm every "blocked by" edge points in the correct direction.
3. Confirm no circular or cross-repo pseudo-dependencies exist.
4. Confirm preserved branches, PRs, and worktrees are named where they apply.

## 7. Report the Dispatch Frontier

Return:

- Epics grouped by repository.
- Tickets grouped by priority and dependency wave.
- The **frontier**: tickets with no unfinished blockers.
- Recommended concurrency: one worker per owning repository unless the project
  explicitly supports more.
- Exact dispatch call for the next wave — `POST /api/dispatch` with `change_id`
  set to the ticket's corresponding OpenSpec change id (decision O3), since
  dispatch resolves to an OpenSpec change on v2, not an external ticket id.

Do not dispatch unless the user asked to begin implementation.

## Ticket Quality Checklist

Before reporting each ticket as ready, verify:

- [ ] One owning repository.
- [ ] One independently verifiable outcome.
- [ ] Stable finding or parent reference preserved.
- [ ] Acceptance criteria cover failure behavior, not only happy path.
- [ ] Migration and rollback criteria exist when persisted data changes.
- [ ] Observability or live verification exists for operational changes.
- [ ] Blockers are genuine and acyclic.
- [ ] Cross-repo counterpart and merge order are explicit.
- [ ] No brittle implementation file list unless a preserved prototype requires it.
- [ ] Small enough for one fresh agent context.

## Output Template Before Publishing

```markdown
### Epic: <title> — <owning repo>

1. **<ticket title>** — `<repo>`
   - Blocked by: <IDs or none>
   - Delivers: <end-to-end behavior>
   - Acceptance: <concise observable criteria>
```

## Output Template After Confirming

```markdown
**Epics**
- `<repo>`: <title>

**Frontier**
- `<repo>`: <title>

**Next Dispatch**
`POST /api/dispatch` `{"project":"<project>","change_id":"<change-id>", ...}`
```
