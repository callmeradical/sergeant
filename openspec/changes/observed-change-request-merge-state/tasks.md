# Tasks — Observed change-request merge state

One repository, `sergeant-v2`. Task order matters: 2-4 depend on 1; 5
depends on 2-4 all landing.

## Task 1 — The provider seam and its GitHub implementation

Repository: `sergeant-v2`. Depends on: nothing.

Read first: this change's `design.md` in full; `internal/export/export.go`
and `internal/export/registry.go` (the exact pattern this package
mirrors); `internal/ui/gitutil.go`'s `resolveGitRemoteURL` (the existing
GitHub-URL recognition this extends); `internal/ui/server.go`'s current
`runGHPRCreate` (the exact `gh pr create` invocation shape to match, plus
`--base`).

Build:
- New `internal/changerequest/changerequest.go`: `Provider`, `StatusResult`,
  `Providers`, `DetectProvider` — exactly as design.md specifies.
- New `internal/changerequest/github.go`: `githubProvider`, registered via
  `init()`.

Verification: `go build ./... && go vet ./internal/... && go test
./internal/... -count=1 -skip
'^(TestBuildProjectGraphAppliesExcludePatterns|TestBuildProjectGraphMergesEveryParticipatingRepo|TestIncludeGroupsExcludesNonMatchingRepos|TestBuildNeverLeavesOutputInAPartialState|TestPublishFailureRestoresPriorGraph|TestBuildNeverSpawnsSgtGraphify|TestQueryAgainstABuiltGraphReturnsAnAnswer|TestExplainAndAffectedAreDistinctFromQuery|TestMCPGraphQueryAgainstABuiltGraphReturnsAnswer|TestBuildGraphEndpointBuildsAndPublishes)$'`.

Scenarios needing direct test coverage:
- `DetectProvider` returns `"github"` for both `git@github.com:owner/repo.git`
  and `https://github.com/owner/repo` forms.
- `DetectProvider` returns a clear error naming the host for a non-GitHub
  remote (e.g. `git@gitlab.com:owner/repo.git`) and for a bare/unrecognized
  URL.
- `Providers["github"]` is actually registered (a test importing the
  package and reading the map, not just trusting `init()` ran — this
  codebase has a known recurring "implemented but never wired up" bug
  class).

## Task 2 — Record and use the real base branch

Repository: `sergeant-v2`. Depends on: nothing (independent of Task 1).

Read first: `internal/dag/engine.go`'s `prepareWorktree` (line 127) in
full; `internal/ui/gitutil.go`'s `defaultBase`; `internal/ui/delivery.go`
line 67, its one call site.

Build:
- Add `base_branch` to `migrateAddColumns`, `RunRecord`, `runColumns`, and
  every scan/insert site that already lists every other run column.
- Add `Store.SetRunBaseBranch`.
- Wire the capture-once-per-run logic into `prepareWorktree`, exactly per
  design.md's guard (`if run.BaseBranch == ""`).
- Change `defaultBase`'s signature to accept and prefer a recorded value;
  update `delivery.go`'s call site to pass `run.BaseBranch`.

Verification: same command as Task 1.

Scenarios needing direct test coverage:
- A run's first worktree creation records the source repo's actual
  checked-out branch as `BaseBranch`.
- A resumed run (worktree removed, branch survives) does NOT overwrite an
  already-recorded `BaseBranch`, even if the source repo's checked-out
  branch has since changed.
- `defaultBase` returns the recorded value immediately when one is present,
  without shelling out to git at all (assert via a directory argument that
  is not even a git repo — if `defaultBase` tried its old fallback chain
  against it, that would itself error/hang, proving the recorded value
  short-circuited it).
- A run with no recorded `BaseBranch` (predates this change) still gets an
  answer from `defaultBase`'s existing fallback chain, unchanged.

## Task 3 — Persist the change request onto the bullet; refuse unrecognized hosts

Repository: `sergeant-v2`. Depends on: Task 1 (the provider seam) and
Task 2 (`run.BaseBranch` to pass as the create call's base).

Read first: `internal/ui/server.go`'s current `handleCreatePR` in full,
including its existing envelope-recording; `internal/store/store.go`'s
`SealBulletForRun` and `UpdateBulletStatus` (the setter pattern
`SetBulletPRURL` follows).

Build:
- Add `Store.SetBulletPRURL(bulletID, url string) error`.
- Rewrite `handleCreatePR` exactly per design.md: resolve the raw remote,
  detect the provider, refuse with a 400 naming the host on an
  unrecognized one, call `Provider.Create` with `run.BaseBranch`, persist
  the URL onto the bullet on success.
- Remove `Server.GHPRCreate` and `runGHPRCreate`; update every existing
  test that swapped `Server.GHPRCreate` for a stub to instead swap
  `changerequest.Providers["github"]` for a fake `Provider`.

Verification: same command as Task 1.

Scenarios needing direct test coverage:
- A successful seal+create against a GitHub remote persists the change
  request's URL onto the bullet (`GetBullet` afterward reports it), not
  only into an envelope.
- The created change request's `Create` call receives the run's recorded
  `BaseBranch` as its base argument.
- A repo whose remote is not GitHub is refused with a clear error naming
  the detected host, and the bullet's `PRURL` remains empty (the seal
  itself, which already succeeded, is not reverted — this scenario proves
  only that no change request gets fabricated for an unsupported host).

## Task 4 — Observe merge status on pipeline-view activation

Repository: `sergeant-v2`. Depends on: Task 1 and Task 3 (a real `PRURL`
must exist on a bullet before there is anything to check).

Read first: `internal/ui/static/index.html`'s `selectRun` function in
full; `internal/store/store.go`'s `updateBulletStatusAndReason` (the
setter the blocked-on-mismatch path reuses) and `UpdateBulletStatus`.

Build:
- Add `handleCheckMergeStatus`, registered as `POST
  /api/check-merge-status?run_id=<id>`, exactly per design.md's contract
  (per-bullet independent error handling, merged-into-recorded-base ->
  `merged`, merged-into-other-base -> `blocked` with a reason naming both
  branches, not-yet-merged -> untouched).
- Wire `selectRun` to call it (awaited, before `renderWorkflowGraph`),
  exactly per design.md.

Verification: same command as Task 1, plus a manual check (no scripted
frontend test suite exists in this repo today): seal a bullet against a
real or faked GitHub remote, open its run in the dashboard, confirm the
Delivery lane reflects `merged` once the underlying PR is actually merged
— note this manual check in the PR description.

Scenarios needing direct test coverage:
- A sealed bullet whose recorded change request is observed merged into
  its run's recorded `BaseBranch` advances to `merged`.
- A sealed bullet whose recorded change request is observed merged into a
  *different* branch advances to `blocked`, with a reason naming both the
  expected and actual branch — not `merged`.
- A sealed bullet whose change request is observed still open is left
  untouched at `sealed`.
- A run with no sealed bullets (or no bullets at all) makes the endpoint a
  cheap no-op — no provider call attempted.
- One bullet's check failing (a provider error) does not prevent another
  bullet of the same run from being checked and correctly advanced.
