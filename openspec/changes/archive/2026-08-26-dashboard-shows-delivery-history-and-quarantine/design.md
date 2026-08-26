# Design — Dashboard shows delivery history and quarantine

## Ownership and merge order

One repository, `sergeant-v2`. Fourth and final bullet against R5. Depends on
bullets 1-3 (merged): `EnvelopeRecord`'s `ID`/`RunID` (bullet 1), the
`deliveries` table and `Store.ListDeliveryHistory`/`QuarantineDelivery`
(bullets 2-3).

## `ListDeliveriesForRun` is a join, not a new table walk

```go
// ListDeliveriesForRun returns every delivery row belonging to any envelope
// of runID, across all consumers, ordered by created_at. Unlike
// ListDeliveryHistory (one envelope/consumer pair), this is the run-scoped
// view the dashboard actually needs: an operator looks at a run, not a
// single delivery chain.
func (s *Store) ListDeliveriesForRun(runID string) ([]DeliveryRecord, error)
```

```sql
SELECT d.id, d.envelope_id, d.consumer, d.state, d.attempt,
       d.next_attempt_at, COALESCE(d.error, ''), COALESCE(d.error_class, ''),
       COALESCE(d.recovery_instructions, ''), d.idempotency_key,
       d.created_at, d.updated_at
FROM deliveries d
JOIN envelopes e ON e.id = d.envelope_id
WHERE e.run_id = ?
ORDER BY d.created_at ASC, d.id ASC
```

`next_attempt_at` stays un-COALESCE'd for the reason already documented on
`ListDeliveryHistory`: COALESCE-wrapping a DATETIME column changes the format
the driver returns it in, and `parseSQLiteTime` only recognises the
non-COALESCE'd format. Scan it into `sql.NullString`, same pattern.

The scan logic (12 columns into `DeliveryRecord`) is identical to
`ListDeliveryHistory`'s — factor it into a shared `scanDeliveryRow(rowScanner)
(DeliveryRecord, error)` helper both functions call, the same way
`scanEnvelope` is already shared across the envelope listers, rather than
copying the 12-field `Scan` call a second time.

## API: one read endpoint, one write endpoint

`GET /api/delivery-history?run_id=<id>` — calls `ListDeliveriesForRun`,
returns the array as JSON (empty array, not null, matching
`handleRunDetails`'s existing convention for phases/envelopes). 400 on a
missing `run_id`.

`POST /api/delivery-quarantine` — body `{"envelope_id": "...", "consumer":
"...", "reason": "..."}`, all three required (400 if any is empty). Calls
`Store.QuarantineDelivery(envelopeID, consumer, reason)` directly — no
reconstruction needed, unlike replay, because quarantine only ever writes a
record; it does not re-execute anything. Responds with the same
`{"status": ..., ...}` shape `handleRunCancel` uses.

Both follow `internal/ui/server.go`'s existing route registration and
`writeJSON`/`http.Error` conventions exactly — no new response envelope
shape, no new middleware.

## UI: an added section in the existing drawer, not a new page

The per-run drawer already renders `activityHTML(envelopes)` for the
"activity" kind. Add a `deliveriesHTML(deliveries)` function following the
same structure (Tailwind utility classes matching the existing dark theme,
`escapeHTML`/`escapeAttr` for all interpolated text) and call it inside the
existing drawer render path so a run's drawer shows both envelopes and
deliveries — not a second drawer kind an operator has to know to open
separately. `dead_letter` rows get a visually distinct treatment (matching
how other severity-carrying UI in this file is already styled, e.g. the
existing red/amber status conventions) and a "Quarantine" button that
prompts for a reason (a plain `prompt()` is acceptable here — this codebase
has no existing modal/dialog component to match, and inventing one is scope
this bullet does not need) and POSTs to `/api/delivery-quarantine`, then
re-fetches `/api/delivery-history` to reflect the new state.

## Rejected alternatives

**A separate "Deliveries" top-level tab.** The existing "Workers &
worktrees" drawer was deliberately moved out of a top-level tab into a
drawer because it "put a table beside a run list it had no relationship to"
(see the existing comment in `index.html` above `workersHTML`). A
deliveries view has the same relationship to a run that envelopes already
do — a drawer section, not an unrelated tab, for the same reason.

**Building replay into this bullet by guessing which call site to
re-invoke from `consumer`'s shape.** Documented in `proposal.md`'s
out-of-scope section — a heuristic that happens to work today (bare repo
name vs. worktree path) is exactly the kind of guess this project's decisions
this session have consistently avoided (see, e.g., bullet 1's rejection of
inventing a second correlation identifier). Read-only history plus
quarantine (which needs no reconstruction) is the honest slice to ship now.
