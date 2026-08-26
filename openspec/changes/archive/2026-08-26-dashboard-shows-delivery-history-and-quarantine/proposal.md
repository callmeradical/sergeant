# Proposal — Dashboard shows delivery history and quarantine

## Repository

One repository: `sergeant-v2`.

## Requirement served

**R5.6** (partial — see scope below): "CLI and embedded UI expose envelope
history and correlation: delivery state, attempts and errors, pending work,
and dead letters scoped by project, repository, run, phase, assignment, and
correlation ID. MCP, when enabled, provides structured notification status
and policy-controlled replay/quarantine operations. These surfaces operate
the same durable transport, not a parallel dispatch mechanism."

Bullet 4 of 4 against R5 — the last one. Depends on bullets 1-3 (all merged):
envelope identity (R5.1/R5.2), the `deliveries` table and its state machine
(R5.3/R5.4), and dead-lettering with `ReplayDelivery`/`QuarantineDelivery`
(R5.5). Those bullets built the mechanism; this one is the first thing that
reads it from outside the store package.

## Problem

`Store.ListDeliveryHistory`, `Store.ReplayDelivery`, and
`Store.QuarantineDelivery` all exist and are correctly implemented and
tested (Reviews 007-008), but nothing outside `internal/store` calls any of
them. An operator with a dead-lettered delivery today has no way to see it
exists short of opening the SQLite file directly. The dashboard's existing
per-run drawer (`internal/ui/static/index.html`'s `activityHTML`, fed by
`/api/run-details`) shows envelopes; it has no equivalent for deliveries.

`Store.ListDeliveryHistory` is also keyed strictly on one `(envelope_id,
consumer)` pair — there is no store method that answers "every delivery for
this run," which is the natural dashboard query (a run, not a single
envelope/consumer pair, is what an operator is looking at).

## Proposal

Add `Store.ListDeliveriesForRun(runID string) ([]DeliveryRecord, error)`,
joining `deliveries` to `envelopes` on `envelope_id` and filtering by
`envelopes.run_id`. Expose it as `GET /api/delivery-history?run_id=`,
following the existing route conventions in `internal/ui/server.go`. Extend
the dashboard's existing per-run activity drawer with a "Deliveries" section
listing each delivery's current state, consumer, attempt count, error/error
class, and (for `dead_letter` rows) recovery instructions — the same drawer
pattern already used for envelopes and worktree leases, not a new page.

Add `POST /api/delivery-quarantine` (body: `envelope_id`, `consumer`,
`reason`), calling `Store.QuarantineDelivery` directly — this is a pure,
already-guarded write (refused unless the delivery's latest state is
`dead_letter`) with no reconstruction required. Give the dashboard a
"Quarantine" action on each `dead_letter` row, prompting for a reason.

## Out of scope

- **Replay from the dashboard/API.** `Store.ReplayDelivery` takes an
  `attempt func() error` — the actual retry closure (`Router.SaveEnvelope` or
  `Router.InjectHandoffToWorktree`, depending on which of the two production
  call sites originally attempted the delivery). Reconstructing which one
  applies from `(envelope_id, consumer)` alone, outside the process that
  made the original attempt, is a real design question (the two call sites
  are distinguishable today only by a heuristic on the shape of `consumer` —
  a bare repo name vs. a worktree path — which this proposal is not willing
  to guess at without a considered design). Follow-on work, not this bullet.
- **MCP tools.** R5.6 names this "when enabled" — softer than the CLI/UI
  half of the same sentence. Adding `sergeant_delivery_status` /
  `sergeant_delivery_quarantine`-shaped tools to `internal/mcp/server.go` is
  mechanical (7 tools already follow one pattern there) but is separate
  follow-on work, not bundled into this bullet.
- **Scoping by project, repository, phase, or correlation ID independently
  of a run.** The dashboard's existing structure is run-centric (one drawer
  per run); R5.6 lists several other scoping dimensions, but the immediately
  useful, achievable slice is "deliveries for the run I'm already looking
  at." A project-wide or cross-run dead-letter view is a different UI
  surface, not an extension of the existing drawer.
- **Any CLI binary/subcommand.** "CLI" in R5.6 is served today by the same
  HTTP API a future CLI would call; this bullet adds the API surface, which
  is the shared substrate, not a new terminal tool.
- Changing `DeliverEnvelope`, `ReplayDelivery`, or the delivery state machine
  themselves.
