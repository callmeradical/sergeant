# Proposal — Work analytics dashboard

## Repository

One repository: `sergeant-v2`.

## Requirements served

PRD: `docs/prd-work-analytics-dashboard.md`.

## Problem

`RunRecord.Type` (decision O2) and per-phase `model`/`provider`/`agent`
(decision R4.6, `phases-record-their-model-and-provider`) are durably
recorded today. Nothing aggregates them. An operator wanting to know how
much of their shipped work was bug fixes versus features, which agent did
the work, or what fraction of dispatches actually reach a merged PR has no
way to answer that except reading raw run records by hand — the dashboard
only ever shows one run at a time.

## Proposal

Add a read-only aggregate view, reachable from the existing dashboard
header (the same drawer pattern already used for "Workers & worktrees" —
see `internal/ui/static/index.html`'s `openWorkersDrawer`/`openDrawer`;
there is deliberately no separate full-page view in this dashboard today,
per the existing "no Repair view" precedent at index.html's
`updateRepairTabState` comment, and this change does not introduce one)
showing:

- Total run count and a breakdown by outcome (passed/failed/cancelled/
  interrupted/running, and any other status value actually present).
- A breakdown by work type, using `RunRecord.Type` — including runs
  recorded before O2 existed, whose `Type` is empty, bucketed explicitly
  rather than dropped.
- A breakdown by agent, model, and provider, derived from each run's own
  phase records — reusing exactly the data the run-detail view already
  reads (`internal/ui/static/index.html`'s `phaseDetailHTML`, `p.agent`/
  `p.model`/`p.provider`), not a new capture mechanism. A run with no phase
  carrying this information (most agents besides goose today, per R4.6's
  disclosed limitation) is bucketed as unknown, not silently omitted.
- Bullets that have reached `merged` versus the total number of bullets
  that exist, as the "how much of what we started actually shipped"
  number.
- Scoped by project exactly the way every other dashboard view already is:
  a specific project shows only that project's data; "all projects" (the
  existing `all` sentinel the project filter already uses) combines every
  project's data, never silently defaulting to one or the other.

This must reflect the complete recorded history, not the 50-row window
`GET /api/runs` and `GET /api/intents`-style endpoints use for their
"recent activity" lists — those exist to answer "what's active right now,"
this exists to answer "how much has shipped, ever."

## Out of scope

- **Any change to what is recorded.** No new columns, no new envelope
  types. Purely a read aggregation over `RunRecord.Type`, phase payload
  `agent`/`model`/`provider`, and `BulletRecord.Status`.
- **A charting/graphing library.** The existing dashboard has zero
  third-party JS dependencies beyond what is already vendored; this change
  adds none. Counts and percentages are presented as plain lists/bars using
  the existing Tailwind utility classes, matching the dashboard's existing
  visual style.
- **Time-bucketed history (weekly/monthly trends).** This is a
  point-in-time aggregate of everything recorded so far, not a
  time-series. A trend view is a future PRD if wanted.
- **Cross-installation or exported reporting.** Local, single-operator,
  read-only, in the same process that already serves the dashboard.
- **Extending `detectModelProvider` to recognize agents besides goose.**
  Already-disclosed, not this change's problem to solve (R4.6).
- **v1 retirement (decision A1).** Unrelated and untouched.
