# Proposal — Retry policy is explicit and observable

## Repository

One repository: `sergeant-v2`, in `internal/config`, `internal/dag` and
`internal/runner`.

## Requirements and decisions served

- **R2.4 — "configured retry policy is explicit and observable."** Unmet.

## Problem

`RunAgentPhase` takes a retry count and every caller passes zero:

```
internal/dag/engine.go:310   pr.RunAgentPhase(ctx, phase, prompt, 0)
```

There is no retry field anywhere in the project configuration schema, so the
policy is neither configurable nor visible. The parameter exists and is dead.

An agent phase can fail for reasons a second attempt would clear — a transient
provider error, a rate limit, a truncated response. Today the only recovery is an
operator noticing and resuming the run by hand.

## Proposal

Let a project declare `retries` at the defaults level and per repository, pass it
into the phase, and record each attempt separately so the policy is observable in
the run record rather than inferred.

Retry applies to **agent phases only**. A deterministic gate that fails has
produced a real result, and re-running it to get a different answer would defeat
the purpose of a gate (R2.5, R2.6).

## Out of scope

- Backoff between attempts. Worth having, but it is a separate decision about
  timing and this change is about the policy being declared and recorded.
- Retrying a whole run. Resume already covers that and re-enters at the first
  phase without a passed record.
