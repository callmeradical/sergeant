# Product Requirements: Plan Approval and Blocked-Bullet Escalation

Status: Draft, awaiting explicit human PRD approval

Extends: `docs/prd-sergeant-v2.md`, decision D5

## Summary

D5 names three legitimate human interruptions: (a) an inferred plan awaits
approval, (b) a bullet is blocked on a human decision, (c) a bullet is ready
for an irreversible step. (c) is implemented (R3.5, sealed bullets). (a) and
(b) are not: dispatch always proceeds immediately regardless of how the
repository/bullet decomposition was arrived at, and a failed bullet is
indistinguishable from one that genuinely cannot proceed without a human.
This PRD defines what must be true for both.

## Problem

**D5(a).** Today, a dispatch that does not name explicit repositories
silently defaults to every repository in the project and starts working
immediately — there is no point at which a human confirms that
decomposition first. This contradicts D2, which requires a plan sergeant
arrived at itself (rather than one the caller stated explicitly) to be
proposed and explicitly approved before any work begins. A caller who
forgets to name repositories today dispatches against their entire project
with no confirmation at all.

**D5(b).** A bullet's outcome today is only ever "passed its gates" or
"failed." An agent that gave up because a requirement was genuinely
ambiguous, and a bullet that failed because of an ordinary, fixable bug,
land in the same bucket, distinguishable only by reading raw failure detail
after the fact. Nothing raises this as an interruption the way D5 requires
("a human is notified"), and nothing records *why* a human's input is
needed.

## Requirements

### Plan approval

1. A dispatch whose repository/bullet decomposition was not stated
   explicitly by the caller must not begin any work — no worktree, no
   agent — until a human has reviewed and approved it. This is what D2
   already requires; today nothing enforces it.
2. A dispatch whose decomposition *was* stated explicitly by the caller is
   never subject to this gate; its behavior is unchanged. Only the
   not-stated-explicitly case is new.
3. A human must be able to see what is awaiting approval — which
   repositories, in what order — before deciding.
4. A human must be able to explicitly approve a pending plan, which is the
   only way its work begins, or explicitly reject it, which starts nothing
   and ends that plan.
5. Approving or rejecting an already-decided plan must not take a second
   action or produce a second, conflicting outcome.

### Blocked-bullet escalation

6. A bullet whose dispatched work could not reach a passing result, and for
   which no further automatic attempt is going to help, must be
   distinguishable from a bullet that simply failed one attempt and may
   still succeed on a retry.
7. That distinguishable state must carry a human-readable reason a person
   can act on — not just "it failed," but why a human's judgment is
   needed. A reason must always be present, even when nothing explains it
   beyond "no automatic attempt succeeded" — this must not depend entirely
   on an agent choosing to explain itself.
8. A bullet that still has an automatic attempt remaining after a failure
   is not affected by this — it is mid-retry, not blocked.
9. This reason is a durable, inspectable record, not something visible only
   in raw logs, and it is subject to the same privacy/redaction guarantees
   as every other durable, human-readable text this project retains (R4.4).

## Non-goals

- **Inferring a decomposition intelligently** (proposing, from a brief,
  which repositories and bullets it implies). This PRD only gates the case
  that exists today — deciding *for* the caller when they name nothing —
  and does not build a smarter proposal mechanism. A better proposal
  mechanism is separate, later scope.
- **Editing a proposed plan before deciding on it.** The decision is
  binary: approve what was proposed, or reject it.
- **Push notifications** (email, Slack, desktop). Visibility to a human is
  a dashboard requirement, not a delivery-channel requirement.
- **A way to resume a blocked bullet with new guidance in place.** How a
  human's decision gets back into the work — a fresh attempt, or
  abandoning it — is not solved by this PRD.
- **Reclassifying past work.** This changes what gets recorded going
  forward; it does not reinterpret history.

## Open questions

None blocking.
