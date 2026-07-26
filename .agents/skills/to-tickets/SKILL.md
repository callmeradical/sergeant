---
name: to-tickets
description: Use when the user says "to tickets", "create issues", "create td tasks", "make epics", or asks to break a plan, spec, investigation, findings register, PR, or conversation into dependency-aware tracer-bullet work for Sergeant and td.
---

# To Tickets

Turn a plan, specification, investigation, findings register, PR, or current
conversation into implementation-ready td epics and tickets. Tickets are narrow,
complete tracer bullets with explicit ownership, acceptance criteria, and blocking
edges. Sergeant project configuration is the source of truth for repository scope.

## Principles

- Prefer vertical slices that produce independently verifiable behavior.
- Keep each ticket small enough for one fresh agent context.
- Assign exactly one owning repository to each implementation ticket.
- Represent cross-repository delivery with counterpart tickets and explicit merge
  order, not one ambiguous shared ticket.
- Use expand-migrate-contract for mechanical changes that cannot remain green as a
  vertical slice.
- Create epics for coherent programs, not as substitutes for executable tickets.
- Never duplicate an existing td task or GitHub issue.
- Preserve stable finding IDs such as `RBAC-P1-004` or `DATA-P0-002` in titles.
- A ticket is not ready unless its acceptance criteria are observable and its
  blockers are accurate.

## 1. Load Project Context

When operating through Sergeant:

1. Run `sgt-list` if the project name is not already established.
2. Run `sgt-context <project>`.
3. Run `sgt-td-list <project> --all --json` to deduplicate against every status.
4. For architecture or codebase questions, use the existing graphify graph before
   reading files individually.
5. Read any referenced issue, PR, specification, ADR, or findings register in full.

If an owning repository has no td database, initialize it only after confirming it
is a real project repository:

```bash
td init --work-dir /absolute/repo/path
```

Do not automatically add td instructions to repository guidance files.

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

## 5. Publish to td

Create local epics first so child tickets can reference real IDs:

```bash
td create "<epic title>" \
  --type epic \
  --priority P1 \
  --labels <comma-separated-labels> \
  --description "<scope and cross-repo counterparts>" \
  --acceptance "<epic completion gate>" \
  --json
```

Create tickets in dependency order, blockers first:

```bash
td create "<ticket title>" \
  --type feature \
  --priority P1 \
  --parent <local-epic-id> \
  --description "<what this vertical slice delivers>" \
  --acceptance "<observable criteria>" \
  --depends-on <local-blocker-id> \
  --json
```

For an existing task, update rather than duplicate it:

```bash
td update <id> --parent <epic-id>
td log <id> "Preserved branch/PR/worktree and cross-repo counterpart details"
```

Use `sgt-td-create` when one approved logical outcome needs matching task records in
several registered repositories. Then add repository-specific details with `td log`.

td dependencies are repository-local. For cross-repository blockers:

- Record the counterpart repo and td ID in both descriptions or logs.
- State the exact merge order.
- Do not invent a native dependency edge that td cannot enforce across databases.

Do not mark tasks `in_progress`; dispatch or a worker does that. New published tasks
remain `open` until work begins.

## 6. Validate the Graph

After publishing:

1. Run `sgt-td-list <project>` by priority.
2. Run `td epic list` in every owning repository.
3. Confirm each ticket has one parent epic.
4. Confirm every dependency points in the correct direction.
5. Confirm no circular or cross-repo pseudo-dependencies exist.
6. Confirm preserved branches, PRs, and worktrees are logged.
7. Close stale duplicates only with an explicit superseding task:

```bash
td close <duplicate-id> --admin "Superseded by <canonical-id>"
```

## 7. Report the Dispatch Frontier

Return:

- Epic IDs grouped by repository.
- Ticket IDs grouped by priority and dependency wave.
- The **frontier**: tickets with no unfinished blockers.
- Recommended concurrency: one worker per owning repository unless the project
  explicitly supports more.
- Exact dispatch commands for the next wave:

```bash
sgt-dispatch <project> --td <ticket-id>
```

Do not dispatch unless the user asked to begin implementation.

## Ticket Quality Checklist

Before publishing each ticket, verify:

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

## Output Template After Publishing

```markdown
**Epics**
- `<repo>` `<epic-id>`: <title>

**Frontier**
- `<repo>` `<ticket-id>`: <title>

**Next Dispatch**
`sgt-dispatch <project> --td <ticket-id>`
```
