# Design — Resume is reachable from the dashboard

## Ownership and merge order

One repository, `sergeant-v2`. One bullet, so no merge order.

## Where the control goes

The run detail drawer, beside the existing run metadata. Not the run list: a list
row is a navigation target, and putting a state-changing action on it invites a
misclick while scanning. The drawer is where the operator has already read the
status, the branch and the worktree.

## What decides whether it renders

The run's status, checked against the same set the server enforces. `internal/ui`
already exports `ResumableStatuses`; the dashboard must derive the condition from
a value served by the API rather than hardcoding a second copy of the list in
JavaScript, or the two will drift and the interface will offer actions the server
refuses.

The cheapest correct route is for the run payload to carry a boolean the server
computes. The interface then renders on that boolean and holds no opinion of its
own about which statuses qualify.

## What it says before acting

The endpoint already returns the phases it will skip. The control reports the same
information before the operator commits: a resume that silently skipped four
gates would leave the operator unsure whether those gates ever ran.

## After acting

The run returns to `running`, which the change stream already publishes, so the
existing render path updates the row and the drawer with no extra polling. This is
the first consumer to benefit from Task 3 without adding a request of its own.

## Rejected alternatives

**A resume button on every run row.** Denser, and it puts an irreversible-feeling
action one stray click from a scan gesture.

**Hardcoding the resumable statuses in JavaScript.** Two authorities for one rule.
The server's refusal is authoritative, so the interface must not maintain its own
copy.

**Resuming automatically when a run fails.** A failed run may have failed for a
reason that a retry cannot fix, and looping on it would burn agent invocations
without a human ever seeing the failure. D5 keeps the operator in the loop.
