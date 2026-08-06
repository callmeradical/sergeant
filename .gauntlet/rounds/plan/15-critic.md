# Plan critic — round 15

## Winner

Quality bar. Inventory remained namespace-blind.

## Largest gap

`refs/recovery`, `refs/no-mistakes/recover` and stash held 17 unique commits
outside every local and remote branch. The plan's schema could pass while losing
work stored under namespaces literally named recover/orphans.

A configured remote URL also carried a live credential, and the directive to
rotate it had no owner, command or pass condition.

## Exact challenge

Inventory all refs and reflogs/stash, requiring an owner for every unique commit.
Block fetch on credential-bearing URLs, create one P0 owner, and require a
credential-free URL before proceeding. Persist and execute planning tools from
the foundation worktree rather than waiting for a later merge.
