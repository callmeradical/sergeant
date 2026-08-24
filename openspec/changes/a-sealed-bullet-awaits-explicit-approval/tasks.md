# Tasks — A sealed bullet awaits explicit approval

One repository, `sergeant-v2`, so one task.

## Task 1 — seal on approval, refuse otherwise, make it inspectable

Repository: `sergeant-v2`. Depends on: nothing. Reuses existing
`Store.GetRun`, `Store.ListBulletsForIntent`, `Store.UpdateBulletStatus` —
read them first so the new method matches existing error-handling and
naming conventions in `internal/store/store.go`.

- Add `Store.SealBulletForRun(runID, repo string) error` to
  `internal/store/store.go` exactly as specified in design.md: resolve the
  run's intent via `GetRun`, find the ONE bullet in that intent whose `Repo`
  matches (not every bullet of the intent — a bullet is scoped to one repo),
  refuse with an error naming the bullet's actual status unless it is
  currently `"green"`, otherwise call `UpdateBulletStatus(bullet.ID,
  "sealed")`. Refuse (with an error, write nothing) if the run has no
  intent id, or if no bullet matches the repo.
- In `internal/ui/server.go`'s `handleCreatePR`, call
  `srv.Store.SealBulletForRun(req.RunID, req.Repo)` immediately after
  decoding and validating the request body, BEFORE the existing
  `gh pr create` logic runs. On error, respond with the store's error
  message and HTTP 409, and do not proceed to attempt PR creation at all.
  On success, proceed with the existing logic unchanged.
- Add `GET /api/bullets` to `internal/ui/server.go`: reads `run_id` from the
  query string, 400 if missing; resolves the run's intent the same way
  `SealBulletForRun` does (if the run has no intent id, respond with an
  empty JSON array, not an error); returns
  `Store.ListBulletsForIntent(intentID)`'s result as JSON (empty array, not
  null, on zero bullets). Register the route alongside the other `/api/*`
  routes.
- Do not implement D5's interruptions (a) or (b). Do not add
  `UnsealBullet`. Do not add a dashboard UI element or a notification
  mechanism. Do not change how `merged` is set or what it means.

Verification: `go build ./... && go vet ./... && go test ./internal/... -count=1`.
Tests must cover every scenario in `specs/bullet-approval/spec.md`:
`SealBulletForRun` succeeds and transitions status for a green bullet;
refuses (no write) for a bullet in each of pending/red/sealed/failed;
affects only the one repo's bullet in a multi-repo intent, leaving siblings
unchanged; a real `POST /api/create-pr` request against a non-green bullet
is refused with 409 and does NOT invoke `gh pr create` (assert this the same
way this session has asserted "no subprocess invocation" elsewhere — a
recording wrapper or equivalent seam around the `gh` invocation, not just
checking the HTTP status); the same request against a green bullet succeeds
and the bullet becomes sealed afterward (verify via `GET /api/bullets`, not
by inspecting internal state directly, so the test also proves the listing
endpoint reflects the write); `GET /api/bullets` for a run with no intent id
returns `[]`, not an error or `null`. Exit status decides the outcome.
