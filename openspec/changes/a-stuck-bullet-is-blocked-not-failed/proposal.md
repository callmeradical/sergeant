# Proposal — A stuck bullet is blocked, not failed

## Repository

One repository: `sergeant-v2`.

## Requirements served

**D5(b)**: "A human is notified when a bullet is blocked on a human
decision."

PRD: `docs/prd-plan-approval-and-blocked-bullets.md` ("Blocked-bullet
escalation" section).

## Problem

`bulletStatusForRunOutcome` (`internal/ui/server.go`) maps a run's terminal
status onto exactly one of two bullet outcomes: `passed -> green`, `failed
-> failed`. It is also the *only* place in the codebase that ever writes
`"failed"` to a bullet (confirmed by grepping every `UpdateBulletStatus`/
`AdvanceBulletsForRun` call site). An agent that gave up because a
requirement was genuinely ambiguous and a gate that failed on an ordinary,
fixable bug land in the same `failed` bucket, with no recorded reason a
human can act on beyond whatever text happens to be in a phase's raw error.

Sergeant today dispatches a bullet's work exactly once per run — there is
no bullet-level automatic re-dispatch, and a run's own internal retry
budget (`RunAgentPhase`'s `retries` parameter) is already exhausted by the
time a run concludes `"failed"` at all. So a bullet reaching `"failed"`
today already means "no further automatic attempt is going to help" in
every case — which is precisely D5(b)'s "blocked on a human decision," not
merely "one attempt among several did not pass."

## Proposal

Replace the `failed` outcome of `bulletStatusForRunOutcome` with `blocked`,
carrying a recorded, human-readable reason:

- When the agent's own envelope reports why it could not proceed, that
  reason is used verbatim.
- When it does not, a synthesized reason is used — a bullet becomes
  `blocked`, with *some* actionable text, unconditionally on a
  gates-never-passed outcome. This must not depend entirely on an agent
  choosing to explain itself.

`green` (from `passed`) is unaffected. Cancellation continues to move
nothing, exactly as today.

## Out of scope

- **A way to resume a blocked bullet with new guidance attached to the
  same bullet.** How a human's decision gets back into the work — most
  concretely, a fresh dispatch — is not solved by this proposal. No
  `UnblockBullet`, no "retry this bullet" endpoint.
- **Reclassifying historical rows.** Bullets already recorded `failed`
  before this change stay `failed`. This changes what gets written going
  forward only.
- **Distinguishing degrees of "needs a decision."** One `blocked` status
  with one reason string, not a taxonomy of reasons or severities.
- **Any change to `green`, `sealed`, `merged`, or the D5(a)/D5(c)
  mechanisms.**
