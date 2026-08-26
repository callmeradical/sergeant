# Design — Dispatch Admission Control and Hard Stop

## Ownership

One repository, `sergeant` (v1). Touches `bin/_sgt-lib.sh` (new shared
helpers), `bin/sgt-dispatch` (the admission check itself, inserted before
fleet/pane creation), `bin/sgt-watch` (queue-state reporting and queue
promotion), and a new `bin/sgt-stop-all` script (hard-stop). Reuses
existing, already-verified mechanisms rather than inventing parallel ones:
`_sgt_pane_identity_matches` for liveness proof, `_sgt_replace_owned_file`
for atomic durable writes, and `sgt-drain-force`'s SIGTERM→wait→SIGKILL
escalation shape for hard-stop.

## Census: `_sgt_live_worker_census`

New function in `bin/_sgt-lib.sh`:

```
# _sgt_live_worker_census
# Machine-wide count of verified-live worker panes across every task, every
# repo, every coordinator instance sharing $FLEET_DIR — not just workers this
# invocation's own coordinator dispatched.
_sgt_live_worker_census() {
  local count=0 task_dir repo_dir status
  for task_dir in "$FLEET_DIR"/*/; do
    [[ -d "$task_dir" ]] || continue
    for repo_dir in "$task_dir"/*/; do
      [[ -d "$repo_dir" ]] || continue
      status="$(cat "$repo_dir/status" 2>/dev/null || true)"
      [[ "$status" == "in_progress" ]] || continue
      _sgt_pane_identity_matches "$(cat "$repo_dir/pane" 2>/dev/null || true)" \
        "$repo_dir" || continue
      count=$((count + 1))
    done
  done
  printf '%s\n' "$count"
}
```

This mirrors the exact enumeration `bin/sgt-watch:597-622` (`--list`)
already does for reporting, and the exact liveness proof `bin/sgt-recover`
already trusts before killing/replacing a pane (`_sgt_pane_identity_matches`,
`bin/_sgt-lib.sh:1255`) — a `status=in_progress` file alone is not proof of
life (a crashed pane can leave a stale `in_progress` record), so counting
the file without the identity check would over-count.

## System pressure: `_sgt_system_pressure`

New function in `bin/_sgt-lib.sh`, returning `load_avg_1m
available_mem_ratio cpu_count` space-separated (mirrors the existing
`_sgt_harness_launch_contract` "one decoder for a record" convention):

```
_sgt_system_pressure() {
  local load mem_ratio cpus
  if [[ "$(uname)" == Darwin ]]; then
    load="$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')"
    mem_ratio="$(vm_stat 2>/dev/null | awk '
      /Pages free/ {free=$3} /Pages active/ {active=$3}
      /Pages inactive/ {inactive=$3} /Pages wired/ {wired=$3}
      END { total=free+active+inactive+wired
            if (total>0) printf "%.2f", free/total; else print "1.00" }')"
    cpus="$(sysctl -n hw.ncpu 2>/dev/null)"
  else
    load="$(awk '{print $1}' /proc/loadavg 2>/dev/null)"
    mem_ratio="$(awk '/MemAvailable/{a=$2} /MemTotal/{t=$2}
      END{ if (t>0) printf "%.2f", a/t; else print "1.00" }' /proc/meminfo 2>/dev/null)"
    cpus="$(nproc 2>/dev/null)"
  fi
  printf '%s %s %s\n' "${load:-0}" "${mem_ratio:-1.00}" "${cpus:-1}"
}
```

## Effective budget: `_sgt_effective_worker_budget`

```
# SERGEANT_DISPATCH_MAX_WORKERS overrides the CPU-derived nominal ceiling
# outright (an explicit human-set number always wins). Otherwise the nominal
# ceiling is derived from CPU count, then reduced when load or memory
# pressure is already high.
_sgt_effective_worker_budget() {
  local nominal load mem cpus
  read -r load mem cpus < <(_sgt_system_pressure)
  nominal="${SERGEANT_DISPATCH_MAX_WORKERS:-$((cpus * 2))}"
  awk -v nominal="$nominal" -v load="$load" -v cpus="$cpus" -v mem="$mem" '
    BEGIN {
      budget = nominal
      if (load > cpus) budget = int(budget * cpus / load)
      if (mem < 0.15)  budget = int(budget / 2)
      if (budget < 1) budget = 1
      print budget
    }'
}
```

The exact formula constants (`cpus * 2`, the `0.15` memory floor) are a
starting point for implementation to tune against real measurements, not a
number this design treats as final — the PRD's settled decision only
requires that the ceiling scale with CPU/RAM and that load/memory reduce it
below the nominal value, not a specific formula.

## Admission check in `sgt-dispatch`

Inserted immediately before the existing fleet-reconciliation sweep
(`bin/sgt-dispatch:1448`, `sgt-watch --sync-all`), so a queued dispatch
never reaches fleet/worktree/pane creation at all:

```
live="$(_sgt_live_worker_census)"
budget="$(_sgt_effective_worker_budget)"
if [[ "$live" -ge "$budget" ]]; then
  _sgt_dispatch_queue_enqueue "$TASK_ID" "$PROJECT" "$REPOS_ARG" "$BRIEF" ...
  echo "queued: live=$live budget=$budget; will be admitted automatically"
  exit 0
fi
```

`TASK_ID` must already be allocated (via the existing serialized
dispatch-task lock) before this check, so a queued entry is a real,
durably-identified task from the caller's perspective — `sgt-watch
<task-id>` and `sgt-td-list` work on it immediately, exactly matching PRD
Outcome 3 ("one dispatch command for N repos still produces N tracked
tasks, whether they start immediately or wait").

## Queue storage and promotion

`$FLEET_DIR/.dispatch-queue/<task-id>` holds one file, `order`, an integer
written via `_sgt_replace_owned_file` — the existing atomic-write helper
(`bin/_sgt-lib.sh:1165`) already used throughout this codebase for durable
single-value records. FIFO order is the file's numeric value (a
monotonically increasing counter, read-and-incremented under the existing
serialized dispatch-task lock so two simultaneous enqueues never collide).
Manual reorder is a new `sgt-dispatch-queue --reorder <task-id> <position>`
subcommand that rewrites `order` for the affected entries.

Promotion is driven by `sgt-watch`'s existing background loop
(`bin/sgt-watch --background`, `bin/sgt-watch:30`): each cycle, after its
existing reconciliation work, it re-checks `_sgt_live_worker_census` against
`_sgt_effective_worker_budget` and, if capacity exists, pops the
lowest-`order` entry from `.dispatch-queue/` and invokes the same dispatch
path the original call would have taken (the queued entry's recorded
project/repos/brief/task-id), reusing `TASK_ID` rather than allocating a
new one.

## Status/list surfaces "queued"

`bin/sgt-watch --list` and `--snapshot` gain a `queued` status bucket,
checked before the existing per-repo `status` file read: a task with an
entry under `.dispatch-queue/<task-id>` and no repo directories yet created
is reported as `queued`, distinct from every existing bucket (`done`,
`in_progress`, `needs_input`, `blocked`, `waiting`, `drained`, `orphaned`,
`failed`).

## Hard-stop: `bin/sgt-stop-all`

New script, explicitly independent of `sgt-drain`/`sgt-drain-force`
(neither requires nor sets a drain record). Default tier signals every
task/repo whose `_sgt_pane_identity_matches` proves it live, in the same
PID-identity-checked, TERM-then-poll-then-KILL shape `sgt-drain-force`
already implements (`bin/sgt-drain-force:188-226`) — reused via a shared
helper, not reimplemented — but with one addition: before sending SIGTERM,
it invokes the existing durable-handoff write path
(`sgt-td-memory handoff`, already called by `sgt-recover` and
`sgt-cleanup`) so a live worker's last-known state is captured before the
signal, giving it "a last chance" per the PRD's settled decision — this is
a best-effort write with a short bound, not a wait for the worker's own
cooperation. `sgt-stop-all --force` skips the handoff write and the
grace-period poll entirely, sending `SIGKILL` immediately.

## Rejected alternatives

**Requiring an active drain before hard-stop, matching
`sgt-drain-force`.** Rejected: the PRD explicitly requires hard-stop to
work without that precondition — a saturated machine may never be able to
reliably signal a drain to begin with, per the problem statement.

**A separate daemon/poller for queue promotion.** Rejected in favor of
reusing `sgt-watch --background`, which already runs on a cycle and
already owns fleet-wide reconciliation; a second, uncoordinated poller
touching the same `$FLEET_DIR` state would risk exactly the kind of
uncoordinated-writer problem this PRD exists to prevent.

**Counting `$FLEET_DIR` entries without a liveness check.** Rejected: a
stale `in_progress` record left by a crashed pane would otherwise suppress
admission for phantom capacity that was never really in use, which is the
same class of bug `sgt-watch`/`sgt-recover` already had to solve for their
own reconciliation.
