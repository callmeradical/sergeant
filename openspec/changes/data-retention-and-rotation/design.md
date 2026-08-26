# Design — Data retention and rotation

## Ownership

One repository, `sergeant-v2`. Touches `internal/config/config.go` (new
`Retention` field), `internal/store/store.go` (new table),
a new `internal/store/retention.go`, `internal/store/analytics.go`
(`ComputeWorkAnalytics`), a new `internal/ui/retention.go`,
`internal/ui/server.go` (loop startup, analytics response), and
`internal/ui/static/index.html` (analytics drawer).

Depends on `pipeline-artifacts` for the `artifacts` table it also rotates,
but does not depend on that change's dashboard rendering — only its store
schema. If `pipeline-artifacts` has not landed yet, this change's
artifact-rotation half has nothing to rotate and is a no-op; it must not
fail to build or run without it (guard with `hasTable("artifacts")`, the
same check `migrateAddTables` already uses, before querying it).

## `internal/config/config.go` — opt-in retention policy

Follows `Export`/`Graphify`'s exact pointer convention: absent means
disabled, distinguishable from a declared-but-zeroed block.

```go
// Retention declares a project's data-rotation policy. A pointer,
// following Export/Graphify exactly: nil means retention is disabled for
// this project, distinguishable from a declared block with zero
// horizons (which would rotate everything immediately and is very
// unlikely to be what an operator meant).
type Retention struct {
	RunsAfterDays      int `yaml:"runs_after_days" json:"runs_after_days"`
	ArtifactsAfterDays int `yaml:"artifacts_after_days" json:"artifacts_after_days"`
}
```

Added to `Project` as `Retention *Retention`. Validation (in whichever
function already validates `Export`/`Graphify` blocks on load): both
fields, if the block is present, must be positive — a declared block with
a zero or negative horizon is a config error, not "rotate everything now."

## `internal/store/store.go` — new tables

Added to `migrateAddTables`'s `wanted` list:

```sql
CREATE TABLE IF NOT EXISTS retention_rollups (
  project              TEXT PRIMARY KEY,
  computed_through     DATETIME NOT NULL,
  run_count            INTEGER NOT NULL DEFAULT 0,
  passed_count         INTEGER NOT NULL DEFAULT 0,
  failed_count         INTEGER NOT NULL DEFAULT 0,
  bullet_total         INTEGER NOT NULL DEFAULT 0,
  bullet_merged        INTEGER NOT NULL DEFAULT 0,
  by_work_type_json     TEXT NOT NULL DEFAULT '{}',
  by_provenance_json    TEXT NOT NULL DEFAULT '{}'
)
```

One row per project — a running total "as of `computed_through`" that
each rotation pass updates in place (`INSERT ... ON CONFLICT(project) DO
UPDATE`), not an appended history of rollups. `by_work_type_json`/
`by_provenance_json` hold the same breakdown shapes
`ComputeWorkAnalytics` already computes from raw rows (work type counts;
agent/model/provider counts), so folding a rotated batch in is "parse,
add counts, re-marshal," not a new aggregation shape.

## `internal/store/retention.go` — new file

```go
func (s *Store) GetRetentionRollup(project string) (*RetentionRollup, bool, error)

// RotateProject folds every eligible run (terminal status, every bullet of
// its intent — if any — at "merged", created before cutoff) into
// project's rollup row, then deletes those runs' phases, envelopes,
// deliveries, and the run rows themselves. Returns how many runs were
// rotated. A run that is not yet terminal, or whose intent has an
// unmerged bullet, is left untouched — mirrors R6.5's "cleanup refuses to
// remove active or diagnostically incomplete" evidence, extended from
// worktrees to rows.
func (s *Store) RotateProject(project string, cutoff time.Time) (int, error)

// RotateArtifacts deletes artifact rows (and their durable files) older
// than cutoff, independent of whether their parent run has itself
// rotated — artifacts have their own, typically shorter, horizon per
// proposal.md.
func (s *Store) RotateArtifacts(cutoff time.Time) (int, error)
```

`RotateProject`'s eligibility query reuses the same "terminal status"
list `RunsEligibleForCleanup` already defines, and additionally requires,
for a run with an `intent_id`, that
`DeriveIntentStatus`/`store.BulletProgression` would place every one of
that intent's bullets at `merged` — a stricter bar than fleet cleanup's
own worktree-reclaim eligibility, since rotating a database row is less
reversible than reclaiming disk space that a re-dispatch would simply
recreate.

## `internal/store/analytics.go` — `ComputeWorkAnalytics`

After computing its existing counts from `AllRunsForAnalytics`/
`AllBulletsForAnalytics`, add the project's `RetentionRollup` (if one
exists) into every corresponding total before returning — same numbers an
operator would have seen had nothing ever rotated. For the "all projects"
view, sum every project's rollup the same way the existing code already
sums across projects.

## Rotation loop (`internal/ui/retention.go`)

Mirrors `internal/ui/fleet.go`'s `fleetCleaner`/`runFleetCleanupLoop`
exactly:

```go
const retentionInterval = 1 * time.Hour

type retentionRotator struct{ store *store.Store; cfg *config.Config }

func (r *retentionRotator) runRetentionLoop(ctx context.Context)
```

For each configured project with a non-nil `Retention`, computes each
horizon's cutoff and calls `RotateProject`/`RotateArtifacts`, recording the
pass's outcome (timestamp, counts) in-memory on the rotator for the
analytics response to read — no new table needed for "last rotation
status," since it only ever needs to answer "since this process started,"
matching `fleetCleaner`'s own in-memory last-run bookkeeping.

## `GET /api/analytics` and the dashboard

The existing analytics response and its drawer gain a `retention` object:
`{"last_run_at": "...", "runs_rotated": N, "artifacts_rotated": N}` per
project with retention configured, absent for a project with none —
same "absent, not zero" rule as everywhere else in this design.

## Rejected alternatives

**Deleting without rolling up first.** Rejected outright — it would make
`work-analytics`' historical totals silently shrink over time, which is
exactly the kind of "a value not derived from stored state" the project's
own truthfulness rule forbids; a rolled-up total is still derived from
real prior state, just pre-aggregated.

**One rollup row per rotation pass (an append-only history) instead of one
running total per project.** Rejected: `ComputeWorkAnalytics` would need
to sum an unbounded number of rollup rows instead of reading one — the
same unbounded-growth problem this change exists to solve, just moved to a
different table.

**Sharing `automated-fleet-cleanup`'s existing loop/ticker instead of a
new one.** Rejected: worktree reclaim and database rotation have
different eligibility rules (rotation's is strictly stricter, per above)
and different failure blast radii (a rotation bug deletes rows; a cleanup
bug deletes a worktree a re-dispatch can recreate) — conflating their
schedules would make a future change to one's cadence a de facto change to
the other's.
