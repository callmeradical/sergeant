# Proposal — An intent ships through a shipping gate

## Repository

One repository: `sergeant-v2`.

## Requirements served

**D3**: "TDD is enforced, not assumed" — per-bullet gates are real evidence,
but scoped to one bullet; this proposal does not touch D3, it adds a
separate check one level up.

**D5(c)**: "A human is notified... a bullet is ready for an irreversible
step." Today this interruption's only evidence is a bullet reaching
`sealed` (via `Store.SealBulletForRun`, added by
`a-sealed-bullet-awaits-explicit-approval`). This proposal is what makes
that evidence trustworthy at the intent level, not just per bullet.

**D6**: "Sequenced submission, human merge" — unaffected; this proposal
adds evidence generated before a human acts, not a new actor in the merge
sequence.

PRD: `docs/prd-intent-shipping-gate.md`.

## Problem

`DeriveIntentStatus` (`internal/store/store.go:1510`) only distinguishes
`in_progress` from `satisfied` (every bullet `merged`). There is no derived
or stored concept of "every bullet is sealed" at all — an intent whose five
bullets are all individually sealed looks, to any caller, exactly like one
whose bullets are scattered across pending/red/green. Nothing today checks
bullets *together*: that a later bullet's diff is still consistent with an
earlier one already merged, or that a cross-cutting concern no single
bullet's own `Factory.Gates` command covers (a security pass over the whole
diff, a check specific to this project) has actually run before a human is
asked to trust the chain is ready.

## Proposal

Add an intent-scoped, optional shipping gate:

- `Project` (`internal/config/config.go:13`) gains `ShippingGates
  map[string]string` (`yaml:"shipping_gates,omitempty"`), the same shape as
  `FactoryConfig.Gates` (`config.go:70`) but declared once per project, not
  per repo — because it evaluates the intent as a whole, which spans
  repos, not one bullet's worktree.
- `IntentRecord` (`store.go:88`) gains `ShippingGateStatus string`
  (`""`/`"passed"`/`"failed"`) and `ShippingGateReason string`, mirroring
  `BulletRecord.BlockedReason`'s existing pattern exactly (empty unless
  status is `"failed"`).
- A new pure function, `AllBulletsSealedOrMerged(bullets []BulletRecord)
  bool` (`store.go`, alongside `DeriveIntentStatus`), returns true only when
  every bullet's status is `"sealed"` or `"merged"` — `"merged"` is
  included because D6's sequenced submission can merge an earlier bullet
  while a later one is still catching up to `sealed`.
- The trigger point is `SealBulletForRun`'s caller, `handleCreatePR`
  (`internal/ui/server.go:650`): immediately after a successful seal, check
  whether this seal made `AllBulletsSealedOrMerged` true for the intent. If
  so — and only then — run the project's configured `ShippingGates`
  commands and record the result via a new `Store.RecordShippingGateResult
  (intentID string, passed bool, reason string) error`. A project with no
  `ShippingGates` configured records `passed` immediately and
  unconditionally the moment the condition is met (opt-in, matching how
  `FactoryConfig.Gates` already defaults to none).
- Shipping-gate commands run via a new `runner.RunShippingGate(ctx context
  .Context, name, command string, worktrees []string) (*runner.GateResult,
  error)`, sibling to `RunCodeGate` (`internal/runner/runner.go:231`) but
  not a `*PhaseRunner` method — a shipping gate has no single worktree.
  It runs the command with `cmd.Dir` unset (the sergeant process's own
  working directory) and `SERGEANT_BULLET_WORKTREES` set to the bullets'
  worktree paths, comma-joined, in merge order, in the command's
  environment — the substrate a project's shipping-gate command needs to
  actually inspect more than one repo. It reuses `GateResult` (not a new
  struct), with `Worktree` set to the same comma-joined list, redaction and
  timeout handling identical to `RunCodeGate`.
- `ShippingGateStatus`/`ShippingGateReason` are already visible wherever an
  `IntentRecord` is already serialized to JSON (its `json:` tags cover the
  new fields for free) — no new endpoint is required.

## Out of scope

- **Sergeant merging anything.** D6 unchanged.
- **Per-bullet gate changes.** `Factory.Gates`/`RunCodeGate` untouched.
- **The independent-review-phase PRD.** Not a prerequisite either
  direction.
- **Re-running a shipping gate automatically on every subsequent bullet
  change once it has already run once for an intent.** The trigger is "the
  seal that completes `AllBulletsSealedOrMerged`" — exactly once per
  intent's path to that condition becoming true, not a recurring poll. If
  a later capability needs re-evaluation (e.g. after a bullet is
  re-dispatched post-merge), that is new scope, not this proposal's.
- **A dashboard UI element.** The stored fields are the substrate; a future
  view is separate scope, matching the precedent set by
  `a-sealed-bullet-awaits-explicit-approval`.
