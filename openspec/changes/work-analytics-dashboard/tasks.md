# Tasks — Work analytics dashboard

One repository, `sergeant-v2`, so one task.

## Task 1 — analytics query, endpoint, and drawer

Repository: `sergeant-v2`. Depends on: nothing. Read
`openspec/changes/work-analytics-dashboard/{proposal,design}.md` and
`specs/work-analytics/spec.md` first — they are binding. Read `AGENTS.md`.
Work test-first per decision D3. Before writing anything, read:
`internal/store/store.go`'s `RunRecord`, `BulletRecord`, `runColumns`,
`ListPhasesForRun`, and `RunsEligibleForCleanup` (the precedent for an
unbounded, purpose-built query living alongside the capped ones);
`internal/runner/runner.go`'s `annotatePayloadWithProvenance` (what writes
the `agent`/`model`/`provider` keys a phase payload may carry);
`internal/ui/server.go`'s `handleRuns` (the `project`/`all` scoping
convention to match exactly); and `internal/ui/static/index.html`'s
`openWorkersDrawer`/`openDrawer`/`phaseDetailHTML` (the drawer pattern and
the existing `p.agent`/`p.model`/`p.provider` read to reuse, not reinvent).

- Add `Store.AllRunsForAnalytics(project string) ([]RunRecord, error)` and
  `Store.AllBulletsForAnalytics(project string) ([]BulletRecord, error)`
  per design.md — unbounded, project-scoped (`""`/`"all"` means every
  project), reusing `runColumns`/`scanRun` where applicable.
- Add the `WorkAnalytics` aggregation per design.md, wherever the
  project's existing store/UI type boundary convention says it belongs.
  Every run must land in exactly one bucket of `ByAgent`, `ByModel`, and
  `ByProvider` — verify this invariant with a test, not just by
  inspection.
- Add `GET /api/analytics?project=<name>`, matching `handleRuns`'s
  `project`/`all` scoping convention exactly.
- Add a header button and drawer to `internal/ui/static/index.html`
  following the existing Workers-drawer pattern (see design.md). The
  rendering function must be a pure function extractable and testable
  under real `node`, per `internal/ui/stage_matrix_test.go`'s established
  harness pattern — do not ship it covered only by the dashboard loading
  without a JS syntax error.
- Do not add a third-party charting dependency. Do not add a new
  full-page view. Do not change what any existing endpoint records or
  returns.

Verification: `go build ./... && go vet ./... && go test ./internal/... -count=1`.
Tests must cover every scenario in `specs/work-analytics/spec.md`:
total/outcome counts reflecting more than 50 runs (proving no silent
50-row cap); the empty-`Type` bucket for pre-O2 runs; the known-provenance
and unknown-provenance agent/model/provider buckets, with a test asserting
the sum-equals-total invariant explicitly; merged-vs-total bullet counts;
the zero-bullets no-NaN case; project-specific scoping with two projects'
data proven not to commingle; and the "all projects" case combining both.
The drawer's pure render function needs its own node-executed test(s)
covering at least the zero-bullets and known-provenance-breakdown cases.
Exit status decides the outcome.
