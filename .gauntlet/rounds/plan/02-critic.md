# Plan critic — round 2

## Winner

Quality bar. The revised plan still permitted live-host mutation.

## Largest gap

Phase -1 did not contain all host-global state:

- `systemd-run --user` units are per-UID and can collide with live
  `sgt-watch-<task-id>.service` units;
- drain state derives from `SERGEANT_CONFIG` unless separately overridden;
- combining `TMUX_TMPDIR` and `tmux -L` creates different servers because
  production invokes bare `tmux`.

## Dependency defect

Phase -1 required two coordinators to fail closed on foreign fleets, which is
Phase 2's deliverable. That introduced cycle `-1 -> 2 -> 1 -> 0 -> -1`.

## Existing-work conflict

`git worktree list` showed overlapping cleanup, dispatch, validation and worker
lifecycle branches. The plan assigned builders without first reconciling those
owners, guaranteeing duplicate work and merge conflicts.

## Exact challenge

Use one tmux socket strategy; isolate `SERGEANT_CONFIG`, `SERGEANT_DRAIN_DIR`,
callback state and user-systemd commands; make boundaries self-auditing through
`tests/gauntlet/boundaries.txt`; and add a pre-phase reconciliation that maps
every existing worktree to exactly one owner and phase before any builder runs.
