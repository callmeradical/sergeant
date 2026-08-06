# Plan critic — round 3

## Winner

Quality bar. Three of four clauses passed; live-host isolation remained
unproven.

## Largest gap

Phase -1 supplied a substrate but did not require any test to use it. Fifteen
tests invoked ambient tmux and four issued `tmux kill-session`; three were named
as later phase evidence. No test isolated HOME. The plan could therefore pass
its substrate test and still run destructive critics on the live factory.

Unlisted external boundaries also remained: the real rescue directory and real
GitHub via bare `gh`.

## Existing-work conflict

Twenty branches held 166 unpushed commits, eight worktrees were dirty and no PR
was open. Phase -2 detected them but did not own disposition, while later phases
assigned builders to the same scopes.

## Exact challenge

Add a conformance test that fails with file:line for every test bypassing
`factory_env_new`, migrate all tmux tests, isolate rescue and GitHub, and require
every existing worktree to have one merge/preserve/supersede/discard disposition
before a new builder starts on an overlapping scope.
