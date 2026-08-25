# Product Requirements: Intent Shipping Gate

Status: Draft, awaiting explicit human PRD approval

Extends: `docs/prd-sergeant-v2.md`, D3 ("TDD is enforced, not assumed"), D5
("Three interruptions only"), D6 ("Sequenced submission, human merge"), and
AGENTS.md's listed v2 gap "the shipping gate."

## Summary

v1's `no-mistakes`/`sgt-validate` ran a final, holistic validation pass —
distinct from any single bullet's own tests — before a human was asked to
trust that work was actually ready to ship. v2's D3 gates are real
evidence, but they are scoped to one bullet at a time; nothing today looks
at an intent as a whole (all of its bullets together, in the merge order
D6 already tracks) and answers "is this intent, as a unit, actually ready
for the human merge step D6 hands off to." D5(c) already defines the
notification ("a bullet is ready for an irreversible step") but nothing
generates the evidence that makes that notification trustworthy beyond
per-bullet gates having passed.

## Problem

An intent can reach a state where every one of its bullets is individually
`sealed` (gates green, reviewed if the independent-review phase is
configured) while nothing has checked them **together** — for example,
that bullet B's changes are still consistent with what bullet A already
shipped, or that a cross-cutting concern no single bullet's gates cover
(a security review across the whole diff, a check specific to this
factory's product) has actually run. Today D5(c)'s notification fires
purely on a bullet reaching `sealed`; a human approving a merge sees "gates
passed" and nothing else, which is exactly the gap AGENTS.md names as "the
shipping gate."

## Proposal

Add an intent-level shipping gate: a configured check (or set of checks,
same mechanism as a bullet's own gates) that runs once **all** bullets in
an intent's declared merge order have reached `sealed`, evaluating the
intent as a whole rather than any single bullet:

- Shipping-gate checks are configured per factory, the same way bullet
  gates already are (D8) — this is additive to the existing gate
  mechanism, scoped one level up, not a new mechanism.
- A shipping-gate failure does not fail any individual bullet (they keep
  their own honestly-earned `sealed` status) — it holds the intent back
  from the D5(c) "ready" notification and records why, the same shape as
  the existing blocked-bullet reason (D5(b)'s mechanism, applied at the
  intent level).
- A shipping-gate pass is what actually triggers D5(c)'s notification —
  today that notification is implicitly "a bullet reached sealed"; this
  PRD makes it "the intent's bullets are sealed **and** the shipping gate
  passed," which is the evidence D5(c)'s interruption is supposed to carry.
- This does not change D6: Sergeant still never merges, and still only
  advances the chain by observing real PR state. The shipping gate is
  additional evidence generated before the human is asked to act, not a
  new actor in the merge sequence.

## Out of scope

- **Sergeant merging anything itself.** D6 is unchanged — human merge only.
- **Per-bullet gate changes.** D3's existing per-bullet TDD evidence is
  untouched; this is a new, separate, intent-scoped check layered above it.
- **Replacing the independent review phase.** If both are implemented, a
  shipping gate runs across an already-reviewed set of bullets — it is not
  a substitute for per-bullet review, and this PRD does not require the
  review-phase PRD as a prerequisite (an intent with no review phase
  configured can still have a shipping gate).
- **Blocking human approval outright.** A shipping-gate failure records a
  reason and withholds the "ready" notification; it does not prevent an
  operator who disagrees from proceeding manually — Sergeant surfaces
  evidence, per its own truthfulness rule, it does not become a second
  authority over what ships.

## Open questions

- What is a reasonable default shipping-gate check set when a factory
  configures none — is an empty set (opt-in only, matching how bullet
  gates already work) acceptable, or should some minimal cross-bullet
  consistency check be a default?
- Does a shipping-gate failure ever need to be re-evaluated automatically
  (e.g., a later bullet's merge changes the answer), or is it always
  re-triggered by the same "all bullets sealed" condition firing again?
