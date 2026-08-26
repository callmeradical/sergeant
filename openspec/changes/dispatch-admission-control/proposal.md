# Proposal — Dispatch Admission Control and Hard Stop

## Repository

One repository: `sergeant` (v1, the `bin/sgt-*` bash toolbelt). This does
not touch `sergeant-v2` (the `internal/`/Go server on the `v2` branch).

## Requirements served

PRD: `docs/prd-dispatch-admission-control.md`. Source: Deloitte support
[#41](https://github.com/Deloitte-US-Ascend/ascend-pm-sergeant-support/issues/41).

All six PRD open questions are already settled in that PRD's "Settled
Decisions" section; this proposal implements them, it does not re-litigate
them.

## Problem

`bin/sgt-dispatch` spawns one full interactive-agent worker pane per
requested repo unconditionally. Nothing in the dispatch path reads live
worker count, load average, or memory pressure before spawning another
pane. Two independent coordinator instances on one machine each dispatched
their own batch of work into the same local tmux server; combined live
worker panes exceeded 40 before anyone noticed, the machine started
starving already-running workers of scheduling time, and several
dispatched tasks were later found `drained` with no corresponding live pane
and no completed work.

The fleet directory (`$FLEET_DIR`, default
`$HOME/.local/share/sergeant/fleet`, overridable via `SERGEANT_FLEET`) is
already the one piece of state every coordinator instance on a machine
shares — `sgt-watch --sync-all` already walks every `$FLEET_DIR/*/*/`
record for its own reconciliation sweep (`bin/sgt-dispatch:1448-1478`), and
`sgt-watch --list` already counts per-repo `status` files across the whole
tree (`bin/sgt-watch:597-622`). There is today no equivalent read *before*
spawning a new pane, and no bound at all on the combined total.

Separately, the existing drain path (support #3, PR #184) makes an
already-active cooperative drain reliable, but there is no single command
that reliably stops every live worker immediately without a drain already
being active — not a safe assumption once a machine is already saturated
enough that its own processes may not be scheduled promptly enough to
notice a drain signal.

## Proposal

1. **Machine-wide live-worker census.** A new helper walks
   `$FLEET_DIR/*/*/` counting repos whose `status` file reads `in_progress`
   **and** whose recorded pane is verified live via the existing
   `_sgt_pane_identity_matches` (`bin/_sgt-lib.sh:1255`) — the same
   liveness proof `sgt-watch`/`sgt-recover` already trust, not a bare
   status-file count that could over-count a stale record left behind by a
   pane that died without cleanup.
2. **System pressure as part of the budget, not a separate gate.** A new
   helper reads load average (`sysctl -n vm.loadavg` on Darwin,
   `/proc/loadavg` on Linux) and available memory (`vm_stat` on Darwin,
   `/proc/meminfo` on Linux), and combines it with detected CPU count to
   produce one effective worker-count ceiling — scaled from machine specs,
   backing off further when the machine is already busy, per the PRD's
   settled decision.
3. **Durable FIFO queue with manual reorder, indefinite wait.** A dispatch
   call that would exceed the effective ceiling is recorded as a queued
   entry under `$FLEET_DIR/.dispatch-queue/`, promoted to a real pane
   automatically as capacity frees up. An operator can reorder the queue
   directly. No timeout/expiry — a queued entry waits until admitted.
4. **`sgt-watch`/status output surfaces "queued".** A queued task is a
   distinct, queryable state, not indistinguishable from a hung preflight.
5. **A new two-tier hard-stop command**, independent of the existing drain
   path: default signals every live worker with a short grace period that
   allows a last-chance durable-handoff flush before escalating to a hard
   kill; `--force` skips straight to an immediate, unconditional stop.

## Out of scope

- Fine-grained per-action CPU/RAM cost estimation (a worker is costed as
  one harness process, not sub-process resource accounting).
- Cross-machine/cluster scheduling.
- Replacing `sgt-drain`/`sgt-drain-force` (support #3/PR #184) or the
  preflight-latency bound (support #33, already fixed). This is additive:
  admission control decides whether a worker starts at all; drain remains
  the cooperative shutdown path; hard-stop is the new emergency path.
- Per-repo/per-project scope selectors for hard-stop (PRD settled decision:
  machine-wide "every live worker" is sufficient for now).
- Connection pooling, MCP transport, or anything from the companion
  `shared-mcp-server` change — that PRD is complementary, not a dependency
  of this one.
