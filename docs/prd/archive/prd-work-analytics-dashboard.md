# Product Requirements: Work Analytics Dashboard

Status: Draft, awaiting explicit human PRD approval

Extends: `docs/prd-sergeant-v2.md`, R7.3 (the embedded UI presents delivery
status without becoming a second execution engine)

## Summary

Sergeant now durably records, per run, who did the work (which agent),
what kind of work it was (decision O2's work type: feat/fix/refactor/docs/
chore/test), and what happened to it (passed/failed/blocked/merged). None
of this is visible anywhere as an aggregate. The dashboard today shows one
run at a time; there is no view of the fleet's output over time. This PRD
adds a page that answers, at a glance: how much work has shipped, of what
kind, by which agents, and how reliably.

## Problem

An operator running sergeant across multiple projects has no way to see
their own throughput without manually reading through runs one at a time.
Questions like "how much of what we shipped this month was bug fixes versus
new features," "which agent is being used for what," and "what fraction of
dispatches actually reach a merged PR versus dying somewhere along the way"
currently have no answer except reading raw run records by hand. This is a
real, growing gap: work-type (O2) and model/provider capture
(R4.6/`phases-record-their-model-and-provider`) were both built specifically
so this information would exist durably, and today it is captured but never
surfaced back to the person doing the work.

## Proposal

Add a new dashboard view, separate from the existing single-run detail view,
that presents an aggregate picture of completed and in-flight work:

- Volume and outcome of work over time (how many runs, broken down by
  terminal outcome: passed/failed/cancelled/interrupted, and by how many
  reached an actual merged PR).
- Breakdown by work type (feat/fix/refactor/docs/chore/test), using the
  type already recorded on every run and intent since O2.
- Breakdown by agent and, where known, model/provider, using the fields
  already recorded per phase since R4.6.
- The view must reflect real recorded history, not a sample or an
  approximation, and must scope by project the same way every other
  dashboard view already does — an operator running several projects must
  never see one project's activity commingled with another's by default.

## Out of scope

- **Any change to what is recorded.** This PRD is purely a read-side view
  over run/intent/phase fields that already exist (`Type`, agent, model,
  provider, status, timestamps). It defines no new data to capture.
- **Cross-installation or team-wide reporting.** Sergeant is single-operator,
  local-first; this is one operator's own local view of their own local
  history, not a shared or exported report.
- **Real-time/streaming updates to this specific view.** The existing
  dashboard's live-update mechanism for the active run view is unaffected;
  this new view may simply reflect current state on load/refresh.
- **Editing, annotating, or reclassifying past work from this view.** It is
  read-only.
- **v1 retirement (decision A1)** — unrelated and untouched by this PRD.

## Open questions

None blocking.
