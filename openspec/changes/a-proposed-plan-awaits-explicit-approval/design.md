# Design — A proposed plan awaits explicit approval

## Ownership

One repository, `sergeant-v2`. Touches `internal/store/store.go` (new
bullet status, new listing method), `internal/ui/server.go`
(`handleDispatch`'s branch point, new endpoints), and reuses existing
change resolution (O3), worktree/run creation, and dispatch machinery
unchanged.

## Trigger: no explicit `repos`

`handleDispatch` already resolves `targetRepos := targetRepositories(proj,
req.Repos)` before any record is written. The gate is a single check
immediately after that resolution: if `len(req.Repos) == 0`, this
dispatch's decomposition was not stated by the caller and must be proposed,
not executed. If `len(req.Repos) > 0`, nothing about the existing path
changes.

OpenSpec change resolution (O3) still happens before this check, exactly as
today — O3's requirement is "before any worktree is created," and a
proposed plan creates no worktree either way. The human reviewing a
proposed plan can already see which change/spec will govern the work.

## Data model

- `store.BulletStatuses()` gains `"proposed"`, ordered first (before
  `pending`): a bullet that exists as part of a plan awaiting approval,
  naming a repository but not authorized to start.
- `IntentRecord.Status` gets real use of the already-documented,
  never-written `"proposed"` value.
- No new table. A proposed plan is an intent + bullets like any other; only
  their status differs.

## The proposed-plan path

When the trigger fires, `handleDispatch`:

1. Resolves the change exactly as today (O3, unchanged).
2. Creates the intent with `Status: "proposed"` (no `RunRecord` is created
   in this path at all — there is no run yet).
3. Creates one bullet per resolved repository with `Status: "proposed"`,
   same `Position` ordering as today.
4. Responds `202 Accepted` with the intent id and its bullets. It does not
   call the worktree/branch/dispatch sequence.

```go
if len(req.Repos) == 0 {
    intentID := naming.RunID() + "-intent" // same generator already used for run-derived intent ids
    if err := srv.Store.CreateIntent(&store.IntentRecord{
        ID: intentID, Project: proj.Name, Statement: brief, Status: "proposed",
    }); err != nil { ... }
    for i, repoName := range targetRepos {
        _ = srv.Store.CreateBullet(&store.BulletRecord{
            ID: fmt.Sprintf("%s-b%d", intentID, i+1), IntentID: intentID,
            Repo: repoName, Position: i + 1, Status: "proposed",
        })
    }
    writeJSON(w, http.StatusAccepted, map[string]interface{}{
        "intent_id": intentID, "status": "proposed", "repos": targetRepos,
    })
    return
}
```

## Approval reuses the existing dispatch sequence, not a copy of it

`handleDispatch`'s remaining body — creating the `RunRecord`, the
per-bullet worktrees/branches, and launching `executeRun` — must be
extracted into an internal function taking `(proj, brief, targetRepos,
change, requestID)` (the values already available at that point in
`handleDispatch` today). `handleDispatch`'s explicit-repos path calls it
immediately, exactly as today; the new approval endpoint calls the same
function after transitioning a proposed intent's status. This is a
refactor of existing code into a shared call, not a second
implementation — a divergence between the two paths (e.g. one setting a
field the other forgets) is exactly the class of bug this structure
prevents.

## `POST /api/plans/{intent_id}/approve`

1. Load the intent; 404 if it does not exist.
2. If already `"in_progress"` or beyond: return the existing state
   unchanged (idempotent — a repeat is not an error).
3. If not `"proposed"`: refuse (409) — most concretely, an intent already
   `"abandoned"` cannot be approved after the fact.
4. Otherwise: transition the intent to `"in_progress"`, every one of its
   bullets from `"proposed"` to `"pending"`, and call the shared dispatch
   function from above using the intent's existing bullets' repos (in
   their recorded `Position` order) as `targetRepos`.

## `POST /api/plans/{intent_id}/reject`

1. Load the intent; 404 if it does not exist.
2. If already `"abandoned"`: return the existing state unchanged
   (idempotent).
3. If not `"proposed"`: refuse (409).
4. Otherwise: transition the intent to `"abandoned"`. Bullets are left at
   `"proposed"` — the intent's terminal `"abandoned"` status is what makes
   them inert; no bullet-level rejected status is introduced (mirrors this
   project's precedent of not inventing a parallel state where an existing
   field already carries the fact — see `sealed`'s reuse of the bullet
   lifecycle rather than a new approval table).

## `GET /api/plans`

Lists intents with `Status: "proposed"`, each with its bullets — the
listing a human reviews before deciding. Requires a new store method,
`ListIntentsByStatus(status string) ([]IntentRecord, error)`, following the
same shape as the existing `ListBulletsForIntent`.

`GET /api/bullets` (added by R3.5) is extended to accept `intent_id` as an
alternative to `run_id` in its query string — a proposed plan has no run to
key off of yet, and this is the same bullet-listing behavior the dashboard
already needs, not a new concept.

## Rejected alternatives

**A separate `PlanRecord`/`ProposedBullet` table instead of reusing
Intent/Bullet.** Rejected: D4 already makes intent/bullet sergeant's
first-class planning record, and D8 makes the intent the dashboard's
primary noun. A parallel table would give the dashboard two different
things to reconcile before and after approval, for what is the same
underlying plan.

**Duplicating the dispatch sequence into the approval handler.** Rejected:
guarantees the two paths drift. Extracting a shared function is mechanical
and removes the risk entirely.

**Editing a proposed plan's repository list before approving.** Rejected
by the proposal as out of scope; approval is binary.
