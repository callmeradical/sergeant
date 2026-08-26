# Product Requirements: Activity Reflects Every Real Transition

Status: Draft, awaiting explicit human PRD approval

Extends: `docs/prd-sergeant-v2.md` D8/R7.5 (the dashboard renders real
lifecycle position, not a curated subset of it) and R4.2 (records
correlate project/run/stage/repo/phase/gate — the Activity feed is where
an operator reads that correlation back as a narrative).

## Summary

The Activity panel is missing two whole classes of real, already-recorded
state change:

1. **A code gate's completion has no Activity entry at all.** Only agent
   phases (`RunAgentPhase`, publishing a `"phase.completed"` envelope)
   appear. `RunCodeGate` — every `build`/`test`/`vet` gate — only calls
   `RecordPhase` (a silent database write); it never publishes an
   envelope. The GATES panel shows these passing with real timings, but
   Activity shows nothing for them, as if they never ran.
2. **A bullet's lifecycle transition has no Activity entry at all.**
   `UpdateBulletStatus`/`updateBulletStatusAndReason` (the shared write
   paths behind every bullet status change — red→green, green→sealed,
   sealed→merged, sealed→blocked, and any run-outcome-driven blocked
   transition) only call `recordTransition`, which writes to the `changes`
   table — the live SSE state-stream, not the durable `envelopes` table
   Activity reads from. Once an operator isn't watching it happen live,
   the transition leaves no narrative trace.

## Problem

Both gaps have the identical shape: something real, already durably
recorded elsewhere (the `phases` table; the `bullets` table plus the
`changes` stream), never gets turned into the human-readable record
Activity exists to be. An operator reading a run's history today sees an
incomplete, misleading story — two agent phases and a delivery event, with
every gate and every lifecycle step silently missing, not because nothing
happened, but because nothing was ever asked to narrate it.

## Proposal

- **Every gate completion publishes an Activity envelope**, exactly the
  same tier of evidence a phase completion already gets: which gate, its
  repo, pass/fail, duration — published from the one shared function every
  gate invocation already goes through, so no future gate type or call
  site can silently omit one the way today's gaps happened.
- **Every bullet status transition publishes an Activity envelope**, from
  the shared low-level write path(s) every status change already goes
  through, not from each of the several higher-level callers individually
  — the same "fix it once, at the choke point" principle, so a future
  caller of an existing bullet-mutation method cannot introduce a new gap
  the way today's gaps happened.
- Both extend the existing envelope mechanism (`EnvelopeRecord`,
  `RecordEnvelope`) — no new storage concept, no new UI surface. The
  Activity panel already renders whatever `envelopes` a run has; it needs
  more complete input, not a new renderer.
- A bullet transition's envelope is scoped to the run that caused it —
  the same correlation discipline every other envelope in this system
  already has (R4.2).

## Out of scope

- Redesigning the Activity panel's rendering itself (grouping, filtering,
  pagination) — purely a completeness fix to what gets recorded, not how
  it's displayed.
- Retroactively backfilling Activity entries for gates/transitions that
  already happened before this ships. Historical runs simply keep the
  incomplete record they already have.
- Any change to the live SSE state-stream (`changes` table) — unaffected;
  this adds a durable envelope alongside it, not a replacement for it.

## Open questions

- **Which run a bullet-transition envelope is scoped to, when the
  low-level write path doesn't currently receive one.**
  `UpdateBulletStatus(bulletID, status)`/`updateBulletStatusAndReason(bulletID,
  status, reason)` take only a bullet id today. Some callers already have
  a `runID` in hand (`AdvanceBulletsForRun`); at least one
  (`checkBulletMergeStatus`, behind the merge-observation check) has a
  `run` in scope but doesn't currently pass it into the store call it
  makes. Whether that means threading `runID` through these signatures, or
  something else, is a `design.md` decision — but *which* run an
  out-of-band transition (one not caused by a currently-executing
  dispatch) should be attributed to is a real product question this PRD
  should answer before design.md has to guess: the run whose pipeline
  view triggered the check that observed the transition, or the run that
  most recently touched that bullet, if they differ.
- **Volume.** Publishing one envelope per gate and per bullet transition
  could noticeably increase how many Activity entries a single run
  produces. This PRD takes the position that completeness matters more
  than density here (an operator can already filter/scroll; a missing
  entry cannot be un-missed), but it's worth naming as a real tradeoff
  rather than an assumed non-issue.
- **Granularity when one real moment produces two facts.** Gates all
  passing and a bullet advancing to `green` happen at essentially the same
  instant, from the same underlying event. This PRD's default is two
  separate entries (a gate-completion envelope and a bullet-transition
  envelope), each naming a different fact — not merged into one — but
  that's a judgment call worth surfacing, not a settled requirement.
