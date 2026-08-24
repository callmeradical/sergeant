# Proposal — Automated fleet cleanup

## Repository

One repository: `sergeant-v2`.

## Requirements served

PRD: `docs/prd-automated-fleet-cleanup.md`.

## Problem

`POST /api/clean-worktrees` (`internal/ui/server.go`) already reclaims a
terminal run's fleet worktree safely — it refuses a still-`running` run
and refuses (without `force`) a worktree with uncommitted changes. Nothing
ever calls it automatically. An operator who does not think to invoke it
accumulates fleet directories under
`~/.local/share/sergeant-v2/fleet/<run-id>/` indefinitely, for runs that
finished — or died — days or weeks ago.

## Proposal

Add a background process, running for the lifetime of the server, that
periodically finds runs whose status has been terminal (`passed`, `failed`,
`cancelled`, `interrupted`) for longer than a fixed seven-day retention
window and reclaims their fleet worktrees — reusing the exact same
running-check and dirty-worktree-check `handleCleanWorktrees` already
applies, not a relaxed version of them. This is a scheduling change, not a
new safety model: anything the manual endpoint would refuse to remove
today, the automatic pass also refuses.

The manual endpoint's own run-status lookup only considers the 200 most
recent runs (`ListRecentRuns(200)`), which is adequate for asking "is this
specific run still running" about something recent but not for
identifying every terminal run older than seven days out of the full
history. A store query scoped to exactly that question — terminal status,
`updated_at` older than the cutoff — replaces relying on the recent-runs
window for the automatic path.

## Out of scope

- **Database row retention/deletion.** Only the on-disk fleet worktree is
  reclaimed; run/phase/envelope/intent/bullet rows are untouched. Database
  retention remains R4.4's already-disclosed, still-open decision.
- **A configurable retention period or schedule.** Seven days and the scan
  interval are fixed constants.
- **Any change to `handleCleanWorktrees`'s existing manual behavior or its
  200-recent-runs lookup for the on-demand path.** The new store query is
  additive, used only by the automatic pass.
- **A dashboard view or notification of what automatic cleanup did.**
