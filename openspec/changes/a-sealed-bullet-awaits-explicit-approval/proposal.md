# Proposal — A sealed bullet awaits explicit approval

## Repository

One repository: `sergeant-v2`.

## Requirements served

**R3.5**: "Human approval is explicit and required for factory-configured
gates that authorize product/specification transitions or risky delivery
actions."

**D5** — three legitimate interruptions: (a) an inferred plan awaits
approval, (b) a bullet is blocked on a human decision, (c) a bullet is ready
for an irreversible step.

This proposal covers **(c) only**. Research this session found (a) and (b)
have no existing hook point in the code at all — "an inferred plan" isn't
currently a distinct object separate from an OpenSpec change directory, and
nothing distinguishes a gate failure that needs a fix from one that needs a
human decision. Both need a real design decision made before either can be
implemented; inventing that decision as a side effect of this proposal would
be exactly the kind of scope-guessing this project's bullets have
consistently avoided. (c) has a concrete, already-partially-built landing
spot: `sealed` already exists in `store.BulletStatuses()` /
`BulletProgression()`'s documented lifecycle
(`pending → red → green → sealed → merged`) — nothing has ever written it.

## Problem

`bulletStatusForRunOutcome` (`internal/ui/server.go:1786`) only ever
produces `"green"` or `"failed"`. `POST /api/create-pr`
(`handleCreatePR`, line 580) stages or creates a real pull request for a
run's repo, and its own surrounding comments already describe this as
deliberately "an explicit human action" — but it never checks the target
bullet's status before acting, and never advances it to `sealed` afterward.
Two consequences:

- **Not required.** Nothing stops `POST /api/create-pr` from being called
  for a bullet that never passed its gates (never reached `green`) — the
  "risky delivery action" R3.5 names has no guard at all today.
- **Not durably recorded.** Even when a human does take this explicit
  action through the intended path, the bullet silently stays `green`
  forever. There is no record that a human approved the delivery step,
  no distinct state that says "this happened," and no way for the dashboard
  or an API caller to ask "which bullets are ready and waiting for this
  versus which have already been approved."

R3.5's "explicit and required" is two separate properties: today's
`/api/create-pr` supplies "explicit" (a real HTTP call a human or their
tooling makes) but not "required" (nothing enforces gate-passing first) or
durably recorded (nothing marks that it happened).

## Proposal

Add `Store.SealBulletForRun(runID, repo string) error`: resolves the run's
intent, finds the one bullet in that intent for `repo` (a bullet is scoped
to exactly one repository — AGENTS.md), refuses with an error unless that
bullet's current status is `green`, otherwise transitions it to `sealed` via
the existing `UpdateBulletStatus`.

Wire it into `handleCreatePR`: call `SealBulletForRun` **before** attempting
`gh pr create` — a bullet that isn't green refuses the whole request (409),
so the guard is a real gate on the action, not just a status update tacked
on after the fact. Add `GET /api/bullets?run_id=` returning the bullets for
that run's intent (id, repo, status) as JSON, the API substrate this
proposal's guard needs to be inspectable — the same "API first" pattern
`dashboard-shows-delivery-history-and-quarantine` used for R5.6.

## Out of scope

- **D5's interruptions (a) and (b)** — no existing hook point for either;
  each needs its own design decision before implementation, not guessed
  scope bundled into this bullet.
- **A dashboard UI element** showing sealed-vs-green or disabling a
  "Create PR" button for a non-green bullet. The API guard and listing this
  proposal adds are the substrate a future dashboard change would call; this
  bullet does not build that surface, matching the API-first, UI-deferred
  precedent already used once this session.
- **A notification mechanism** for "a bullet is ready" (D5 says a human "is
  notified" for each interruption). This proposal makes the state
  inspectable via `GET /api/bullets`; actively notifying someone (email,
  Slack, a dashboard badge) is separate scope.
- **Un-sealing or reversing a sealed bullet.** No `UnsealBullet` — reversing
  an approval that already happened is a separate, deliberate decision this
  proposal does not need to support (mirrors this session's earlier decision
  not to add `UnquarantineDelivery`).
- **Changing what `merged` means or when it's set.** `sealed → merged` stays
  exactly as already documented (merged is only reachable from observed
  pull-request state; sergeant never merges) — untouched by this proposal.
