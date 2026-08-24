# Design — Automated fleet cleanup

## Ownership

One repository, `sergeant-v2`. Touches `internal/store/store.go` (a new
query for cleanup-eligible runs), `internal/ui/server.go` (extracting
`handleCleanWorktrees`'s reclaim logic into a function both the HTTP
handler and the new background loop call), and `cmd/sergeant/main.go` (or
wherever the server is started — starting the background loop alongside
the server).

## Eligibility query

A run is eligible for automatic reclaim when its status is one of
`passed`, `failed`, `cancelled`, `interrupted` (never `running`) and its
`UpdatedAt` is older than the retention cutoff (seven days before now).
`UpdatedAt` already exists and is bumped on every phase/status transition,
so it already means "the last time anything happened to this run" —
exactly what "how long has this been sitting idle in a terminal state"
needs, with no new column required.

```go
// RunsEligibleForCleanup returns terminal runs whose UpdatedAt is at or
// before cutoff — reused by automatic cleanup so it does not have to rely
// on ListRecentRuns' fixed 200-row window, which exists to answer "is this
// specific recent run still running", not "find every old terminal run".
func (s *Store) RunsEligibleForCleanup(cutoff time.Time) ([]RunRecord, error) {
	rows, err := s.db.Query(
		`SELECT `+runColumns+` FROM runs
		 WHERE status IN ('passed','failed','cancelled','interrupted')
		   AND updated_at <= ?
		 ORDER BY updated_at ASC`,
		cutoff,
	)
	...
}
```

## Sharing the reclaim logic between the manual endpoint and the automatic loop

`handleCleanWorktrees`'s body (the running-check, the
`dirtyWorktreesUnder` check, the actual `os.RemoveAll`) is extracted into a
plain function, e.g. `reclaimFleetDir(fleetDir string, runStatus string,
force bool) (removed bool, skipReason string)`, callable both from the
existing HTTP handler (which still supports `task_id`/`dry_run`/`force`
for the on-demand case) and from the new automatic pass (which always
calls it with `force=false` — automatic cleanup never overrides the
uncommitted-changes guard).

## The background loop

Started once, alongside the server (in `cmd/sergeant/main.go`, next to
wherever `ui.NewServer`/`ReconcileOrphanedRuns` already run at startup —
this mirrors that existing "something runs automatically as part of
server lifecycle" precedent rather than inventing a new one):

```go
func (srv *Server) runFleetCleanupLoop(ctx context.Context) {
	const interval = 1 * time.Hour
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			srv.reclaimEligibleFleetDirs()
		}
	}
}
```

`reclaimEligibleFleetDirs` calls `Store.RunsEligibleForCleanup(time.Now().
Add(-7*24*time.Hour))`, and for each returned run, calls the shared
reclaim function against that run's fleet directory. A run whose fleet
directory does not exist (already cleaned, or never created) is silently
skipped — not an error.

An hourly tick against a seven-day cutoff means a newly-eligible run is
reclaimed within an hour of crossing the threshold, not instantly — this
is intentional: cleanup is a background hygiene task, not a real-time
guarantee, and an hourly cadence is cheap enough to never be a measurable
load on a local SQLite database.

## Rejected alternatives

**A cron-style external invocation instead of an in-process ticker.**
Rejected: sergeant-v2 already runs as a long-lived server process
(managed by launchd in this deployment); adding a second scheduled
entry point external to it would duplicate supervision concerns for no
benefit a ticker inside the existing process doesn't already provide.

**Reusing `ListRecentRuns(200)` for the automatic path.** Rejected: it
answers a different question (is this specific recent run still running)
and would miss any terminal run older than the 200 most recent, which is
exactly the population automatic cleanup exists to find.

**Making the retention period configurable.** Rejected by the proposal:
a fixed constant, matching this project's existing preference for fixed
constants over configuration knobs for single-user, local-first defaults.
