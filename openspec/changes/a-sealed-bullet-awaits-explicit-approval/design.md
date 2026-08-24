# Design — A sealed bullet awaits explicit approval

## Ownership

One repository, `sergeant-v2`. Standalone. Touches `internal/store/store.go`
(new method, reusing `GetRun`, `ListBulletsForIntent`, `UpdateBulletStatus`,
all existing) and `internal/ui/server.go`'s `handleCreatePR`.

## `SealBulletForRun` is scoped to one bullet, not the whole intent

`AdvanceBulletsForRun` (existing, used for green/failed) deliberately
advances *every* bullet of a run's intent to the same status, because a
run's gate outcome (passed/failed) is a fact about that whole dispatch. Seal
is different: it records "a human approved delivery for this one repo,"
which `POST /api/create-pr` requests one repo at a time (`req.Repo`).
Reusing `AdvanceBulletsForRun`'s "every bullet in the intent" semantics for
seal would incorrectly seal sibling bullets in a multi-repo intent whose own
PRs were never created. `SealBulletForRun` therefore finds and updates
exactly one bullet:

```go
// SealBulletForRun marks the bullet for (the intent behind runID, repo) as
// sealed, refusing unless it is currently green. A bullet is scoped to
// exactly one repository, so unlike AdvanceBulletsForRun this updates one
// bullet, not every bullet of the run's intent — sealing records that a
// human approved THIS repo's delivery, not the run's gate outcome.
func (s *Store) SealBulletForRun(runID, repo string) error {
	run, err := s.GetRun(runID)
	if err != nil {
		return fmt.Errorf("loading run %q to seal its bullet: %w", runID, err)
	}
	if run.IntentID == "" {
		return fmt.Errorf("run %q has no intent; nothing to seal", runID)
	}
	bullets, err := s.ListBulletsForIntent(run.IntentID)
	if err != nil {
		return err
	}
	for _, b := range bullets {
		if b.Repo != repo {
			continue
		}
		if b.Status != "green" {
			return fmt.Errorf("bullet %q for repo %q is %q, not green — refusing to seal", b.ID, repo, b.Status)
		}
		return s.UpdateBulletStatus(b.ID, "sealed")
	}
	return fmt.Errorf("no bullet found for repo %q on intent %q", repo, run.IntentID)
}
```

## The guard runs before the PR action, not after

`handleCreatePR` currently: resolve project/repo → attempt `gh pr create` →
record an envelope. `SealBulletForRun` is called immediately after decoding
the request, before any `gh` invocation — a bullet that isn't green gets a
409 and `gh pr create` never runs. This is what makes approval "required"
rather than "possible": the action itself is gated, not merely logged after
the fact.

Sealing happens once, at the point of the actual `gh pr create` attempt —
whether that attempt succeeds in creating a live PR or falls back to the
existing "local branch, PR not opened" path (`prError != ""` in the current
code) does not change sealed's meaning: the human took the explicit delivery
action either way, which is the fact R3.5 asks to be recorded. If `gh pr
create` itself errors in a way that means nothing was staged at all, seal
still records that the human-triggered attempt happened; this proposal does
not need a finer-grained "attempted but totally failed" state, since retrying
`create-pr` for an already-sealed bullet is a separate, existing question
about idempotency this proposal does not change.

## `GET /api/bullets?run_id=`

Resolves the run's intent the same way `SealBulletForRun` does, returns
`ListBulletsForIntent`'s result as JSON (empty array, not null, for a run
with no intent — matching this project's established convention). Read-only,
no new write path.

## Rejected alternatives

**Sealing all of the intent's bullets, reusing `AdvanceBulletsForRun`.**
Rejected above — wrong for a per-repo action.

**A separate `Store.RecordApproval` audit table instead of reusing the
`sealed` bullet status.** The bullet lifecycle already has a slot for
exactly this fact (`sealed`, documented since `BulletStatuses` was written,
never populated) — using it is completing existing design, not inventing a
parallel one, the same reasoning that favored a `state` column over a new
table for quarantine in the R5.5 bullet.

**Guarding at PR-creation time only implicitly (skip creating the PR
silently for a non-green bullet, no error).** Rejected: R3.5 asks for
approval to be "explicit and required" — a silent no-op leaves the caller
unable to tell "this succeeded" from "this was quietly skipped," which is
the same category of problem R5.3 rejected for the store (writing malformed
input somewhere it's not visible moves the failure somewhere harder to
find).
