# Proposal — A proposed plan awaits explicit approval

## Repository

One repository: `sergeant-v2`.

## Requirements served

**D5(a)**: "A human is notified when an inferred plan awaits approval."

**D2**: "Inferred decomposition produces a *proposed* plan requiring
explicit human approval before any worktree is created."

PRD: `docs/prd-plan-approval-and-blocked-bullets.md` ("Plan approval"
section).

## Problem

`handleDispatch` (`internal/ui/server.go`) resolves target repositories via
`targetRepositories`: the caller's explicit list, or — when the caller
supplies none — every repository in the project, sorted by name. Either
way, the intent is created already `"in_progress"` and its bullets already
`"pending"` in the same request, and dispatch begins immediately. There is
no branch anywhere in this path that produces a *proposed* plan, and no
approval gate before a worktree is created.

This directly contradicts D2: a decomposition the caller did not state
explicitly — the literal case D2 calls "inferred" — is exactly what must
require approval first. Today it silently defaults to "every repository in
the project" and starts working immediately. A caller who forgets to pass
`repos` dispatches against their entire project with no confirmation at
all.

## Proposal

When, and only when, a dispatch request names no explicit, non-empty
`repos` list, create the intent with status `proposed` and one bullet per
resolved repository, also `proposed`, and stop there: no run, no worktree,
no branch, no agent process. Add a way to list plans awaiting approval, and
a way to explicitly approve (which starts exactly the dispatch sequence an
explicit-repos request already runs today, for the same resolved bullets)
or reject (which ends the plan and starts nothing) one.

An explicit-repos dispatch is never gated by this — it is what D2 calls
workflow-defined decomposition, already trusted, and its behavior does not
change.

## Out of scope

- **Inferring a decomposition intelligently** (a model proposing which
  repositories/bullets a brief implies). This proposal gates the one
  non-explicit path that exists today — defaulting to every project
  repository — and does not build a smarter proposal mechanism. A future
  inference mechanism would produce the same `proposed` state this
  proposal defines; it does not need to change this proposal to be added
  later.
- **Editing a proposed plan before deciding on it** (dropping one repo,
  reordering bullets). The decision is binary: approve exactly what was
  proposed, or reject it entirely.
- **Push notifications** (email, Slack, desktop) for a pending plan.
  Dashboard-listable and inspectable satisfies D5's "a human is notified,"
  matching this project's established precedent (R5.6's delivery
  history/quarantine surface is dashboard visibility, not a delivery
  channel).
- **Any change to bullet status values beyond adding `proposed`.** The
  existing `pending -> red -> green -> sealed -> merged` progression and
  `failed` are untouched.
