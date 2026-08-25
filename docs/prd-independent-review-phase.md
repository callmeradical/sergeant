# Product Requirements: Independent Review Phase

Status: Draft, awaiting explicit human PRD approval

Extends: `docs/prd-sergeant-v2.md`, D2 ("Trust the workflow, review the
inference"), D3 ("TDD is enforced, not assumed"), D5 ("Three interruptions
only"), and AGENTS.md's listed v2 gap "independent review workers."

## Summary

v1 routed a bullet's diff through a separate reviewing agent before calling
work done: `sgt-review-findings --axis <axis>` deduplicated findings into
owning-repository `td` tasks by axis (correctness, security, and so on) and
published a blocking gate only for `error`-severity findings. v2 has no
equivalent — a bullet's own gates (D3's red/green evidence) are the only
check between "green" and `sealed`, and they are deterministic commands,
not a second, independent look at whether the diff actually does what the
intent asked for. This PRD adds that second look as a native phase in the
bullet pipeline, not as a human process layered on top of it (which is what
this repository's own `progress` skill currently does by hand, one change
at a time).

## Problem

D3 enforces that gates ran and passed. It does not, and cannot by design,
catch a diff that passes every gate while quietly not doing what the intent
actually asked for, introducing a security issue no configured gate checks
for, or diverging from the OpenSpec change's `design.md`. v1 caught exactly
this class of problem with a second, independent agent — "independent"
specifically meaning it did not share the implementing agent's context or
assumptions. v2 has no phase that plays this role at all today: a bullet
goes gates-green straight to sealed/approval with nothing between them.

## Proposal

Add an optional review phase, configured per factory like any other gate
(D8 — "adding a gate changes the view with no UI change"), that runs after
a bullet reaches `green` and before it is eligible for `sealed`:

- The review phase dispatches a **fresh agent with no shared context** with
  the implementing run — mirroring exactly what this repository's
  `progress` skill's step 6 ("independent critic") already does manually.
  This PRD makes that pattern a first-class, automatic phase instead of a
  documented human procedure.
- The reviewer is given the diff, the intent, and (when the bullet resolves
  to one, per O3) the OpenSpec change's `proposal.md`/`design.md`/
  `specs/*/spec.md`, and judges against those — not its own assumptions
  about what the feature should do.
- Findings are recorded on the bullet as structured evidence — axis,
  severity, summary, disposition — in Sergeant's own store (D4: Sergeant
  does not hand findings to an external tracker as their record of truth;
  a task-tracking export, if configured per the task-tracking-export PRD,
  may carry a read-only copy).
- A finding's severity determines what happens next, and this is
  constrained by D5 ("three interruptions only" — this phase must not
  invent a fourth):
  - Non-blocking findings (the equivalent of v1's `warning`/`info`) are
    recorded and shown in the fleet view. They do not interrupt anyone.
  - A blocking finding (v1's `error` family — a genuine spec mismatch or
    correctness/security problem) transitions the bullet to `blocked`,
    reusing the existing blocked-bullet mechanism (D5(b)) rather than
    inventing new state. The recorded reason is the finding itself.
- A bullet with no review phase configured behaves exactly as it does
  today — this is additive, not a required step for every factory.

## Out of scope

- **Routing findings into an external task tracker as their primary
  record.** That would violate D4 the same way a two-way `td` integration
  would; see the task-tracking-export PRD for the (read-only, optional)
  export path.
- **Replacing or weakening D3's deterministic gates.** The review phase is
  a second, independent check in addition to gates, not a substitute for
  them — a diff that fails its own gates never reaches this phase.
- **Human-in-the-loop review UX** (a person reading findings in the
  dashboard before approval) beyond what already exists for a `blocked`
  bullet. This PRD does not add a new approval surface.
- **Multiple review axes as separate configurable phases in this PRD's
  first cut.** A single review phase producing axis-tagged findings is the
  starting scope; splitting into per-axis phases (mirroring v1's
  `--axis <axis>` routing) is a candidate future extension, not required
  here.

## Open questions

- Which model/agent runs the review phase, and is it configurable per
  factory or fixed? An OpenSpec `design.md` decision.
- Does a review phase have its own timeout/retry policy distinct from an
  implementation phase's, given it reads a diff rather than producing one?
