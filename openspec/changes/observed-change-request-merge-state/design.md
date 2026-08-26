# Design — Observed change-request merge state

## Ownership

One repository, `sergeant-v2`. Touches `internal/store/store.go` (new
column, new bullet setter), `internal/dag/engine.go` (`prepareWorktree`),
a new `internal/changerequest` package, `internal/ui/gitutil.go`
(`defaultBase`), `internal/ui/server.go` (`handleCreatePR`, a new
handler), `internal/ui/delivery.go`, and `internal/ui/static/index.html`
(`selectRun`).

## `internal/changerequest` — the provider seam

New package, structured exactly like `internal/export`'s `Target`/
`Backends` split (`export.go` defines the interface the consumer needs;
`registry.go` defines the registry; a provider's own file registers into
it) — chosen over extending `Server.GHPRCreate`'s raw swappable-func-field
style specifically because it structurally couples "create" and "check
status" to one provider, where two independent func fields could drift.

```go
// internal/changerequest/changerequest.go
package changerequest

import "context"

// Provider is anything that can open a change request and report whether
// it has since merged. Defined here (the consumer) rather than in a
// provider's own package, per internal/export.Target's reasoning: a future
// provider imports this package and implements Provider, not the reverse.
type Provider interface {
	// Create opens a change request for head against base, returning its
	// URL. title/body are passed through as-is (already redacted by the
	// caller, same discipline runGHPRCreate's caller already applies).
	Create(ctx context.Context, repoPath, base, head, title, body string) (url string, err error)

	// Status reports whether the change request identified by url has
	// merged, and if so, which branch it actually merged into — the
	// caller (not this package) decides what a base mismatch means.
	Status(ctx context.Context, repoPath, url string) (*StatusResult, error)
}

// StatusResult is url's current state. Merged is false for every state
// except an actual merge; MergedIntoBranch is only meaningful when Merged
// is true.
type StatusResult struct {
	Merged           bool
	MergedIntoBranch string
}

// Providers is the process-wide registry of providers, keyed by the name
// DetectProvider returns. Ships with exactly one entry ("github"),
// registered by github.go's init — unlike export.Backends, which starts
// empty because no Target implementation existed yet at the time; here,
// one does.
var Providers = map[string]Provider{}

// DetectProvider parses remoteURL (as returned by a `git remote get-url`
// style command — not yet normalized to https://) and returns the
// registry key for its host, or an error naming the host when it is not
// recognized. v1 recognizes exactly the literal host github.com, both
// git@github.com: and https://github.com/ forms — no GitHub Enterprise
// allowlist, no configuration.
func DetectProvider(remoteURL string) (string, error)
```

```go
// internal/changerequest/github.go
package changerequest

import ( "context"; "os/exec"; "strings"; "encoding/json" )

func init() { Providers["github"] = &githubProvider{} }

type githubProvider struct{}

// Create shells out to `gh pr create --base base --head head --title
// title --body body`, matching runGHPRCreate's existing invocation shape
// exactly except for the added --base. cmd.Dir = repoPath.
func (g *githubProvider) Create(ctx context.Context, repoPath, base, head, title, body string) (string, error)

// Status shells out to `gh pr view url --json state,mergedAt,baseRefName`.
// state == "MERGED" means Merged; baseRefName is the branch it actually
// merged into.
func (g *githubProvider) Status(ctx context.Context, repoPath, url string) (*StatusResult, error)
```

## `internal/store/store.go` — recording the real base branch

Added to `migrateAddColumns`:

```go
{"runs", "base_branch", "ALTER TABLE runs ADD COLUMN base_branch TEXT NOT NULL DEFAULT ''"},
```

`RunRecord` gains `BaseBranch string`, added to `runColumns` and every
scan/insert site that already names every other run column (`scanRun`,
`CreateRun`'s insert). A new setter:

```go
// SetRunBaseBranch records the branch a run's worktree actually branched
// from. Callers are responsible for the "only once" contract (see
// engine.go below) — this method itself just writes what it is given.
func (s *Store) SetRunBaseBranch(runID, branch string) error
```

## `internal/dag/engine.go` — capturing it exactly once

`prepareWorktree` (line 127) already loads `run` via `e.Store.GetRun(runID)`
(line 144) before deciding whether to attach to an existing branch or
create a new one from `HEAD`. Immediately before the `git worktree add`
call (line 164), if `run.BaseBranch == ""`:

```go
if run.BaseBranch == "" {
	if head := gitOutput(ctx, repoPath, "rev-parse", "--abbrev-ref", "HEAD"); head != "" {
		_ = e.Store.SetRunBaseBranch(runID, head)
	}
}
```

The `run.BaseBranch == ""` guard is what makes this "captured once, ever,
per run": `prepareWorktree`'s own early-return (`os.Stat(wt) == nil` at
line 137) already skips this whole block on a run whose worktree already
exists, but a resumed run whose worktree was removed while its branch
survived reaches this code again — the guard stops that resume from
recapturing (and potentially getting a different, wrong answer if the
operator's own checkout has since moved on) what the run's first attempt
already correctly recorded. A failed `gitOutput` (empty string, e.g. a
detached HEAD) leaves `BaseBranch` empty rather than recording garbage;
`defaultBase()` below already has its own fallback for that case.

## `internal/ui/gitutil.go` — `defaultBase` prefers the recorded value

`defaultBase(dir string) string` becomes `defaultBase(dir, recorded string) string`:
if `recorded != ""`, return it immediately, skipping every guess. Its
existing `origin/HEAD`/`origin/main`/`main`/`master` fallback chain is
kept, unchanged, for the one caller that still needs a guess: a run
predating this change, whose `BaseBranch` column reads `""`.

`internal/ui/delivery.go:67`'s call site passes `run.BaseBranch` (already
in hand via the run it already loaded) as the new second argument.

## `internal/ui/server.go` — wiring `handleCreatePR`

Today (lines ~474-486): `srv.GHPRCreate(repoPath, req.Title, req.Body, branch)`
with no base, and the resulting URL is only ever written into an envelope,
never onto the bullet. Replaces to:

1. Resolve the raw remote (`git -C repoPath remote get-url origin`, the
   same command `resolveGitRemoteURL` already runs — refactor its `git
   config --get` call into a small shared helper both this and
   `resolveGitRemoteURL` call, rather than duplicating the `exec.Command`).
2. `providerName, err := changerequest.DetectProvider(rawRemote)`. An error
   here (unrecognized host) is a **400**, not a silent fallback to the old
   `local://worktree/...` placeholder path — sealing already succeeded
   (`SealBulletForRun` ran first, unchanged), so this refusal is reported
   back to the caller as "sealed, but no change request could be opened:
   <reason>", not reverted.
3. `provider := changerequest.Providers[providerName]`, then
   `url, err := provider.Create(ctx, repoPath, run.BaseBranch, branch, req.Title, req.Body)`.
4. On success, find the bullet `SealBulletForRun` just sealed (same
   repo/run lookup `SealBulletForRun` itself already does) and call a new
   `srv.Store.SetBulletPRURL(bulletID, url)`.
5. The existing envelope recording (`pr.staged`) is unchanged, still
   recording `url`/`branch`/`error` — this is evidence of the action, not
   the bullet's own durable field, and both should agree.

`Server.GHPRCreate` and `runGHPRCreate` are removed — `changerequest`'s
GitHub provider is the one and only path that shells out to `gh pr
create` now. Existing tests that swap `Server.GHPRCreate` for a recording
stub are updated to swap `changerequest.Providers["github"]` for a fake
`Provider` instead (same "swap the thing with real side effects" pattern,
one seam earlier).

## `internal/ui/server.go` / a new handler — checking merge status

```go
// handleCheckMergeStatus is called when a run's pipeline view is
// activated (index.html's selectRun), not on any timer. For every sealed
// bullet of the named run with a non-empty PRURL, it checks the real
// status through the provider seam and advances the bullet:
//   - merged into the run's recorded BaseBranch -> "merged"
//   - merged into any other branch -> "blocked", reason naming both
//   - not merged -> untouched
// A provider-detection failure or a Status call failure for one bullet
// does not stop the others from being checked; each bullet's own error
// (if any) is reported in the response, never silently swallowed.
func (srv *Server) handleCheckMergeStatus(w http.ResponseWriter, r *http.Request)
```

Registered as `POST /api/check-merge-status?run_id=<id>` alongside the
existing route block.

## `internal/ui/static/index.html` — triggering it from `selectRun`

`selectRun(runId)` (currently calling `renderProgressPanel()` and, further
down, fetching phases before calling `renderWorkflowGraph`) gains one more
`fetch('/api/check-merge-status?run_id=' + encodeURIComponent(runId), {method:'POST'})`,
fired and awaited before `renderWorkflowGraph` is called, so a just-observed
`merged`/`blocked` transition is reflected in the very first render rather
than requiring a second click. Failure of this call (network error, no
sealed bullets to check) never blocks the rest of `selectRun` — it is
exactly as best-effort as `bulletsForRun`'s own existing failure handling.

## Rejected alternatives

**A background loop, mirroring `fleetCleaner`/`retentionRotator`.**
Rejected per the PRD's own explicit decision: checking a change request's
status is a real network call to an external host for every sealed
bullet; a standing timer would make that call on a fixed schedule
regardless of whether an operator is looking, for every project, forever.
Tying it to pipeline-view activation means the check only ever runs for a
run someone is actually looking at, at the moment they want to know.

**Storing which provider handled a bullet's change request as a new bullet
column.** Rejected: the provider is a pure function of the repository's
remote URL, which does not change between sealing and checking status (and
if it somehow did, the operator changed something more fundamental than
this feature should silently paper over). Re-running `DetectProvider` at
check time is one cheap function call, not worth a schema column to avoid.

**Extending `Server.GHPRCreate`'s existing swappable-func-field pattern
instead of a new package.** Rejected per proposal.md: it does not
structurally prevent "create" and "status check" from being wired to two
different providers by mistake, which a registry keyed by one detected
name does.
