# Plan critic — round 18

## Winner

Quality bar. The quarantine command violated its own no-mutation rule.

## Largest gap

`git stash create` rewrote `.git/index` while `git status` stayed unchanged, so
the plan's check could not detect the mutation. It also failed on unmerged
indexes with no fallback.

## Exact challenge

Capture exact index bytes, binary patches, stage blobs and untracked files;
construct optional preservation commits only through a temporary index; prove
live index/worktree hashes unchanged. Prove both git transport and GitHub API
identity/push permission before and after credential rotation.
