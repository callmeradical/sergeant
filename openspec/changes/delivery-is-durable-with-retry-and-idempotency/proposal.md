# Proposal — Delivery is durable, with retry and idempotency

## Repository

One repository: `sergeant-v2`.

## Requirements served

Bullet 2 of 4 against **R5 — notification/envelope transport**. Depends on bullet
1 (`envelopes-are-typed-versioned-and-correlated`, merged), which gave every
envelope the identity (`id`, `type`, `correlation_id`, ...) this bullet keys
delivery records on. This bullet covers:

- **R5.3** — publication is durably persisted before acknowledgement; the
  authoritative record includes an append-only delivery history; process exit,
  restart, or a disconnected consumer must not lose an accepted envelope.
- **R5.4** — each delivery has explicit state (`pending`, `leased`,
  `delivered`, `acknowledged`, `retrying`, `failed`, `dead_letter`), attempt
  count, lease/next-attempt timestamps, consumer identity, and error
  classification. Delivery uses bounded retry with observable backoff and an
  idempotency key; redelivery cannot create duplicate authoritative phase
  results, approvals, or commits.

Bullet 3 (dead-lettering with replay/quarantine, R5.5) and bullet 4 (CLI/UI/MCP
operator surfaces, R5.6) depend on this one for the delivery record they inspect
and act on.

## Problem

sergeant-v2 has exactly two places an envelope reaches a consumer, and both
discard their error:

- `runner.RunAgentPhase` calls `Router.SaveEnvelope`, which writes the envelope
  to a file under the fleet's handoff directory. The call is `_ =
  pr.Router.SaveEnvelope(&env)` — a failed write is invisible.
- `dag.Engine` calls `Router.InjectHandoffToWorktree(upstream, worktreePath)` to
  copy the upstream repo's latest envelope into a downstream repo's worktree
  before that repo's phase starts. The call is `_ =
  e.Router.InjectHandoffToWorktree(upstream, worktreePath)` — same thing.

Neither call has a durable record of the attempt, a state, a retry, or an
idempotency key. If the copy fails — the worktree does not exist yet, the disk
is full, a permission error — the downstream phase starts anyway, reads no
handoff, and proceeds on an agent-authored guess about what the upstream repo
did. Nothing fails loudly. Nothing retries. Nothing records that this happened,
so an operator debugging a bad downstream result has no delivery history to
inspect, only the fact that a file was or was not present on disk.

Concretely, what is missing and what it costs:

- **No durable delivery record.** A delivery is a `_ =` line, not a row. There
  is nothing to inspect after the fact, and nothing survives a process restart
  mid-delivery — a coordinator crash between the write and its result being
  observed loses that history entirely.
- **No state machine.** A delivery either happened or it silently didn't.
  There is no `pending`, `retrying`, or `failed` — only "we called the
  function."
- **No retry.** A transient failure (worktree not yet created, a momentary disk
  error) is permanent, because there is no attempt count and nothing decides
  whether to try again.
- **No idempotency key.** Nothing stops the same envelope from being delivered
  to the same consumer twice and being treated as two independent facts, which
  matters once retry exists — a naive retry of a partially-succeeded delivery
  must not duplicate whatever the delivery caused downstream.

v1 has no equivalent mechanism either: `bin/_sgt-response-lock.sh` implements a
comparable idempotency guarantee for one specific handoff (worker responses)
using flock'd directories and marker files on top of the filesystem. It works,
but it is bespoke to that one call site, unqueryable as a set, and exactly the
kind of file-based coordination v2 replaced its store with. This bullet gives
v2 one general mechanism, backed by the same SQLite store as everything else,
that both current call sites use.

## Proposal

Add a `deliveries` table: one row per (envelope, consumer) delivery attempt
chain, with explicit state, attempt count, lease/next-attempt timestamps,
consumer identity, and error classification, exactly as R5.4 lists. A delivery
is created `pending` before the attempt, and every state transition is a new
row in an append-only history rather than an update that discards what came
before — R5.3's "authoritative record includes ... an append-only delivery
history."

`Router.SaveEnvelope` and `Router.InjectHandoffToWorktree` keep their current
job (write the file); the store wraps each call: record `pending`, attempt,
transition to `delivered` on success or `retrying` on failure up to a bounded
attempt count, then `failed`. The idempotency key is the pair (`envelope_id`,
`consumer`): a second delivery attempt for a key that already reached
`delivered` is a no-op that returns the existing terminal record rather than
attempting the write again or recording a second delivery.

`acknowledged` is part of the state vocabulary this bullet's schema supports,
but no current consumer acknowledges receipt — the two existing call sites are
fire-and-forget file writes with no read-side confirmation. This bullet does
not invent a consumer-side ack protocol; a delivery this bullet drives reaches
`delivered`, not `acknowledged`. `dead_letter` is reachable in the state
vocabulary but bullet 3 owns what happens when a delivery is dead-lettered
(replay, quarantine, blocking policy); this bullet only stops retrying and
marks `failed` once attempts are exhausted.

## Out of scope

- Dead-letter handling: replay, quarantine, and the policy deciding whether a
  dead-lettered delivery blocks its dependent phase — bullet 3 (R5.5).
- CLI/UI/MCP surfaces over delivery history — bullet 4 (R5.6).
- A consumer-side acknowledgement protocol. `acknowledged` exists in the state
  enum; nothing in this bullet drives a delivery to it.
- Changing what `SaveEnvelope` and `InjectHandoffToWorktree` write, or the
  handoff file format. This bullet wraps the existing writes with a durable
  record of the attempt; it does not change their content or destination.
