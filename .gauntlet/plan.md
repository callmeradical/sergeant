# Sergeant Agent Factory Gauntlet

## Goal

Clear Sergeant's backlog while proving a crash-safe, multi-coordinator agent
factory. Workers are ephemeral. Plans, evidence, git output and lifecycle state
are durable. A process, pane, tmux server or host restart must not destroy work
or leave the factory unable to derive what happened.

Owning td epic: **td-445c24**.

## Fixed point

- Repository: `callmeradical/sergeant`
- Integration branch: `origin/main`
- Initial base: `fa864ab` (`fix(cleanup): bind notification ledger directories as lifecycle evidence (#178)`)
- Plan branch: `plan/agent-factory-gauntlet`
- Baseline captured: 2026-08-05

## Constraints and accepted decisions

1. The plan owns intent, phases, dependencies and the definition of done.
   Evidence owns progress. Status in this file is a human cache and is never
   trusted on resume without rerunning the commands.
2. Workers are ephemeral. No worker context is required to resume correctly
   persisted work.
3. Every implementation slice gets a fresh builder and a separate fresh critic.
   Critics inspect real output and never receive the builder's reasoning.
4. Critics are validation-only. Findings return to builders; they never auto-fix.
5. Guards are proved by mutation: the prohibited condition is introduced and
   the guard must fail, then the mutation is restored.
6. Two consecutive rounds that change code without improving the measured bar
   trigger architectural review, not another patch.
7. No `sgt-drain --global`, `sgt-watch --sync-all` or foreign fleet mutation
   while coordinator ownership is unenforced. Interim protocol:
   `~/.local/share/sergeant/COORDINATOR-BOUNDARY.md`.
8. Repository shipping policy still applies: native validation, independent
   standards/spec review, one final no-mistakes gate, PR and CI.

## Quality bar

### Agent-factory bar

From a clean checkout, two simultaneous coordinator sessions dispatch independent
fleets while an adversarial harness injects:

- tmux server death;
- worker SIGKILL at every lifecycle boundary;
- coordinator death and verified handover;
- derived-branch collision and stale checkout HEAD;
- stale refs and squash-merged content;
- notification/response crash windows;
- process leaks holding worktree CWDs;
- no-mistakes capability mismatch;
- CI/network loss and deferred wake conditions;
- cleanup retry after partial removal.

The artifact wins only if all of these remain true:

- no committed or uncommitted work is lost;
- no session mutates another's fleet without explicit audited handover;
- durable state plus git/PR/td evidence reconstructs the true state;
- status and progress are derived from evidence, not stale recorded fields;
- every mutation is exact-owner-bound and fail-closed;
- retries are idempotent or report the exact prior outcome;
- Bash 3.2, ShellCheck, native tests, independent reviews and CI pass;
- one command reproduces the fault-injection matrix.

### Backlog bar

Initial untrusted inventory:

```text
490 non-closed: 12 P0, 217 P1, 185 P2, 69 P3, 7 P4
10 in_progress, 55 in_review, 419 open, 6 blocked
```

Backlog is clear only when:

- every card belongs to one phase or is deferred with a durable trigger;
- duplicates are closed with pointers to one canonical owner;
- no `in_progress` card lacks a live owner or durable handoff;
- no merged/delivered card remains open;
- no actionable finding lives only in a PR, validation run or agent context;
- every P0/P1 has a current owner or verified blocker.

## Progress verification

Run these on every resume before trusting phase status:

```bash
git fetch origin --prune
git status --short --branch
git diff --stat origin/main...HEAD
td list --json --limit 2000 > /tmp/sergeant-gauntlet-td.json
sgt-watch --list
```

Do **not** run `sgt-watch --sync-all` until Phase 2 verifies session scoping.

## Phases

### Phase -4 — Reconcile the external no-mistakes dependency

- Status: pending
- Depends on: none
- Builder scope: external dependency reconciliation plus the plan-local
  `scripts/gauntlet/reconcile-external.py` evidence tool; no Sergeant or
  no-mistakes product implementation
- Critic input: installed binary, no-mistakes repo/worktrees, td-cc69e3 and
  fleet task `add-protected-intent-fil-e38566`
- Why this is first: `--intent-file` is owned by no-mistakes. A live blocked
  branch already exists for that exact capability. Sergeant must not build a
  fallback that races or is immediately superseded by its upstream owner.
- Verification commands and expected outcomes:

```bash
python3 scripts/gauntlet/reconcile-external.py --repo no-mistakes \
  --card td-cc69e3 --capability intent-file
# exactly one owner, branch, blocker and resolution path

no-mistakes axi run --help
# capture installed capability as evidence; never infer it
```

- Required outcome: either upstream has a verified path to merge and Sergeant
  waits for it, or upstream explicitly rejects/defers the capability and
  Sergeant owns a documented fallback. No code changes in this phase.
- Tooling persistence: `reconcile-external.py` is committed on the Gauntlet
  foundation branch and travels with the Phase -0A bootstrap PR. It is planning
  evidence tooling, not a product implementation.
- Evidence: installed binary lacks `--intent-file`; critic round 5 found live
  task `add-protected-intent-fil-e38566`, no-mistakes td-cc69e3, branch
  `feat/ship-intent-file-onto-current-main`.
- Largest remaining gap: upstream blocker/ownership is not reconciled

### Phase -3 — Inventory existing work before assigning builders

- Status: pending
- Depends on: none
- Builder scope: ownership/branch/worktree/PR inventory plus plan-local
  `scripts/gauntlet/reconcile-work.py`; no disposition, push, merge or product
  implementation
- Critic input: `git worktree list`, fleet owner identities, td cards, remote
  branches and PRs
- Verification commands and expected outcomes:

```bash
python3 scripts/gauntlet/reconcile-work.py --check-one-owner-per-scope
# must print zero overlapping builders for the same files/state boundary

python3 scripts/gauntlet/reconcile-work.py --check-unpublished-work
# every ref namespace, reflog/stash and worktree with commits or uncommitted work
# must have one durable owner and shipping/handoff path

python3 scripts/gauntlet/reconcile-work.py --check-base
# plan fixed point must equal the resolved origin/main used for dispatch

python3 scripts/gauntlet/reconcile-work.py --check-inventory-complete
# every branch/worktree/dirty tree has an owner candidate, overlap set and
# evidence. Disposition happens only in Phase -0 after the substrate exists.

python3 scripts/gauntlet/reconcile-work.py --check-fleet-owner-reconciled
# one row per fleet record. Every nonterminal status — in_progress,
# needs_input, blocked, waiting, orphaned — must report branch, worktree,
# pane_identity, worker_process_start and DERIVED liveness. Bare pane numbers
# are never ownership evidence because tmux reuses them after restart.
```

- Required artifact: `.gauntlet/existing-work.md` with one row per **ref in any
  namespace, reflog/stash entry and worktree**: namespace/trust class, commit
  count, dirty count, owning td, coordinator,
  overlap set, provisional disposition and evidence. It does not execute the
  disposition. No builder in any phase may start against an overlap set until
  Phase -0B integrates or explicitly preserves it with a trigger. Negative
  phase numbers do not exempt bootstrap work.
- The artifact also contains one row per fleet record, including terminal and
  nonterminal status, response/wake condition, exact `pane_identity`, process
  start, derived liveness and audited handover. A branch cannot be adopted,
  merged, superseded or discarded while its nonterminal worker is awaiting a
  response/wake/handover.
- Mutation evidence runs only on a copied fixture fleet: rewrite a copied dead
  record's `pane_identity` to a live foreign pane while leaving
  `worker_process_start` unchanged; reconciliation must FAIL as reused. Sha256
  of every real identity/start file must be byte-identical before and after.

- Baseline evidence updated at critic round 8: 22 worktrees, 102 local branches,
  80 remote refs, 397 non-merge commits off `origin/main`, and 74 local-only
  branches with commits. The earlier 166-commit/19-branch count was materially
  incomplete because the schema omitted local refs not attached to worktrees.
- Remote baseline at critic round 14: origin is not the only commit store.
  `refs/remotes/no-mistakes/*` holds 82 refs and 124 non-merge commits reachable
  from no local branch or origin ref; a gate ref holds 2 more. Twenty-seven
  no-mistakes refs contain unique work and require owner rows before the bare
  repo can be shimmed, pruned or ignored.
- Ref-namespace baseline at critic round 15: the repo also has 23
  `refs/no-mistakes`, 20 `refs/recovery`, 5 tags and a stash. Four recovery
  commits, twelve no-mistakes/recover commits and one stash commit are reachable
  from no head/remote ref. Inventory is complete only when every unique commit
  from `git rev-list --all --reflog --glob=refs/* refs/stash` has an owner row.
- Trust classes are explicit: `origin` is canonical; `no-mistakes` is a trusted
  same-repository pipeline commit store; `gate` is pipeline evidence, not
  automatically mergeable; third-party forks such as `pr13-head` are untrusted
  until commit provenance and owning PR are verified.
- Remote URLs are never recorded verbatim. Evidence stores sanitized host/path
  plus a digest. A credential-bearing URL was observed in critic round 14; it
  must be rotated by the owning coordinator and must never enter fixtures, logs
  or critic artifacts.
- Credential gate: before any fetch, run
  `scripts/gauntlet/check-remote-secrets.py`. A credential-bearing URL blocks the
  phase and links one P0 owner card. The owning coordinator revokes the
  credential and replaces the URL with a credential-free form; the check must
  then PASS without ever printing the credential.
- Fleet baseline at critic round 9: at least five nonterminal Sergeant records
  have dead pane identities, including the canonical Phase -2 and Phase -0A
  branches; `add-cross-platform-serge-4dfdd3` remains `needs_input`. They require
  per-record response, wake or audited handover — never fleet-wide sync.
- Fixed-point note: initial `origin/main` is `fa864ab`. The default checkout at
  `5a10451` is an unpushed feature branch, not a newer integration base. The plan
  always resolves `origin/main` rather than treating incidental checkout HEAD as
  main. The fixed point is re-recorded after each Phase -0B merge; a successful
  merge must not make `--check-base` fail permanently.
- Evidence: pending; `scripts/gauntlet/reconcile-work.py` does not exist
- Tooling persistence: `reconcile-work.py`, the external tool and the Gauntlet
  plan remain on one foundation branch and travel with the Phase -0A bootstrap
  PR. They execute directly from that plan worktree before merge; Phase -3 does
  not wait for Phase -0A to ship them. Thus no hidden shipping cycle remains.
- Phase -4 owns no-mistakes product capability reconciliation. Phase -3 owns
  inventory/disposition evidence for Sergeant commits stored in the no-mistakes
  remote. Phase -2's execution shim never hides that commit store.
- Largest remaining gap: existing work has no phase/owner map

### Phase -3.5 — Adjudicate dead-record ownership

- Status: pending
- Depends on: Phase -3
- Builder scope: plan-local, one-time audited handover tool; no worker status
  rewrite, no cleanup, no branch edits
- Why it exists: phase-canonical branches are owned by fleet records in every
  nonterminal status (`orphaned`, `blocked`, `needs_input`, `waiting`,
  `in_progress`) with dead pane identities. Existing commands cannot transfer
  them: recover accepts only `in_progress`, respond needs a pending response,
  wake needs a wake condition, and fleet-wide sync is prohibited. Observation
  became a blocking gate with no legal release path.
- Required artifact:
  `scripts/gauntlet/adjudicate-dead-record.py`, read-only by default. `--apply`
  may create one owner-handover record containing:
  - exact old `primary_pane_identity` and `worker_process_start`;
  - proof that the exact pane identity/process start no longer exists;
  - branch, worktree, commit, dirty count, td id/status and PR state;
  - new coordinator exact pane identity/process start;
  - evidence digest and timestamp.
- It **does not** rewrite `status`; every historical status remains unchanged.
  The marker transfers coordinator ownership only. A real blocker or decision
  remains blocked after handover. Phase -0B still owns final branch disposition.
- Phase -3.5 has preservation-only authority before handover. It may create an
  anchored `refs/gauntlet/preserve/<task-id>` and a content-addressed rescue
  artifact; it may not checkout/reset, modify the worker index/worktree, commit
  onto the worker branch, delete files or stash-pop.
- Real fleet safety: dry-run opens real fleet files read-only; mutation tests
  require `--fleet-root <temporary-copy>` and refuse paths under
  `$HOME/.local/share/sergeant`; `--apply` writes only a new handover marker via
  exclusive temp file + fsync + atomic rename, including the pre-image digest.
  It never edits `pane_identity`, `worker_process_start` or `status`.
- Exact commands and expected outcomes:

```bash
python3 scripts/gauntlet/adjudicate-dead-record.py --all-dead \
  --project sergeant --handover-to "$TMUX_PANE"
# dry-run JSON: one row per nonterminal record. Exact dead records report
# eligible=true with status preserved; live/reused identities report false.

python3 scripts/gauntlet/adjudicate-dead-record.py \
  --task <approved-task> \
  --expected-pane-identity '<exact-recorded-identity>' \
  --expected-process-start '<exact-recorded-start>' \
  --handover-to "$TMUX_PANE" --apply
# writes one owner-handover record and prints its digest; repeat only for rows
# individually approved from the dry-run
```

- Dirty worktree quarantine:
  - `.sergeant-*` runtime/evidence files are not product dirt; include their
    file list/hashes in evidence but do not let them block handover.
  - tracked/index modifications are captured without changing the worktree:
    `git stash create`, followed by
    `git update-ref refs/gauntlet/preserve/<task-id> <oid>`. Verify the ref.
  - untracked non-runtime files are archived under the rescue root with sorted
    file list, modes and sha256. Verify the archive before handover.
  - after capture, the tree may remain dirty and is classified
    `dirty-preserved`; the new owner restores/reviews preservation artifacts
    before adopting the branch.

```bash
python3 scripts/gauntlet/adjudicate-dead-record.py --task <approved-task> \
  --expected-pane-identity '<identity>' --handover-to "$TMUX_PANE" \
  --quarantine --apply
# prints preservation ref, untracked archive digest and handover digest; git
# status must be byte-identical before/after
```

- Fail closed if: status is terminal; expected identity differs; pane/process is
  live; product dirt exists but quarantine was not requested/verified;
  branch/head changed after dry-run; td/PR state is
  ambiguous; a newer handover exists; or target coordinator cannot be proved
  live.
- Mutation proof on fixture only: use a PATH-injected fake tmux command that
  reports one synthetic foreign pane as live, replace the copied dead record's
  pane id with it while keeping the old process start, and require adjudication
  to FAIL as reused. Do not start or kill any ambient pane.
- Preservation mutation on fixture: make the stash oid unanchored, corrupt one
  archive byte, or change git status after capture; each must FAIL before
  handover, then restore fixture green.
- Human gate: show the complete dry-run table before `--apply`. The user
  approves exact task ids/identities individually, never a blanket transfer.
- Later ownership work (Phase 2/td-af6916) productizes this behavior; the
  plan-local tool is retained as bootstrap evidence, not a hidden permanent API.
- Evidence baseline: critics 10/11 identified at least seven dead-pane
  nonterminal Sergeant records owning phase work, including durable-condition,
  validation, worker-lifecycle, cleanup, dispatch, review-routing, fleet-global
  and harness branches. No supported command transfers them.
- Critic round 16 measured five dead records with product dirt. The canonical
  validation branch has five commits plus two uncommitted tracked edits in
  `bin/sgt-validate` and `bin/sgt-validation-worker`; it is the mandatory first
  quarantine proof.
- Largest remaining gap: adjudication tool does not exist

### Phase -2 — Create an inert hermetic substrate

- Status: pending
- Depends on: Phase -4, Phase -3.5
- Builder scope: new test infrastructure files only; no existing test or
  production lifecycle script changes
- Critic input: sandbox root, real-host sentinels, boundary inventory
- Explicitly rejected substrate base:
  `feat/epic-durable-condition-evaluation-for-wa` adds a useful
  `tests/global-state-isolation-test.sh`, but it is inseparable from 2,683 lines
  of drain/wake product work, sources branch-local `_sgt-drain.sh`, and requires
  branch-local drain tests. Shipping it here would bypass Phase -0B disposition
  and Phase 4/6 critics. It remains Phase -0B product work; Phase -1 may reuse
  ideas after disposition, not code before then.
- `feat/epic-worker-lifecycle-and-supervision-in` likewise remains Phase -0B
  work; its edits to existing tests are not Phase -2 input.
- Required artifact: `tests/lib/factory-env.sh` exposes
  `factory_env_new <name>` and allocates:
  - one tmux socket strategy used by helper and production commands;
  - `SERGEANT_FLEET`, isolated `HOME`/td database;
  - `SERGEANT_CONFIG`, `SERGEANT_DRAIN_DIR`, callback and rescue roots;
  - fake `SERGEANT_SYSTEMCTL`, `SERGEANT_SYSTEMD_RUN`, `gh` and no-mistakes;
  - unique `SERGEANT_TMUX_SESSION` and bare git origin.
- Fixture origins use generated local paths with no credentials. The substrate
  refuses credential-bearing remote URLs and proves no secret appears in copied
  config, command output or artifacts.
- New foundation files only:
  `tests/lib/factory-env.sh`, `tests/gauntlet/boundaries.txt`,
  `tests/factory-env-isolation-test.sh`, and
  `tests/factory-env-boundaries-test.sh`. This phase intentionally does not
  migrate the 21 legacy tmux tests; Phase -1 does so after disposition.
- Verification commands and expected outcomes:

```bash
tests/factory-env-isolation-test.sh
tests/factory-env-isolation-test.sh --kill-tmux
tests/factory-env-isolation-test.sh --two-coordinators
tests/factory-env-boundaries-test.sh
# all PASS while real fleet/tmux/systemd/GitHub/no-mistakes sentinels remain
# byte-identical before and after
```

- Mutation evidence: hardcode ambient tmux/fleet/drain/rescue/systemd/GitHub/
  no-mistakes one at a time; each isolation test must FAIL naming the escaped
  boundary, then restore green.
- Remote mutation: inject a credential-bearing fixture URL; conformance must
  FAIL naming the remote without printing the credential. A third-party fork ref
  cannot become mergeable until its trust class changes with provenance evidence.
- Shipping: commit this inert substrate on its own foundation branch, but do not
  merge it alone. Phase -0A stacks the canonical validation repair on top and
  ships both together under the one-time bootstrap exception. Thus Phase -0A's
  probe tests can use the substrate before the repaired gate exists, without
  running ambient tmux.
- Evidence: no substrate exists today; no existing test uses `tmux -L`, `tmux
  -S` or `TMUX_TMPDIR` on main. Two preserved branches contain non-separable
  product-plus-isolation work and remain Phase -0B-owned. Real default socket
  and 24 fleet records are live.
- Overlap gate before edits:

```bash
python3 scripts/gauntlet/reconcile-work.py --check-no-overlap-builders --phase -2
# must PASS because every Phase -2 path is new and no existing branch edits it.
# Existing isolation-themed branches remain Phase -0B-owned; conceptual
# similarity is not file/state overlap.
```
- Largest remaining gap: inert substrate does not exist

### Phase -1 — Migrate legacy tests and enforce substrate conformance

- Status: pending
- Depends on: Phase -0B
- Builder scope: migrate existing tests only; no product lifecycle changes
- Critic input: all tmux/process/worktree tests and closed boundary inventory
- Mutual exclusion: no test that kills tmux, process groups or worktrees runs
  outside `factory_env_new`.
- Required enforcement: `tests/factory-env-conformance-test.sh` rejects every
  test that invokes bare tmux, omits isolated HOME/fleet, bypasses
  `factory_env_new`, reaches real systemd/GitHub/no-mistakes, or writes an
  unlisted boundary.
- All 21 existing tmux-touching test files migrate in this phase, after Phase
  -0B has disposed existing branches that modify them.
- Verification commands and expected outcomes:

```bash
tests/factory-env-conformance-test.sh
python3 scripts/gauntlet/check-test-conformance.py --all-tmux-references
# must enumerate every test file containing `tmux` (21 at critic round 8) and
# print zero files that lack `factory_env_new`; a grep over kill verbs alone is
# insufficient because 17 other tmux-touching files would pass silently
```

- Mutation: reinsert bare `tmux kill-session` in a migrated test; conformance
  must FAIL naming file:line, then restore green.
- Evidence: 21 tmux-touching files, six kill-session calls across five files;
  some tests isolate HOME but no rule makes that universal.
- Largest remaining gap: conformance and migrations do not exist

### Phase -0A — Repair the validation capability boundary

- Status: pending
- Depends on: Phase -2
- Builder scope: adopt one existing validation branch as canonical and complete
  `SERGEANT_NO_MISTAKES` indirection plus capability probe/fallback in
  `sgt-validate`/`sgt-validation-worker`; never dispatch a fourth competing
  implementation
- Critic input: hermetic no-mistakes shims advertising each capability variant,
  protected intent, zero-run and argv-exposure behavior
- Verification commands and expected outcomes:

```bash
tests/sgt-validate-capability-probe-test.sh
# must PASS for shims with and without --intent-file support

grep -R "command -v no-mistakes" bin/
# must return zero; production resolves through SERGEANT_NO_MISTAKES

# mutation: force --intent-file unconditionally
tests/sgt-validate-capability-probe-test.sh
# must FAIL naming --intent-file, then restore and rerun green
```

```bash
python3 scripts/gauntlet/reconcile-work.py --check-no-overlap-builders --phase -0A
# must initially FAIL naming every branch that edits validation worker/tests;
# then PASS only after one branch is canonical and the rest are recorded
# superseded-by or preserved in .gauntlet/existing-work.md
```

- Known overlap set at critic round 6:
  - `feat/add-intent-file-flag-support-to-no-mista` (4 commits)
  - `feat/add-intent-file-flag-support-to-usr-loca` (1 commit)
  - `feat/add-protected-intent-file-flag-support-t` (1 commit)
  Each edits `bin/sgt-validation-worker` and
  `tests/sgt-validation-worker-test.sh`. One becomes canonical; no fresh branch
  is created.
- Critic round 8 expanded this set to five local branches plus one remote:
  `feat/epic-restore-the-coordinator-owned-valid`,
  `feat/keep-validation-intent-out-of-process-ar`, and
  `origin/feat/add-protected-intent-file-flag-to-the-no` must be included by the
  Phase -0A overlap gate.

- One-time bootstrap exception: this phase repairs its own shipping gate. If
  Phase -4 has not delivered upstream `--intent-file`, ship after native
  validation and fresh critics by invoking no-mistakes directly in a dedicated
  tmux window with a minimal non-sensitive `--intent`. Record argv exposure and
  end the exception after merge. This PR contains the Gauntlet planning tools,
  adopted Phase -2 substrate and canonical validation repair; all three are the
  minimum foundation required to execute the next phase and are reviewed as
  separate commits/critic artifacts on one stacked branch.
- End-to-end proof belongs to Phase -0B, after existing work has an owner map.
- Evidence: installed no-mistakes lacks `--intent-file`; validation exits 1 and
  creates zero runs.
- Largest remaining gap: repair does not exist

### Phase -0B — Dispose and integrate existing work

- Status: pending
- Depends on: Phase -0A
- Builder scope: execute the dispositions recorded in
  `.gauntlet/existing-work.md`; no new product implementation
- Critic input: each branch's actual diff, tests, td/spec, PR and overlap set
- Verification commands and expected outcomes:

```bash
python3 scripts/gauntlet/reconcile-work.py --check-disposition
# every branch with commits or dirty work has exactly one outcome:
# merge order + owner, preserved/deferred trigger, superseded-by branch, or
# verified discard approval

python3 scripts/gauntlet/reconcile-work.py --check-no-overlap-builders
# zero new builders overlap any unresolved existing branch
```

- Every shipped branch uses the repaired Phase -0A validation boundary. Every
  discard requires explicit human approval and a durable patch/branch anchor.
- After each merge, update the plan's current integration SHA and rerun overlap
  analysis; initial fixed point remains historical evidence.
- Evidence baseline: critic round 4 counted 166 unpushed commits across 19
  branches, 9 dirty worktrees and 0 open PRs. Detection alone is not success.
- Largest remaining gap: no disposition map exists

### Phase 0 — Make the backlog truthful

- Status: pending
- Depends on: Phase -1
- Builder scope: inventory, deduplication, shipped-vs-open reconciliation,
  phase assignment; no product implementation
- Critic input: td database, git history, PR state, existing fleet records
- Existing owners: td-4f9390, td-4ffd5e, roadmap td-1b73e4/td-a141df
- Verification commands and expected outcomes:

```bash
# Snapshot only: classify in_progress cards as linked-to-fleet, handoff-only or
# unlinked. This phase MUST NOT claim process liveness; that is Phase 4 evidence.
python3 scripts/gauntlet/inventory.py --classify-in-progress

# Must print zero: closed PR/merged-content cards still open in td.
python3 scripts/gauntlet/inventory.py --check-shipped-open

# Must print zero: duplicate dedupe keys with more than one non-closed card.
python3 scripts/gauntlet/inventory.py --check-duplicate-owners

# Must print a phase or explicit deferred trigger for every non-closed card.
python3 scripts/gauntlet/inventory.py --check-phase-coverage
```

- Evidence: pending; `scripts/gauntlet/inventory.py` does not exist yet. The
  original `--check-ownerless-in-progress` criterion was removed after critic
  round 1 found it depended on Phase 4 liveness and Phase 2 ownership, creating
  a cycle: 0 -> 4 -> 2 -> 1 -> 0.
- Largest remaining gap: 490-card inventory is untrusted

### Phase 1 — Durable attempt and evidence schema

- Status: pending
- Depends on: Phase 0 inventory vocabulary
- Builder scope: td-dc2cf2 and the attempt/evidence part of td-6986b6
- Critic input: serialized attempt state, event journal, restart recovery
- Verification commands and expected outcomes:

```bash
tests/sgt-attempt-evidence-test.sh                 # must PASS
tests/sgt-attempt-evidence-crash-test.sh           # must PASS at every injected boundary
tests/sgt-attempt-evidence-mutation-test.sh        # removing one event must FAIL
```

- Evidence: pending
- Largest remaining gap: recorded status is still treated as truth

### Phase 2 — Session ownership and multi-coordinator isolation

- Status: pending
- Depends on: Phase 1 stable identity/evidence
- Builder scope: td-dcb573 plus ownership aspects of td-a08ac8
- Critic input: two real coordinator panes, foreign mutation attempts
- Test substrate: Phase -1 only; "real" here means real processes in isolated
  tmux sockets and fleet roots, never the ambient coordinator sessions
- Verification commands and expected outcomes:

```bash
tests/sgt-session-ownership-test.sh                # must PASS
tests/sgt-session-ownership-drain-mutation.sh      # session A draining B must FAIL
tests/sgt-session-ownership-cleanup-mutation.sh    # session A cleaning B must FAIL
tests/sgt-session-ownership-handover-test.sh       # verified handover must PASS
```

- Negative mutation: replace `primary_pane_identity` with human-readable
  `primary_pane`; test must fail because `%2117` was observed recorded as the
  other session's `sergeant:1.0` window.
- Evidence: incident recorded in td-dcb573
- Largest remaining gap: fleet mutations are globally authorized

### Phase 3 — Dispatch launch contract

- Status: pending
- Depends on: Phase 1 evidence, Phase 2 ownership
- Builder scope: td-53834e, td-7f3a9a, td-b846a3 and generated-task rollback
- Critic input: branch collision, stale checkout, worktree failure, partial
  fleet publication
- Verification commands and expected outcomes:

```bash
tests/sgt-dispatch-test.sh
tests/sgt-dispatch-branch-collision-test.sh         # second dispatch must FAIL and leave no fleet dir
tests/sgt-dispatch-base-ref-test.sh                 # stale checkout must still base on origin/main
tests/sgt-dispatch-publication-crash-test.sh        # every boundary recovers exactly once
```

- Evidence: real failures reproduced 2026-08-05 under td-7f3a9a/td-b846a3
- Largest remaining gap: fleet state can publish before worktree creation

### Phase 4 — Worker lifecycle, response and wake recovery

- Status: pending
- Depends on: Phase 1 attempt schema, Phase 2 ownership
- Builder scope: td-af6916, td-e6eece, worker-lifecycle epic and response crash
  cards
- Critic input: SIGKILL between every state transition, stale `progress_ts`,
  tmux server restart
- Test substrate: Phase -1 only. Phase 4 is mutually exclusive with Phase 2 and
  Phase 6 at runtime because all three kill or recycle process/tmux/worktree
  resources; builders may work in parallel, destructive critic runs may not.
- Verification commands and expected outcomes:

```bash
tests/sgt-worker-test.sh
tests/sgt-response-crash-matrix-test.sh
tests/sgt-wake-condition-test.sh
tests/sgt-liveness-evidence-test.sh                 # active work with stale progress_ts must remain live
tests/sgt-tmux-restart-recovery-test.sh             # 48-commit-equivalent work survives and state is derived
```

- Precondition: every listed legacy test must have passed the Phase -1
  conformance gate and use `factory_env_new`. If not, this phase is blocked.

- Negative mutation: make liveness depend only on `progress_ts`; test must fail.
- Evidence: three false-stall incidents plus 2026-08-05 tmux restart
- Largest remaining gap: nonterminal records survive dead workers forever

### Phase 5 — Review/finding routing and validation boundary

- Status: pending
- Depends on: Phases 1, 3, 4
- Builder scope: td-e6f30b, td-c36f41, td-f9db2b, td-c653b8 and finding-router
  epics
- Critic input: installed no-mistakes capabilities, protected intent, overlong
  title, duplicate finding, same-axis rerun, lost review body
- Verification commands and expected outcomes:

```bash
tests/sgt-validate-test.sh
tests/sgt-validate-capability-probe-test.sh          # missing --intent-file must FAIL before pane launch
tests/sgt-review-findings-test.sh
tests/sgt-no-mistakes-finding-title-limit-test.sh   # long description still creates exactly one card
tests/sgt-finding-router-crash-matrix-test.sh
```

- Precondition: every listed legacy test must have passed the Phase -1
  conformance gate and use `factory_env_new`. If not, this phase is blocked.

- Evidence: `sgt-validate` exited 1 with zero runs because installed
  no-mistakes rejected `--intent-file`; router silently dropped findings beyond
  td's title cap
- Largest remaining gap: coordinator validation is structurally unavailable

### Phase 6 — Cleanup and terminal reconciliation

- Status: pending
- Depends on: Phases 1, 2, 4
- Builder scope: td-1b73e4, td-97b095, td-6f9d9a and cleanup roadmap cards
- Critic input: ledger directories, cross-device restore, closed-td orphan,
  leaked CWD processes, partial removal
- Test substrate: Phase -1 only. Destructive critic runs are mutually exclusive
  with Phase 2 and Phase 4.
- Verification commands and expected outcomes:

```bash
tests/sgt-cleanup-test.sh
tests/sgt-cleanup-cross-filesystem-test.sh
tests/sgt-cleanup-foreign-owner-test.sh             # unauthorized cleanup must FAIL
tests/sgt-cleanup-closed-td-cross-repo-test.sh      # must PASS from arbitrary coordinator cwd
tests/sgt-cleanup-process-leak-test.sh               # suite leaves zero fake agents
```

- Precondition: every listed legacy test must have passed the Phase -1
  conformance gate and use `factory_env_new`. If not, this phase is blocked.

- Evidence: PR #178 fixed directory evidence; 249 leaked fake agents then
  prevented cleanup of the task that spawned them
- Largest remaining gap: terminal state still depends on stale recorded status

### Phase 7 — End-to-end factory gauntlet

- Status: pending
- Depends on: Phases 0-6
- Builder scope: one harness only; no new features
- Critic input: fresh environment, two coordinators, full fault matrix
- Precondition: Phase -1 conformance test passes over every tmux-touching test;
  otherwise this harness is blocked and may not run.
- Verification command and expected outcome:

```bash
tests/agent-factory-gauntlet.sh --fresh --two-coordinators --all-faults
# must PASS twice consecutively from clean state
```

- The critic reruns with one guard mutation per subsystem. Each mutation must
  make the gauntlet fail for the named reason.
- Evidence: pending
- Largest remaining gap: harness does not exist

### Phase 8 — Backlog closure and smoothing

- Status: pending
- Depends on: Phase 7 verified
- Builder scope: reconcile td/PR/fleet state, documentation and release only
- Critic input: full repository, plan, backlog inventory, shipped main
- Verification commands and expected outcomes:

```bash
python3 scripts/gauntlet/inventory.py --all
tests/agent-factory-gauntlet.sh --fresh --two-coordinators --all-faults
shellcheck bin/* tests/*.sh
```

- Final smoothing critic checks that the independently improved lifecycle
  modules behave as one factory rather than separate mechanisms.
- Evidence: pending
- Largest remaining gap: all prior phases

## Decision log

- 2026-08-05: Adopt Gauntlet Loop. Hard bar is a reproducible two-coordinator
  fault-injection run, not card closure or agent self-assessment.
- 2026-08-05: Plans own intent; evidence owns progress. Phase status is never
  trusted after process loss without rerunning its commands.
- 2026-08-05: Initial Sergeant coordinator was pane `%2117`; tmux restart made
  that identity dead and pane ids were reused. Ownership must now be derived
  from exact pane identity + process start + durable handover, never a recorded
  pane number. Smith coordinator may add cards/evidence but may not mutate a
  foreign fleet without audited handover.
- 2026-08-05: Critic round 1 rejected the plan because no hermetic test substrate
  existed. Added Phase -1 before all backlog or factory work. Fault injection
  against the ambient tmux server/fleet is prohibited.
- 2026-08-05: Removed Phase 0's liveness verdict. Phase 0 classifies durable
  linkage only; Phase 4 derives liveness after Phase 2 establishes ownership.
- 2026-08-05: Critic round 2 found Phase -1 still escaped through user-systemd,
  `SERGEANT_CONFIG` drain state and split tmux socket strategies. Expanded the
  substrate to a closed boundary inventory and moved cross-owner refusal out of
  Phase -1 into Phase 2, removing cycle `-1 -> 2 -> 1 -> 0 -> -1`.
- 2026-08-05: Added Phase -3 to inventory existing worktrees before assigning
  builders. Current checkout HEAD is not an integration base; `origin/main` is.
- 2026-08-05: Critic round 3 found substrate use was optional and Phase -3 only
  detected existing work. Added a mandatory test-conformance gate, rescue and
  GitHub boundaries, migration of all tmux tests, and disposition/merge ownership
  for every existing branch before new builders.
- 2026-08-05: Critic round 4 found existing-work disposition could not ship
  because validation repair was deferred to Phase 5. Split read-only inventory
  from post-substrate disposition, made integration base re-baselining explicit,
  corrected the
  overclaim that zero tests isolate HOME.
- 2026-08-05: Critic round 5 found the bootstrap raced a live no-mistakes owner
  for `--intent-file` and still merged an existing branch before disposition.
  Split external dependency reconciliation (Phase -4), inventory (Phase -3),
  hermetic substrate (Phase -1), validation repair (Phase -0A), and disposition
  (Phase -0B). Added no-mistakes to the closed boundary set.
- 2026-08-05: Critic round 6 found three existing in-repo branches already
  implement the validation capability, and Phase -0A would have created a
  fourth. Reordered to inventory -> adopt/ship one canonical validation branch
  -> dispose all existing work -> build the substrate -> backlog work. Extended
  the no-overlap rule to every phase and corrected tmux-test counts to 21 files,
  six kill-session calls across five files.
- 2026-08-05: Critic round 7 found the repaired validation phase needed the
  substrate while the substrate was scheduled after validation/disposition.
  Split substrate creation from legacy-test migration: Phase -2 creates only new
  inert sandbox files, Phase -0A stacks the canonical validation repair on it
  and ships both under the bootstrap exception, Phase -0B disposes existing
  work, and Phase -1 then migrates the 21 conflicting legacy tests.
- 2026-08-05: Critic round 8 found Phase -2 duplicated two preserved isolation
  branches, Phase -3 missed 74 local-only branches, and the plan's own inventory
  scripts had no owner. Adopted `tests/global-state-isolation-test.sh` as the
  substrate base, expanded inventory to local refs/remote refs/worktrees, made
  early phases own their planning tools, and replaced kill-verb grep with a
  positive all-tmux-file conformance inventory.
- 2026-08-05: Critic round 9 found ref inventory omitted fleet ownership and the
  decision log trusted dead pane `%2117`. Added one row per fleet record,
  nonterminal response/wake/handover gating, exact identity/process-start
  liveness and a pane-reuse mutation. Fleet-wide sync remains prohibited.
- 2026-08-05: Final critic round 10 found fleet-owner reconciliation had no legal
  release path for the two dead orphaned records owning the canonical bootstrap
  branches. Added Phase -3.5: exact, per-record, human-approved owner handover
  derived from dead identity/process and immutable branch evidence. It records
  handover without rewriting historical worker status.
- 2026-08-05: Critic round 11 found Phase -3.5 hardcoded only two records while
  seven dead nonterminal records own phase work, and Phase -2 incorrectly
  required final disposition before its prerequisite phases. Made adjudication
  status-general and record-general, preserving status while transferring exact
  coordinator ownership; Phase -2 now requires handover and one canonical edit
  target, not final branch disposition.
- 2026-08-05: Critic round 12 found ownership mutation tests would edit live
  fleet files before isolation and race active monitors. Restricted every
  mutation to copied fixture fleets; real dry-run is read-only and approved real
  writes are one atomic handover marker with pre-image digest. Added Phase -1
  conformance as a hard prerequisite for the final fault harness.
- 2026-08-05: Critic round 13 proved the proposed existing isolation branch was
  inseparable from 2,683 lines of drain/wake product work. Rejected it as the
  substrate base and returned it to Phase -0B disposition. Phase -2 is strictly
  new-file-only; fixture liveness uses fake tmux rather than ambient panes.
- 2026-08-05: Critic round 14 found 126 committed changes reachable only from
  no-mistakes/gate refs, outside the origin-only baseline, plus a credential-
  bearing remote URL. Expanded Phase -3 to every configured remote, added trust
  classes and secret-safe URL digests, and clarified that execution shims never
  erase commit-store inventory.
- 2026-08-05: Critic round 15 found another 17 commits under
  `refs/recovery`, `refs/no-mistakes/recover` and stash, plus the plan itself was
  uncommitted and a remote URL carried a live credential. Expanded inventory to
  every ref namespace and reflog/stash, gave remote-secret rotation a P0 owner/
  command/pass condition, and clarified early tools execute from the foundation
  worktree before their bootstrap PR merges.
- 2026-08-05: Critic round 16 found clean-worktree handover was impossible for
  five dead owners, including uncommitted validation edits needed by Phase -0A.
  Granted Phase -3.5 narrow preservation-only authority: anchor tracked/index
  dirt under `refs/gauntlet/preserve/*`, archive untracked product files by
  content digest, preserve `.sergeant-*` evidence, and never modify the worker
  branch/index/worktree before handover.

## Round log

- Round 0: plan created from the verified incidents and backlog snapshot. No
  implementation started. First critic must attack phase decomposition and the
  quality bar before Phase 0 builder work begins.
- Round 1 critic: quality bar won. Largest gap was no isolated, reproducible
  substrate — the plan would have killed the real tmux server and mutated the
  live fleet. Also found the Phase 0 -> 4 -> 2 -> 1 -> 0 dependency cycle and
  destructive Phase 2/4/6 parallelism conflict. Challenge accepted: Phase -1,
  explicit mutual exclusion and snapshot-only Phase 0 added. Evidence report:
  `.gauntlet/rounds/plan/01-critic.md`.
- Round 2 critic: quality bar won. Phase -1 still leaked through user-systemd,
  drain state under `SERGEANT_CONFIG`, and incompatible tmux socket strategies;
  it also depended on Phase 2's cross-owner behavior and ignored overlapping
  in-flight worktrees. Challenge accepted: closed boundary inventory, Phase -1
  scope reduced to identity/root isolation, and Phase -3 reconciliation added.
  Evidence report: `.gauntlet/rounds/plan/02-critic.md`.
- Round 3 critic: quality bar won. Substrate use was optional, so the tests named
  as phase evidence could still kill the ambient tmux server; rescue and GitHub
  boundaries were unlisted. Phase -3 detected but did not dispose 166 unpushed
  commits across 20 branches. Challenge accepted: conformance test and migration
  of all tmux tests, closed boundary list, and an existing-work disposition/
  merge-order artifact that blocks new builders. Evidence report:
  `.gauntlet/rounds/plan/03-critic.md`.
- Round 4 critic: quality bar won. The first phase needed the broken validation
  gate whose repair was deferred to Phase 5; disposition also performed real-host
  mutations before Phase -1 and its fixed-base check would fail after the first
  successful merge. Challenge accepted: one-time bootstrap exception, Phase -3
  read-only inventory, Phase -1 isolation, Phase -0B gated disposition, and
  explicit re-baselining. Evidence report:
  `.gauntlet/rounds/plan/04-critic.md`.
- Round 5 critic: quality bar won. A live no-mistakes task already owned
  `--intent-file`, the bootstrap performed disposition before its owning phase,
  and no-mistakes itself was absent from the hermetic boundary. Challenge
  accepted: Phase -4 external-owner reconciliation, a no-mistakes shim in Phase
  -1, isolated repair in Phase -0A, and all real branch merges in Phase -0B.
  Evidence report: `.gauntlet/rounds/plan/05-critic.md`.
- Round 6 critic: quality bar won. Three preserved Sergeant branches already
  overlapped Phase -0A's exact files, so a fresh builder would create a fourth
  competing implementation. The substrate was also scheduled before disposing
  166 unpushed commits, guaranteeing test-file conflicts. Challenge accepted:
  Phase -0A adopts one canonical existing branch, Phase -0B disposes all work,
  then Phase -1 builds the substrate through the repaired gate. Evidence report:
  `.gauntlet/rounds/plan/06-critic.md`.
- Round 7 critic: quality bar won. Phase -0A depended materially on Phase -1's
  shims while Phase -1 depended on Phase -0B and Phase -0B on Phase -0A; moving
  the substrate after disposition also put destructive validation tests on the
  ambient server. Challenge accepted: inert new-file-only substrate first,
  validation repair stacked and shipped with it, disposition second, legacy
  test migration last. Evidence report: `.gauntlet/rounds/plan/07-critic.md`.
- Round 8 critic: quality bar won. Phase -2 recreated duplicate ownership by
  ignoring two existing isolation branches; inventory undercounted the branch
  surface by roughly five times; and the scripts required to run early phases
  had no owning phase. Challenge accepted: adopt the existing isolation test,
  inventory local/remote/worktree refs, own planning tools on the foundation
  branch, and positively enumerate all tmux-touching tests. Evidence report:
  `.gauntlet/rounds/plan/08-critic.md`.
- Round 9 critic: plan won the bar, with one pre-execution hardening challenge.
  Fleet records were absent from the owner map, while dead panes and reused pane
  numbers owned the canonical substrate/validation branches. Challenge accepted:
  fleet-record rows, exact identity/process-start liveness, per-record
  response/wake/handover before disposition, and pane-reuse mutation evidence.
  Evidence report: `.gauntlet/rounds/plan/09-critic.md`.
- Round 10 critic: quality bar won on one bootstrap deadlock. Canonical Phase -2
  and Phase -0A branches were owned by orphaned dead-pane records; every
  supported resume command refused their state, so Phase -2's first legal action
  was unreachable. Challenge accepted: exact per-record dead-owner adjudication,
  dry-run evidence, explicit human approval, handover marker without status
  rewrite, and pane-reuse mutation. Evidence report:
  `.gauntlet/rounds/plan/10-critic.md`.
- Round 11 critic: quality bar won. Adjudication covered only two dead records
  while at least seven dead nonterminal records owned phase work; Phase -2 also
  required a final disposition owned by Phase -0B, creating a hidden cycle.
  Challenge accepted: dry-run every nonterminal record, exact individually
  approved handover for any status, preserve historical status, and require
  owner transfer — not disposition — before Phase -2 edits. Evidence report:
  `.gauntlet/rounds/plan/11-critic.md`.
- Round 12 critic: quality bar won. Ownership mutation proofs edited live fleet
  fields while active monitors could rewrite the same path, recreating a cycle
  on isolation. Challenge accepted: copied fixture fleets for every mutation,
  before/after hashes proving live fleet immutability, and atomic handover-marker
  writes only after explicit approval. Evidence report:
  `.gauntlet/rounds/plan/12-critic.md`.
- Round 13 critic: quality bar won. The adopted isolation branch changed 13 files
  and depended on drain/wake product semantics, so the bootstrap PR would have
  smuggled Phase 4/6 work around disposition and critics. Challenge accepted:
  reject it as substrate input, keep it for Phase -0B, create a separable
  new-file-only substrate, and use fake tmux liveness for ownership mutations.
  Evidence report: `.gauntlet/rounds/plan/13-critic.md`.
- Round 14 critic: quality bar won. Inventory counted origin refs but missed 82
  no-mistakes refs with 124 unique non-merge commits plus 2 gate commits; one
  remote URL embedded a credential. Challenge accepted: inventory every remote,
  classify trust, own all unique commits, redact/digest URLs, and prevent
  execution shims from hiding commit stores. Evidence report:
  `.gauntlet/rounds/plan/14-critic.md`.
- Round 15 critic: quality bar won. Inventory remained namespace-blind: recovery,
  no-mistakes/recover and stash held 17 unique commits outside heads/remotes. The
  plan was uncommitted and credential rotation had no owner or pass condition.
  Challenge accepted: enumerate all refs/reflogs, own every unique commit,
  enforce secret-safe remotes, and execute early tools from the durable plan
  branch before it merges. Evidence report: `.gauntlet/rounds/plan/15-critic.md`.
- Round 16 critic: quality bar won. Handover required a clean worktree while
  ownership was required to preserve dirt, creating a cycle. Five dead records
  were dirty; the canonical validation branch had two tracked edits in exactly
  the files Phase -0A needs. Challenge accepted: non-destructive quarantine under
  a preservation ref plus untracked content archive, status unchanged, then
  audited handover. Evidence report: `.gauntlet/rounds/plan/16-critic.md`.
