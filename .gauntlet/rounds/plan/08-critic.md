# Plan critic — round 8

## Winner

Quality bar. The plan remained non-executable at its first builder phase.

## Largest gap

Two existing branches already implement isolation work, including a 372-line
`tests/global-state-isolation-test.sh`, while Phase -2 proposed a new parallel
framework without an overlap check.

## Inventory defect

The earlier baseline counted only worktrees and some remote branches. The real
surface was 102 local branches, 80 remote refs, 397 non-merge commits and 74
local-only branches with commits. Phase -3's schema omitted most of them.

## Tool ownership defect

`reconcile-external.py`, `reconcile-work.py` and `inventory.py` were required by
early phases but no phase owned writing or shipping them.

## Exact challenge

Adopt the existing isolation test; phase-gate its two overlapping branches;
inventory every local ref, remote ref and worktree; carry planning tools on the
foundation branch; and enforce conformance by enumerating every tmux-referencing
test rather than grepping only destructive verbs.
