# Design — Retry policy is explicit and observable

## Ownership and merge order

One repository, `sergeant-v2`. One bullet, no merge order.

## Where the number comes from

`config.Defaults` gains `retries`, and `config.Repo` may override it. Resolution
is the same shape as the existing agent resolution: repository value if set,
else project default, else zero. Zero means one attempt and no retry, which
preserves today's behaviour for every existing configuration.

The resolved value is passed at the one call site in `internal/dag/engine.go`
that currently hardcodes zero.

## Why gates are excluded

A gate is a deterministic command whose exit status is the evidence. Re-running a
failed gate until it passes would turn evidence into a lottery and directly
contradict R2.5 and R2.6, which exist to stop a run being marked passed by
anything other than a real result. Only agent phases retry.

## Observability

Each attempt already produces its own phase record — the store keys on a record
id rather than on `(run, repo, phase)`, which is what made resume able to keep a
failure and a later success side by side. The attempt number belongs in the
record so the sequence is readable without inferring it from timestamps.

A phase that succeeds on its second attempt must therefore leave two records: a
failure and a pass. Collapsing them would hide that a retry happened, which is
the observability R2.4 asks for.

## Rejected alternatives

**A global retry count in an environment variable.** Not per project, and not
visible in the configuration an operator reads.

**Retrying inside the agent harness.** Not observable to sergeant, and each
harness would do it differently.

**Defaulting to a non-zero retry count.** Changes the behaviour of every existing
project silently, and doubles the cost of a genuinely failing phase.
