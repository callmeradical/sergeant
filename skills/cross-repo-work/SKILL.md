# Skill: cross-repo-work

Decompose a requested outcome across owning repositories and define dependency and
merge order before dispatch.

## When to use

Load this skill when `sgt-context` shows that more than one repository owns the
requested outcome. Do not use it merely because a project contains multiple repos.

Prerequisite: `load-project` has resolved repository paths, roles, groups, and
instructions.

## Decomposition procedure

### 1. Assign repository ownership

For each required behavior, name exactly one repository that owns its
implementation. Include a repository only when it must change or produce delivery
evidence.

Record:

```text
repo: <name>
role: <resolved role>
delivers: <observable behavior or artifact>
acceptance: <repo-native command/evidence proving completion>
```

If ownership is ambiguous, use the project graph and existing contracts. Ask the
user only when two repositories could legitimately own a user-visible or durable
contract.

### 2. Define dependency order

Create edges only when one repository's merged or deployed result is required by
another. Use `prerequisite>dependent` notation accepted by `sgt-dispatch`.

Common evidence:

- contract/schema producer before consumers;
- infrastructure/config before runtime that requires it;
- independent implementations in parallel when an approved contract already
  exists;
- deployment dependency recorded separately from code merge dependency.

Reject cycles before dispatch. If a cycle reflects a coupled contract, define the
contract artifact or compatibility phase that breaks the cycle.

### 3. Inspect repository state

Run `sgt-status <project>` and record non-main branches, uncommitted changes,
behind/ahead state, active worktrees, and preserved workers for owning repos.

Do not stash, reset, switch, or clean repository state during planning. Route an
existing canonical branch/worktree to the worker brief, or stop for a decision when
state conflicts with the requested outcome.

### 4. Define per-repository delivery gates

Each repository brief must include:

- owning td task or creation requirement;
- fixed point and preserved source state;
- repository-specific tests, lint, typecheck, and build commands;
- Standards and Spec review sources;
- PR dependency and deployment order;
- data/security/destructive decisions already approved or still missing.

The plan is complete when every owning repository has one implementation brief,
acceptance evidence, and an acyclic dependency position.

### 5. Hand off to dispatch

If the user requested planning only, stop after returning the repository briefs,
acceptance evidence, and dependency graph. Do not dispatch or edit repositories.

When the user requested implementation, load `dispatch` and execute through
`sgt-dispatch`; the primary session must not edit several repositories directly.

After workers finish, reconcile:

1. PR URLs and final heads;
2. required CI and unresolved review threads;
3. merge order from dependency edges;
4. deployment order and cross-repo release notes;
5. terminal td/fleet state and cleanup eligibility.

Do not report the cross-repo outcome complete until every owning repository has a
terminal result or an explicit preserved blocker.
