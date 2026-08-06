# Plan critic — round 1

## Winner

Quality bar. The plan as written could not prove it.

## Largest gap

No isolated, reproducible test substrate. The fault matrix required tmux server
death and two coordinators but did not define disposable tmux sockets, fleet
roots, HOME, td database or git origin. Running it would mutate the 24 real fleet
records and kill the coordinator judging the run.

## Evidence

- No existing test references `tmux -L`, `tmux -S` or `TMUX_TMPDIR`.
- Fifteen test files invoke tmux.
- `SERGEANT_FLEET` is configurable, but pane identity remains bound to ambient
  `$TMUX_PANE` in `sgt-validate`.
- Twenty-one of the twenty-seven verification artifacts named by the plan do
  not exist. That is expected and was not the rejection reason.

## Dependency defect

Phase 0's ownerless-live-worker criterion depended on Phase 4 liveness and Phase
2 ownership, while Phase 4 depended on Phase 2, Phase 2 on Phase 1, and Phase 1
on Phase 0: `0 -> 4 -> 2 -> 1 -> 0`.

## Parallelism defect

Phases 2, 4 and 6 each kill or recycle tmux/process/worktree resources. They
cannot run destructive critics concurrently, and none may run against the
ambient server.

## Exact challenge

Create Phase -1 with `tests/lib/factory-env.sh`, disposable tmux socket, fleet,
HOME, td database and bare origin. Prove host sentinels remain byte-identical
after sandbox tmux death and two-coordinator cross-ownership attempts. Mutating
the socket or fleet path back to ambient defaults must make the isolation test
fail with a named leak.
