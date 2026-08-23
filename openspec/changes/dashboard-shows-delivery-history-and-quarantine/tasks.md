# Tasks — Dashboard shows delivery history and quarantine

One repository, `sergeant-v2`, so one task.

## Task 1 — run-scoped delivery history, API, and dashboard surface

Repository: `sergeant-v2`. Depends on: bullets 1-3 of R5 (all merged) —
`internal/store/delivery.go`'s `deliveries` table, `ListDeliveryHistory`,
`QuarantineDelivery`, and `EnvelopeRecord.RunID`.

- Add `Store.ListDeliveriesForRun(runID string) ([]DeliveryRecord, error)` to
  `internal/store/delivery.go`: join `deliveries` to `envelopes` on
  `envelope_id`, filter by `envelopes.run_id`, order by `created_at ASC, id
  ASC`. Select `next_attempt_at` un-COALESCE'd (same reason and pattern as
  `ListDeliveryHistory` — COALESCE changes the driver's returned DATETIME
  format). Factor the shared 12-column scan (already duplicated once in
  `ListDeliveryHistory`) into a `scanDeliveryRow(r rowScanner)
  (DeliveryRecord, error)` helper both functions call, matching the existing
  `scanEnvelope`/`rowScanner` pattern in `store.go`. Return an empty slice,
  not nil, when no rows match.
- Add `GET /api/delivery-history` to `internal/ui/server.go`: reads `run_id`
  from the query string, 400 if missing, calls `ListDeliveriesForRun`, writes
  the result as JSON (empty array not null on zero results, matching
  `handleRunDetails`'s existing convention). Register the route in the same
  block as the other `/api/*` routes.
- Add `POST /api/delivery-quarantine` to `internal/ui/server.go`: decodes
  `{"envelope_id": "...", "consumer": "...", "reason": "..."}`, 400 if any
  field is empty, calls `Store.QuarantineDelivery(envelopeID, consumer,
  reason)` directly (no reconstruction — quarantine only writes a record).
  On the store's error (guard refusal), respond with an error status and the
  store's message, not a generic 500. On success, respond
  `{"status": "quarantined", "envelope_id": ..., "consumer": ...}` following
  the existing response shape convention (see `handleRunCancel`).
- In `internal/ui/static/index.html`, add `deliveriesHTML(deliveries)`
  following `activityHTML(envelopes)`'s structure and Tailwind classes
  (dark theme, `escapeHTML`/`escapeAttr` for every interpolated value — no
  raw string interpolation into the DOM). Wire it into the existing per-run
  drawer render path (see `renderActivity`) so opening a run's drawer also
  fetches `/api/delivery-history?run_id=<id>` and renders its deliveries
  section alongside envelopes — do not add a new top-level tab or a second
  drawer kind. A `dead_letter` row gets visually distinct styling (match this
  file's existing severity/status color conventions) and a "Quarantine"
  button that calls `prompt()` for a reason, POSTs to
  `/api/delivery-quarantine`, and re-fetches delivery history on success to
  reflect the new state.
- Do not implement replay from the dashboard or API. Do not add MCP tools.
  Do not add project/repo/phase-scoped delivery views. Do not change
  `DeliverEnvelope`, `ReplayDelivery`, or the delivery state machine.

Verification: `go build ./... && go vet ./... && go test ./internal/... -count=1`.
Tests must cover every scenario in
`openspec/changes/dashboard-shows-delivery-history-and-quarantine/specs/delivery-surfaces/spec.md`:
`ListDeliveriesForRun` returns deliveries across multiple envelopes/consumers
for one run; a run with no deliveries returns an empty (not nil) slice;
`GET /api/delivery-history` returns the expected JSON shape for a run with
deliveries; the same endpoint without `run_id` returns 400;
`POST /api/delivery-quarantine` succeeds for a dead-lettered delivery and the
quarantine is then visible via a follow-up history request; the same
endpoint refuses (with no new row written) for a delivery that is not
dead-lettered. Exit status decides the outcome. The dashboard's HTML/JS
changes are not covered by `go test`; a manual check (open the dashboard,
inspect a run with a dead-lettered delivery seeded via a direct store call in
a throwaway script, confirm it renders and the quarantine button works) is
acceptable in lieu of frontend test infrastructure this project does not
have.
