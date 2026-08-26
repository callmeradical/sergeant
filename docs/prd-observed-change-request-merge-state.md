# Product Requirements: Observed Change-Request Merge State

Status: Draft, awaiting explicit human PRD approval

Extends: `docs/prd-sergeant-v2.md` D6 ("Sergeant never merges anything
itself") and D8/R7.5 (the dashboard's Delivery lane renders a bullet's real
lifecycle position). `BulletProgression`'s own ordering
(`pending -> red -> green -> sealed -> merged`) has named `merged` since v2's
start; this PRD is what actually reaches it.

## Summary

A bullet's lifecycle currently dead-ends at `sealed`. Investigating why
surfaced three concrete, connected gaps, not one:

1. **No code path ever writes `PRURL` onto a bullet.** `handleCreatePR`
   computes a PR URL after calling `gh pr create` and records it in an
   envelope, but never calls anything to persist it onto the bullet itself —
   `BulletRecord.PRURL` has full read/write plumbing and is always empty in
   practice.
2. **`gh pr create` never names a base branch.** `runGHPRCreate` passes
   `--head` but no `--base`, so `gh` silently targets the repository's
   GitHub-configured default branch — confirmed, for this repo, to be
   `main`, not `v2`, the branch every dispatch this session has actually
   targeted.
3. **Nothing observes a PR's real merge state.** `store.go`'s own comment on
   `AllBulletsSealedOrMerged` says it plainly: no code path anywhere writes
   `merged` to a bullet. `DeriveIntentStatus`, which decides whether an
   intent is `satisfied`, requires every bullet to be `merged` — so no
   intent has ever reached `satisfied` through this mechanism, for any
   project, ever.
4. **Every one of the above is hardcoded to GitHub via the `gh` CLI.**
   `Server.GHPRCreate` is named and typed for GitHub specifically. Sergeant's
   domain model (intent/bullet/PR/merge) has nothing GitHub-specific about
   it — a bullet is "sealed" by opening a change request and "merged" by
   observing it land, regardless of which host the repository's remote
   actually is.

## Problem

Decision D6 makes `merged` observable-only, by design — sergeant must never
merge anything itself. But "observable" requires something that actually
looks, and today nothing does. Separately, `defaultBase()`
(`internal/ui/gitutil.go`) — used by delivery's commit-count reporting — has
the same "guess the base via `origin/HEAD`, fall back to `main`" problem as
`gh pr create`'s missing `--base`: both guess a branch instead of using the
one a run's worktree actually branched from, and today that guess is wrong
for this project.

Compounding this, the one existing PR-creation path is written directly
against GitHub's `gh` CLI, with no seam between "seal a bullet by opening a
change request" and "specifically, run this GitHub CLI command." Building
real merge-observation on top of that as-is would bake the GitHub coupling
in twice — once for creation, once for observation — making a future
non-GitHub host (GitLab, Bitbucket, a bare git remote with no forge at all)
a rewrite instead of a second implementation of an existing seam.

## Proposal

- **Record each run's actual base branch** at the moment its worktree is
  created — the branch the source repository was checked out on at that
  instant, captured directly (`git rev-parse --abbrev-ref HEAD` in the
  source repo path, before `git worktree add` runs), not re-derived later
  by inspecting `origin/HEAD` or any other guess. Stored durably on the run.
  This part is git-native — every git host has branches and a worktree's
  real ancestor commit — and has nothing host-specific about it.
- **Sealing a bullet opens a change request against that recorded branch**,
  through a host-abstracted seam rather than a direct `gh` invocation: one
  interface for "open a change request for this branch, targeting this
  base, and return its identity/URL", with GitHub-via-`gh` as the only
  implementation this PRD ships. The seam exists so a repository on a
  different host is a second implementation later, not a redesign of
  sealing itself.
- **The provider is detected by parsing the repository's own git remote
  URL, not configured.** `internal/ui/gitutil.go` already resolves
  `remote.origin.url` and recognizes a GitHub remote (`resolveGitRemoteURL`);
  this proposal extends that same URL-parsing detection — matching the
  remote's host — to select which host implementation a repo's
  seal/observe calls go through. For v1, "GitHub" means the literal host
  `github.com` only (both `git@github.com:` and `https://github.com/`
  forms) — no GitHub Enterprise allowlist, no other configuration. A repo
  whose remote resolves to a recognized provider with a shipped
  implementation (GitHub, here) uses it automatically — no per-project
  provider setting. A repo whose remote resolves to an unrecognized or
  unimplemented host (including a GitHub Enterprise custom domain, for
  now) is refused clearly at the point sealing is attempted (an actionable
  error naming the detected remote), never silently attempted against the
  wrong provider's CLI/API and never silently skipped.
- **The seam mirrors `internal/export`'s existing `Target`/`Backends`
  pattern** (built for the directly analogous
  `task-tracking-is-a-readonly-export` problem), rather than extending the
  raw swappable-func-field style `Server.GHPRCreate` uses today: a small
  interface (e.g. a `ChangeRequestProvider` with a create-change-request
  method and a check-merge-status method), defined in the consumer's own
  package per `export.Target`'s own stated reasoning ("a future backend
  package imports export and implements Target, not the reverse"), plus a
  registry keyed by detected provider name that the GitHub implementation
  registers itself into. This structurally couples "create" and "check
  status" to the same provider — two independent swappable func fields
  could drift out of sync (one wired to GitHub, one accidentally not); one
  registry entry per provider cannot.
- **The opened change request's identity is persisted onto the bullet**,
  not only recorded in an envelope, so later steps have something to check.
- **`defaultBase()`/delivery's commit-count reporting uses the same
  recorded base branch** instead of its own separate `origin/HEAD` guess —
  one source of truth for "what branch is this run's real base", not two
  independent guesses that can disagree. This is also git-native, not
  host-specific.
- **Merge state is checked on activation of a run's pipeline view, not on a
  background timer.** When an operator opens (or refreshes) a run's
  workflow-graph/pipeline detail view and that run has a bullet currently
  `sealed` with a recorded change-request identity, the dashboard triggers
  a real check through the host-abstracted seam — "has this change request
  landed?" — right then. An observed merge advances the bullet to `merged`
  immediately, which is also the first point `DeriveIntentStatus` can ever
  report `satisfied`. No standing background loop polls change requests
  nobody is currently looking at.
- **A change request observed merged into a base other than the one
  sergeant recorded is not treated as a normal merge.** It is flagged as a
  failure — the bullet moves to `blocked` (matching this codebase's
  existing "a stuck bullet is blocked, not failed" precedent) with a
  `BlockedReason` naming both the expected and the actual base — never
  silently advanced to `merged`, and never left sitting at `sealed` as if
  nothing happened. This is a real anomaly (a human merged it somewhere
  sergeant did not expect) that needs a human to look at, not evidence the
  delivery succeeded as planned.
- Sergeant still never merges anything itself — this mechanism only reads
  state that already happened on the host.

## Out of scope

- **A second host implementation (GitLab, Bitbucket, bare-git, etc.).**
  This PRD establishes the seam and ships exactly one implementation behind
  it (GitHub via `gh`, matching what this repository and every project
  configured so far actually uses). Adding another host is future work the
  seam is deliberately shaped to make possible, not something this PRD
  builds. Detecting that a remote is, say, GitLab is in scope (so sergeant
  can refuse correctly by name instead of guessing); actually talking to
  GitLab's API/CLI is not.
- **A PR/change-request closed without merging.** This PRD only adds an
  observed path to `merged`; a rejected/closed-without-merge case is a
  distinct future question, not answered here. Such a bullet simply stays
  `sealed`.
- **Retrying or fixing a failed change-request-creation call automatically.**
  Error handling for creation itself is unchanged.
- **Any project-level configuration to override the recorded base branch.**
  The recorded, worktree-derived base is authoritative; an operator override
  is a possible future addition, not required here — no design considered
  in this PRD depends on one existing.
- **Changing GitHub's own configured default branch for this or any repo.**
  Not sergeant's concern; this PRD makes sergeant stop depending on it.

## Open questions

None remaining at the product level. Exact method signatures, package
names, and registry wiring are OpenSpec `design.md`'s job, not a product
decision this PRD needs to make.
