# Plan critic — round 5

## Winner

Quality bar. The critical-path root was real but scoped to the wrong owner.

## Largest gap

A live no-mistakes task (`td-cc69e3`, branch
`feat/ship-intent-file-onto-current-main`) already owns `--intent-file`. The
Sergeant plan did not reconcile it and proposed a fallback that upstream work
could supersede.

The bootstrap also merged an existing branch before substrate and disposition,
relocating rather than removing the dependency cycle.

## Boundary defect

No-mistakes was absent from the closed isolation set. Production hardcoded
`command -v no-mistakes`, and tests could reach the installed binary and real
pipeline state. Both capability variants were untestable hermetically.

## Exact challenge

Reconcile the upstream owner first; add no-mistakes indirection and shim to the
substrate; repair validation in its own phase; move all existing-branch merges
to the post-substrate disposition phase.
