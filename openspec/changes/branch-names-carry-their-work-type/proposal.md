# Proposal — Branch names carry their work type

## Repository

One repository: `sergeant-v2`.

## Requirements served

**O2**: "Branch named `<type>/<change-id>` — convenience only. Preserves the
conventional-commit prefix already in use (`feat/`, `fix/`) while making the
branch machine-resolvable."

PRD: `docs/prd-branch-names-carry-their-work-type.md`.

## Problem

O2 already specifies dispatched branches should be named `<type>/<change-id>`.
Today every dispatched branch is named `sergeant/<run-id>` — no type, no
change id, an identifier that carries no information about what kind of work
it is or which OpenSpec change it belongs to.

Worse, this literal format string (`"sergeant/" + runID`) is independently
hand-duplicated in four places across three packages, not called from one
shared function everywhere it matters:

- `dag.BranchName(runID)` — the real source used by `prepareWorktree` when a
  worktree/branch is actually created.
- `internal/ui/server.go`'s `handleCreatePR` — recomputes the same string by
  hand to pass as `gh pr create --head <branch>`.
- `internal/mcp/server.go`'s `sergeant_seal_pr` tool — recomputes it again,
  independently, to call `DeliverPullRequest`.
- `internal/runner/runner.go`'s `DeliverPullRequest` — a fallback branch
  construction for when its caller passes an empty string (currently dead in
  practice: neither real caller does).

Any one of these left unchanged while the others adopt the new format would
silently point `gh pr create` at a branch name that does not match the one
actually created — a real, would-be-introduced bug, not merely a cosmetic
inconsistency.

## Proposal

A dispatch must state its work type — one of `feat`, `fix`, `refactor`,
`docs`, `chore`, `test` — before any run, intent, or worktree is created.
A dispatch naming an unrecognized or missing type is refused, the same way
an unresolvable OpenSpec change or an unsupported agent is refused today.

The type is recorded as a durable, queryable fact (not only baked into a
branch name), consistent with how this project already resolves and records
an OpenSpec change once and reuses it rather than re-deriving it.

The branch-name format itself becomes single-sourced — computed by exactly
one function every one of the four call sites above calls, so it cannot
drift out of sync with itself again.

## Out of scope

- **An analytics/reporting page.** This proposal makes the work type an
  honest, recorded fact; a view built on top of it is separate, later scope.
- **Reclassifying historical runs/branches.** Existing `sergeant/<run-id>`
  branches and already-recorded runs are untouched; this changes what gets
  recorded and named going forward only.
- **Enforcing the type vocabulary in commit messages.** Agents already tend
  to write conventional-commit-style commit messages on their own.
- **A type taxonomy beyond the fixed six**, or per-project customization of
  the vocabulary.
