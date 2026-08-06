# Plan critic — round 16

## Winner

Quality bar. The handover clean-tree precondition was unsatisfiable.

## Largest gap

Five dead records carry product dirt. The canonical validation branch has five
commits plus two tracked uncommitted edits in `sgt-validate` and
`sgt-validation-worker`. Preserving that work required ownership, while gaining
ownership required a clean tree.

## Exact challenge

Grant pre-handover preservation-only authority: capture tracked/index state under
an anchored `refs/gauntlet/preserve/<task>` commit, archive untracked product
files content-addressably, leave branch/index/worktree byte-identical, verify all
digests, then write the approved handover marker. Corruption or unanchored state
must fail before handover.
