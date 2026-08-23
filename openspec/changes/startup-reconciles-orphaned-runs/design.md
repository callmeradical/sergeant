# Design — A restarted coordinator reconciles orphaned runs

## Ownership and merge order

One repository, `sergeant-v2`. One bullet, no merge order.

## Where it runs

In the server's startup path, before the listener accepts connections. Doing it
after would leave a window where a client can read, and act on, a status the
coordinator already knows is stale — including a resume that gets refused for a
reason that stops being true a moment later.

## What certainty a restart provides

A freshly started coordinator is driving no runs. Its in-flight registry is empty
by construction. So any run the store reports as `running` is, from this process's
view, unowned. That is the whole inference, and it is sound precisely because it
is made at startup and nowhere else.

Reconciliation must therefore never run again during the process's life. Mid-life
it would be false: a run legitimately in flight would be reconciled out from under
itself.

## Why `interrupted` and not `failed`

Nothing judged the work. A gate did not fail; the coordinator stopped. Recording
`failed` asserts a verdict no gate produced, which the truthfulness rule forbids,
and it would tell an operator the work was tried and found wanting when it was
merely cut off.

`interrupted` joins `ResumableStatuses`, so the existing resume path recovers it
with no special case. `BulletProgression` must not gain it — it is not a step
toward delivery, it is an absence of one.

## Phases, not just runs

A phase row can be left `running` by the same crash. A run reconciled to
`interrupted` while a phase still claims `running` would contradict itself, and
resume's skip rule reads phase status: a phase stuck at `running` is neither
`passed` nor re-run, so it would be silently skipped. Phases are reconciled with
their run.

## Reporting rather than silence

Reconciliation writes to the log and appends to the change sequence, so an
operator sees that something was recovered. A coordinator that quietly rewrites
statuses at boot is indistinguishable from one that loses data.

## Rejected alternatives

**A heartbeat column, treating a stale timestamp as dead.** Correct for detecting
a crash while running, and unnecessary here: at startup the answer is already
known with certainty and needs no threshold to tune.

**A PID column checked with a liveness probe.** PIDs are reused, and the check is
wrong across a reboot.

**Resuming reconciled runs automatically.** The crash may have been caused by the
run. Relaunching unattended risks a loop, and D5 keeps the operator in the loop
for exactly this kind of decision.

**Leaving them and letting the operator cancel.** The status quo. It requires the
operator to know the trick, and it means the record is knowingly false until
someone intervenes.
