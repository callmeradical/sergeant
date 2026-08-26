# Proposal — Observed change-request merge state

## Repository

One repository: `sergeant-v2`. Standalone.

## Requirements served

`docs/prd-observed-change-request-merge-state.md` (full text). Extends D6
("Sergeant never merges anything itself") and D8/R7.5 (the dashboard
renders a bullet's real lifecycle position).

## Problem

A bullet's lifecycle dead-ends at `sealed` today, for four connected
reasons: `handleCreatePR` never persists the PR URL it computes onto the
bullet (`BulletRecord.PRURL` is always empty in practice); `runGHPRCreate`
never names a `--base`, so `gh` silently targets GitHub's configured
default branch (`main` for this repo, not `v2`); nothing anywhere ever
observes a PR's real merge state and writes `merged` to a bullet
(`store.go`'s own comment on `AllBulletsSealedOrMerged` says so plainly);
and all of the above is written directly against GitHub's `gh` CLI with no
seam for a different host.

## Proposal

- **Record each run's actual base branch** at worktree-creation time —
  `git rev-parse --abbrev-ref HEAD` in the source repo path, captured once,
  before `git worktree add` runs, never re-derived later by guessing.
- **A small provider seam**, mirroring `internal/export`'s existing
  `Target`/`Backends` pattern (built for the directly analogous
  `task-tracking-is-a-readonly-export` problem): a `changerequest.Provider`
  interface with a create method and a status method, a registry keyed by
  detected provider name, and one shipped implementation (`"github"`, via
  `gh`) that registers itself into it.
- **The provider is detected by parsing the repository's remote URL** —
  extending `internal/ui/gitutil.go`'s existing `resolveGitRemoteURL`
  recognition. For v1, only the literal host `github.com` (SSH and HTTPS
  forms) resolves to the GitHub provider; anything else is refused clearly
  by name, at the point sealing is attempted.
- **Sealing opens a change request against the recorded base branch**
  through the provider seam, and **persists the change request's URL onto
  the bullet** (`BulletRecord.PRURL`, which already has read/write plumbing
  but nothing writes to it today).
- **`defaultBase()`/delivery's commit-count reporting uses the same
  recorded base branch** instead of its own independent `origin/HEAD`
  guess.
- **Merge state is checked when a run's pipeline view is activated** — the
  frontend's `selectRun` function — not on a background timer. For every
  `sealed` bullet of the selected run with a recorded PR URL, the dashboard
  triggers a real status check through the provider seam.
- **An observed merge into the recorded base branch advances the bullet to
  `merged`.** An observed merge into any *other* base is flagged as a
  failure instead — the bullet moves to `blocked` with a reason naming both
  branches, never silently treated as a successful delivery and never left
  at `sealed` as if nothing happened.
- Sergeant still never merges anything itself — this is read-only
  observation of what already happened on the host.

## Out of scope

- A second provider implementation (GitLab, Bitbucket, bare-git). Detecting
  one and refusing it clearly is in scope; talking to it is not.
- A PR/change-request closed without merging (stays `sealed`).
- Automatic retry of a failed change-request-creation call.
- A project-level override of the recorded base branch.
- GitHub Enterprise custom-domain recognition (v1 recognizes literal
  `github.com` only).
