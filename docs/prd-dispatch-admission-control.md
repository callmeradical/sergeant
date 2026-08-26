# Product Requirements: Dispatch Admission Control and Hard Stop

Status: Draft, awaiting explicit human PRD approval

Pinned source baseline: `9d9fb612bdb356964bf250904117ece0b3935af8`

Source: Deloitte support [#41](https://github.com/Deloitte-US-Ascend/ascend-pm-sergeant-support/issues/41)

## Summary

Dispatch currently spawns one full interactive-agent worker process per
requested repo, unconditionally, with no awareness of how many worker panes
are already live on the machine (from this coordinator or any other) or how
loaded the machine currently is. This PRD requires Sergeant to treat "how much
of this machine dispatch may use" as an explicit, checked, machine-wide budget
rather than an unenforced personal habit, and to provide one reliable,
unconditional command to stop every live worker immediately when a machine is
already saturated.

## Problem

Two independent coordinator instances on one machine each dispatched their own
batch of work into the same local terminal-multiplexer server. Combined live
worker panes exceeded 40 before anyone noticed. The machine became slow enough
that already-running workers appear to have been starved of scheduling time;
several dispatched tasks were later found `drained` with no corresponding live
pane and no completed work — interrupted mid-run by an unrelated drain rather
than finishing normally. Recovering required manually diffing worktree
contents against remote history, repo by repo, to distinguish real partial
work from noise.

Nothing in the dispatch path reads live worker count, load average, or memory
pressure before spawning another pane. The only current mitigation is an
informal, individually-remembered rule ("keep it to ~5–10 at a time"), which
does not hold across independent coordinator instances with no shared
awareness of each other, and does not adapt to how loaded the machine actually
is at the moment of dispatch.

Separately, once a machine is already thrashing, there is no single command
that reliably stops every live worker right away. The existing drain path
(support #3 / upstream #167, PR #184) makes an *already-active* drain reliable
and diagnosable, but a cooperative drain still depends on the very processes
it is waiting on being healthy enough to notice the signal — not a safe
assumption on a machine already saturated enough to need an emergency stop.

## Users

- **Operator:** runs `sgt-dispatch` against one or more repos, and needs
  dispatch to either run immediately or be reliably queued — never silently
  oversubscribe the machine.
- **Concurrent operator:** runs an independent coordinator instance on the
  same machine, with no expectation of coordinating manually with any other
  operator's dispatch activity.
- **Anyone reaching for an emergency stop:** needs one command that reliably
  and quickly stops every live worker (or an explicit scope) once a machine is
  already in trouble, without a precondition of first having activated a
  drain.

## Outcomes

1. Dispatch checks a machine-wide live-worker census — every session, every
   project, every coordinator instance discoverable on the local
   multiplexer server, not just workers this coordinator itself dispatched —
   before spawning a new worker pane.
2. Dispatch checks current system resource pressure (load average and
   available memory) as a factor in the budget itself, not merely an
   optional secondary signal: the effective ceiling is scaled from detected
   CPU count/RAM and backs off further when the machine is already busy,
   rather than being read purely as a fixed worker-count constant.
3. A dispatch that would exceed the effective budget is queued durably
   instead of spawning a pane or failing the call, and waits indefinitely for
   capacity (no timeout/expiry) — with no change to the caller-facing
   dispatch invocation: one dispatch command for N repos still produces N
   tracked tasks, whether they start immediately or wait. An operator can
   manipulate queue order directly (e.g. promote or reprioritize a specific
   queued task) rather than being limited to strict admission order.
4. Status/list output distinguishes "queued, awaiting capacity" from every
   other non-terminal state, so an operator has a direct answer for "why
   hasn't my dispatch started" instead of something that looks identical to a
   hung preflight.
5. One command exists that immediately signals every live worker to
   terminate, giving each worker a last chance to flush a durable handoff
   before an escalation to a hard kill after a short bounded grace period —
   callable without any precondition of an already-active drain. A `--force`
   variant skips the grace period and handoff chance entirely for an
   immediate, unconditional stop.
6. The admission budget and the hard-stop command both work correctly when
   two or more independent coordinator instances are active on the same
   machine at once — this is treated as an ordinary, expected mode of use,
   not an edge case.

## Non-Goals

- Fine-grained, per-action CPU/RAM cost estimation. A worker's unit of cost is
  treated as "one interactive-agent harness process"; sub-process resource
  accounting is out of scope.
- Cross-machine or cluster-wide scheduling. The budget and census are scoped
  to one local machine.
- Replacing the existing drain (support #3 / PR #184) or preflight-bounding
  (support #33) mechanisms. This PRD's queueing and hard-stop are additive:
  admission control decides whether a worker starts at all; drain remains the
  cooperative shutdown path; hard-stop is the new, independent emergency path.
- Defining the exact resource-check implementation (which `getloadavg`/memory
  APIs, which config file, which queue storage format). That is OpenSpec's
  job.
- Automatically tuning the budget based on historical usage. A configurable,
  human-set ceiling with a sane default is sufficient for this PRD.

## Acceptance Criteria

- Dispatch reads live worker count — scoped to the whole machine, not the
  calling coordinator's own bookkeeping — before spawning a new pane.
- Dispatch reads load average and available memory, and the effective budget
  scales from detected CPU count/RAM rather than being purely a fixed
  worker-count constant.
- A dispatch call that would exceed the effective budget queues the task
  durably rather than spawning a pane or failing the call, and waits
  indefinitely rather than expiring.
- Queue order is FIFO by default, and an operator has a way to manipulate
  queue order directly (promote/reprioritize a specific queued task).
- Queued tasks are promoted automatically as capacity frees up, with no
  change to the caller-facing dispatch invocation.
- Status/list output has a distinct, queryable state for "queued, awaiting
  capacity."
- A single command stops every live worker immediately: by default each
  worker gets a last chance to flush a durable handoff before an escalation
  to a hard kill after a short bounded grace period; a `--force` variant
  skips straight to an immediate, unconditional stop with no handoff
  attempt. Neither requires an already-active drain.
- Regression coverage exists for the exact originating scenario: two
  independent coordinator instances on one machine, where neither dispatch
  alone would exceed the budget but the combined total would — the second
  dispatch queues rather than spawning past the shared ceiling.

## Settled Decisions

1. **Ceiling scales with machine specs.** The worker-count budget is derived
   from detected CPU count/RAM, not a fixed constant across every machine.
2. **Load/memory pressure factors into the budget itself.** Unrelated
   machine load (not just Sergeant-managed worker panes) is accounted for via
   the load-average/memory check, which can shrink the effective budget below
   the nominal worker-count ceiling.
3. **Queue order is FIFO**, across coordinators, by default.
4. **Queued tasks wait indefinitely** for capacity (no timeout/expiry), but
   an operator can manipulate queue order directly rather than being limited
   to strict FIFO promotion.
5. **Hard-stop scope stays machine-wide ("every live worker") for now.**
   No additional per-repo/per-project scope selector is required by this
   PRD; narrower scoping can be added later if a real need surfaces.
6. **Hard-stop has two tiers.** The default gives each worker a last chance
   to flush a durable handoff before escalating to a hard kill after a short
   bounded grace period; `--force` skips the grace period and handoff chance
   entirely for an immediate, unconditional stop.

## Open Questions

None outstanding for this PRD; remaining implementation choices (exact
ceiling formula, queue-reorder interface shape, resource-check APIs) are
OpenSpec's job.
