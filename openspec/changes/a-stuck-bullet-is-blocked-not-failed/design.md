# Design — A stuck bullet is blocked, not failed

## Ownership

One repository, `sergeant-v2`. Touches `internal/store/store.go` (new
bullet status, new `BlockedReason` field), `internal/runner/runner.go`
(reading an optional reason out of an agent-authored envelope), and
`internal/ui/server.go` (`bulletStatusForRunOutcome`).

## Data model

- `store.BulletStatuses()` gains `"blocked"`, documented the same way
  `"failed"` already is — reachable from any earlier state, sorted last
  alongside it, since a bullet can get stuck at any point in its
  lifecycle.
- `BulletRecord` gains `BlockedReason string` (empty unless status is
  `"blocked"`).

## Where the reason comes from

An agent's own envelope (`.sergeant/envelope.json`, already read by
`RunAgentPhase`) may include a `blocked_reason` key **inside its existing
`payload` object**, not as a new top-level `Envelope` struct field.

This is a deliberate choice, not an oversight: `env.Payload` already passes
through `redact.JSON` unconditionally before it is persisted (the fix from
this project's Review 018). A new top-level `Envelope.BlockedReason string`
field would need its own explicit `redact.Text` call wired in at the same
point — exactly the "new field, new call site, easy to forget" shape that
produced nine separate redaction gaps across this project's last redaction
effort. Nesting it inside `Payload` means it is redacted for free, by a
mechanism that already exists and is already tested.

```go
// After env is built (either branch) and before it is returned/persisted:
var blockedReason string
if m, ok := payloadAsMap(env.Payload); ok {
    if v, ok := m["blocked_reason"].(string); ok {
        blockedReason = v // already redacted: env.Payload was redact.JSON'd above
    }
}
```

(`payloadAsMap` is illustrative — a small helper unmarshaling
`json.RawMessage` into `map[string]interface{}`, returning `ok=false` for
non-object payloads.)

## Trigger: replacing the `failed` outcome, not adding a parallel one

`bulletStatusForRunOutcome` today:

```go
func bulletStatusForRunOutcome(runStatus string) (string, bool) {
	switch runStatus {
	case "passed":
		return "green", true
	case "failed":
		return "failed", true
	default:
		return "", false
	}
}
```

Becomes, conceptually:

```go
case "failed":
    return "blocked", true // reason is threaded separately, see below
```

Since `bulletStatusForRunOutcome` only returns a status string today and
`AdvanceBulletsForRun` only takes a status, the call site
(`recordTerminalRun`) needs the reason threaded alongside the status —
either by extending `AdvanceBulletsForRun` to optionally carry a reason
applied to every bullet it advances, or by having `recordTerminalRun` look
up the reason (from the run's envelopes, via existing
`ListEnvelopesForRun`) and write it directly. Either is acceptable;
OpenSpec implementation should pick whichever keeps `AdvanceBulletsForRun`'s
existing "every bullet in the intent, per run outcome" semantics intact for
the unrelated `green` case, which carries no reason.

When no envelope named a `blocked_reason`, use a synthesized one:
`"gates did not pass; no further automatic attempt available"`. Sergeant
dispatches a bullet's work exactly once per run and a run's own retry
budget is already exhausted by the time it concludes `"failed"` — so this
synthesized case is not a weaker fallback for some failures, it is what
happens for every failure an agent did not explicitly explain.

This means `"failed"` becomes unreachable as a bullet status for any run
concluding after this change ships — the only place that ever wrote it is
the line being changed. It remains a valid value for historical rows
(`BulletStatuses()` keeps it documented) and nothing here migrates or
reinterprets those.

## Rejected alternatives

**A new top-level `Envelope.BlockedReason` field.** Rejected: see "Where
the reason comes from" above — reuses existing, already-tested redaction
wiring instead of adding a new call site.

**Keeping a "still has retries, therefore not blocked" carve-out as active
logic.** Considered and rejected as unnecessary: under the current
architecture (one dispatch attempt per run, retries exhausted internally
before a run ever concludes `"failed"`), there is no bullet-visible
mid-retry state to protect against — the carve-out the PRD names is
satisfied because the case it describes cannot occur today, not because of
new logic detecting it. If a future capability adds bullet-level automatic
re-dispatch, that capability is responsible for keeping a genuinely
mid-retry bullet out of this path; it is not this proposal's job to guess
at that mechanism now.

**A taxonomy of blocked reasons (ambiguity vs. missing access vs. ...).**
Rejected: one free-text reason is enough for a human to read and act on;
categorizing it is unproven value for real added schema complexity.

## Carry-forward note for OpenSpec review

R5.6's delivery-history/quarantine surface should be checked against the
new `blocked` status so a blocked bullet's run is not also rendered there
as an ordinary ungated failure. This is a review point during
implementation, not a product decision this proposal needs to resolve.
