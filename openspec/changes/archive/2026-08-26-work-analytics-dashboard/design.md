# Design — Work analytics dashboard

## Ownership

One repository, `sergeant-v2`. Touches `internal/store/store.go` (new
unbounded, project-scoped queries and the aggregation itself),
`internal/ui/server.go` (a new `GET /api/analytics` handler), and
`internal/ui/static/index.html` (a new header button and drawer, following
the existing Workers-drawer pattern).

## Store: unbounded, project-scoped source queries

Every existing run/bullet listing method caps at some limit (`ListRecentRuns(50)`,
`ListRunsForProject(project, limit)`) because they exist to answer "what's
active/recent," not "everything, ever" — the same distinction
`RunsEligibleForCleanup` already established for fleet cleanup (see
`openspec/changes/automated-fleet-cleanup/design.md`). Analytics needs the
second kind, so it gets its own queries rather than a very large limit
passed to the existing ones.

```go
// AllRunsForAnalytics returns every run for project, or every run across
// every project when project is "" or "all" — analytics reflects complete
// recorded history, not a recent-activity window. Ordered by created_at so
// output is deterministic.
func (s *Store) AllRunsForAnalytics(project string) ([]RunRecord, error) {
	query := `SELECT ` + runColumns + ` FROM runs`
	var args []interface{}
	if project != "" && project != "all" {
		query += ` WHERE project = ?`
		args = append(args, project)
	}
	query += ` ORDER BY created_at ASC`
	rows, err := s.db.Query(query, args...)
	// ... scanRun loop, same shape as every other list method.
}

// AllBulletsForAnalytics returns every bullet whose intent belongs to
// project (every bullet, across every project, when project is "" or
// "all"). Bullets carry no project column of their own — only their
// intent does — so this joins through intents, the same relationship
// AdvanceBulletsForRun already reads via GetRun+ListBulletsForIntent.
func (s *Store) AllBulletsForAnalytics(project string) ([]BulletRecord, error) {
	query := `SELECT b.id, b.intent_id, b.repo, b.position, b.status,
		COALESCE(b.branch,''), COALESCE(b.worktree,''), COALESCE(b.commit_sha,''),
		COALESCE(b.pr_url,''), COALESCE(b.blocked_reason,''), b.created_at, b.updated_at
		FROM bullets b JOIN intents i ON b.intent_id = i.id`
	var args []interface{}
	if project != "" && project != "all" {
		query += ` WHERE i.project = ?`
		args = append(args, project)
	}
	rows, err := s.db.Query(query, args...)
	// ... scan loop into []BulletRecord.
}
```

## Aggregation

```go
type WorkAnalytics struct {
	Project       string         `json:"project"`
	TotalRuns     int            `json:"total_runs"`
	ByStatus      map[string]int `json:"by_status"`
	ByType        map[string]int `json:"by_type"`   // "" is the pre-O2 bucket
	ByAgent       map[string]int `json:"by_agent"`  // "" is the unknown bucket
	ByModel       map[string]int `json:"by_model"`  // "" is the unknown bucket
	ByProvider    map[string]int `json:"by_provider"` // "" is the unknown bucket
	BulletsTotal  int            `json:"bullets_total"`
	BulletsMerged int            `json:"bullets_merged"`
}

// ComputeWorkAnalytics aggregates recorded history for project ("" or
// "all" for every project) into WorkAnalytics. It is a pure read: no row
// is written or touched.
func (s *Store) ComputeWorkAnalytics(project string) (WorkAnalytics, error) {
	runs, err := s.AllRunsForAnalytics(project)
	// tally ByStatus[r.Status]++, ByType[r.Type]++ for each run.

	// Agent/model/provider: for each run, load its phases
	// (s.ListPhasesForRun(r.ID), already ordered by created_at) and take
	// the first phase whose Payload unmarshals to a JSON object with a
	// non-empty "agent" key (annotatePayloadWithProvenance in
	// internal/runner/runner.go is what writes this key, so this is the
	// same field the run-detail view already reads). If no phase carries
	// one, this run counts under the "" bucket for all three maps — every
	// run must land in exactly one bucket of each map, so
	// sum(ByAgent) == sum(ByModel) == sum(ByProvider) == TotalRuns always.

	bullets, err := s.AllBulletsForAnalytics(project)
	// BulletsTotal = len(bullets); BulletsMerged = count where
	// b.Status == "merged".
}
```

Whether this aggregation lives in `internal/store` (as sketched above,
alongside the data it reads) or is composed in `internal/ui/server.go`
from the store's list methods is left to the implementer — either is
fine as long as the store's public surface stays list-shaped (no
JSON-shaped return type crossing into `internal/store` if the project's
existing convention keeps store types free of `internal/ui` concerns;
check `internal/store/store.go`'s existing exported types for the
precedent before deciding).

## HTTP endpoint

`GET /api/analytics?project=<name>` (query param omitted or `all` means
every project, matching `handleRuns`'s existing convention at
`internal/ui/server.go:518`). Returns `WorkAnalytics` as JSON. No request
body, no side effects — a plain read, like `handleRuns`.

## Frontend: a drawer, not a new page

This dashboard has exactly one main view (the run list + run detail) and
uses drawers (`openDrawer`/`closeDrawer`, `internal/ui/static/index.html`)
for secondary information — "Workers & worktrees" is the existing example,
opened from a header button (`btn-open-workers` /
`openWorkersDrawer`). A prior attempt at a separate "Repair" view was
rejected (see the comment above `updateRepairTabState`) in favor of
folding that state into the run itself. This change follows the drawer
precedent, not a new one:

- A new header button (next to the existing Workers button) opens the
  analytics drawer.
- `async function openAnalyticsDrawer()` fetches
  `/api/analytics?project=<the project filter's current value>` (read
  whatever the existing project-scoping code already reads —
  `onProjectChange()`/`#project-filter`'s value — do not introduce a
  second, independent notion of "current project"), then calls
  `openDrawer('Work analytics', 'analytics', analyticsHTML(data), this)`.
- `analyticsHTML(data)` is a pure function (string in, string out) that
  renders: total run count; the status breakdown as a labeled list with
  counts and percentages; the work-type breakdown the same way, labeling
  the `""` bucket distinctly (e.g. "before work types were tracked"); the
  agent/model/provider breakdown the same way, labeling their `""`
  buckets "unknown" (per R4.6's disclosed limitation, this will often be
  the majority bucket today — that is correct, not a bug, and should read
  as informative rather than broken); and bullets merged vs. total as a
  count and a percentage, showing "no bullets recorded yet" instead of a
  divide-by-zero/NaN when `bullets_total` is 0.
- Being a pure function taking already-fetched JSON and returning an HTML
  string (the same shape as `laneHTML`/`nodeCardHTML`/`phaseDetailHTML`),
  it is unit-testable the same way those are: extract it into a `.mjs`
  file and execute it under real `node` inside a Go test, following
  `internal/ui/stage_matrix_test.go`'s `extractJSFunction` /
  `internal/ui/phase_detail_test.go`'s harness pattern. Do not ship this
  function covered only by "the dashboard JS parses," per this project's
  standing practice that `go build`/`go test` execute none of
  `index.html`'s embedded script.

## Rejected alternatives

**A dedicated full-page view instead of a drawer.** Rejected: this
dashboard has already rejected adding a second full-page destination once
(the "Repair" view). A drawer is consistent with how "Workers &
worktrees" — the dashboard's one existing example of secondary, aggregate
information — is already presented.

**Adding a chart/graph library.** Rejected: zero third-party JS
dependencies today; plain counts and percentages answer every question
this PRD names without one.

**Reusing `ListRecentRuns`/`ListRunsForProject` with a very large limit
instead of new unbounded queries.** Rejected for the same reason
`RunsEligibleForCleanup` was not built on `ListRecentRuns(200)`: those
methods exist to answer a different question, and passing an
arbitrarily large limit as a stand-in for "no limit" is the wrong
abstraction to depend on going forward.
