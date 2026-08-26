# Tasks — Dispatch Admission Control and Hard Stop

One repository, `sergeant` (v1), so one task, but the surface area is wide
enough to read carefully before touching anything.

## Task 1 — census, budget, admission check, queue, and hard-stop

Repository: `sergeant`. Depends on: nothing. Read this change's own
`design.md` in full first, then read the real existing code it cites before
writing anything: `bin/sgt-watch:580-660` (`--list`'s existing enumeration
and status-bucket pattern), `bin/_sgt-lib.sh:1255` (`_sgt_pane_identity_matches`)
and `bin/_sgt-lib.sh:1165` (`_sgt_replace_owned_file`), `bin/sgt-dispatch:1440-1480`
(where the fleet-reconciliation sweep runs, and thus where the admission
check must be inserted before it), `bin/sgt-drain-force:175-230` (the
PID-identity-checked SIGTERM→wait→SIGKILL escalation to reuse for
hard-stop), and `bin/sgt-watch`'s `--background` mode (`bin/sgt-watch:28-32`)
as the queue-promotion driver.

- Add `_sgt_live_worker_census`, `_sgt_system_pressure`, and
  `_sgt_effective_worker_budget` to `bin/_sgt-lib.sh`, matching design.md's
  signatures.
- Insert the admission check into `bin/sgt-dispatch` immediately before the
  existing `sgt-watch --sync-all` sweep, after `TASK_ID` is allocated
  under the existing serialized dispatch-task lock.
- Add `$FLEET_DIR/.dispatch-queue/<task-id>/order` (via
  `_sgt_replace_owned_file`) and a `sgt-dispatch-queue --reorder <task-id>
  <position>` subcommand.
- Wire queue promotion into `sgt-watch --background`'s existing cycle: after
  its current reconciliation work, re-check the budget and promote the
  lowest-`order` queued entry if capacity exists, reusing the queued
  `task-id` rather than allocating a new one.
- Add a `queued` bucket to `sgt-watch --list`/`--snapshot`, checked before
  the existing per-repo status read.
- Add `bin/sgt-stop-all` (default tier: durable-handoff capture attempt,
  then the reused SIGTERM→wait→SIGKILL escalation, with no drain
  precondition; `--force`: immediate `SIGKILL`, no handoff attempt, no
  wait).
- Do not modify `sgt-drain`/`sgt-drain-force`'s existing behavior or its
  drain-precondition requirement — hard-stop is a new, independent command,
  not a change to those.
- Do not add per-repo/per-project scope selectors to hard-stop, fine-grained
  per-action resource cost estimation, or cross-machine scheduling.

Verification: this repository has no `go build`/`go test` — verification is
this repo's own shell test suite (`bash tests/<name>-test.sh` per file, or
the project's aggregate test runner if one exists; check `AGENTS.md` for the
current convention). Tests must cover every scenario in
`specs/dispatch-admission/spec.md`: cross-coordinator census counting (two
simulated coordinators sharing one `$FLEET_DIR`), a stale `in_progress`
record with a dead pane not counting as live, budget scaling with load
(fake `sysctl`/`/proc` fixtures at two different load levels producing two
different effective budgets), a queued dispatch appearing immediately in
`sgt-watch`/`sgt-td-list` output, indefinite queue wait (no
timeout-triggered failure), automatic promotion when a live worker is
cleaned up, manual queue reorder changing promotion order, the new `queued`
status bucket, hard-stop working with no drain active, the default tier's
handoff-capture-then-escalate behavior, and `--force`'s immediate,
unconditional stop with no handoff attempt. Follow this session's
established mutation-testing discipline for at least the admission
check itself and the hard-stop escalation: revert the specific guard,
confirm the specific test fails, restore, re-verify clean.
