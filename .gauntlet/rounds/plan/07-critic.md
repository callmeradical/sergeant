# Plan critic — round 7

## Winner

Quality bar. The declared DAG was acyclic but the artifacts created a material
cycle.

## Largest gap

Phase -0A required hermetic no-mistakes shims created only in Phase -1, while
Phase -1 depended on disposition and disposition depended on Phase -0A.
Validation and merge tests therefore still ran against the ambient tmux server.

## Live evidence

`sgt-validation-worker-test-812601` remained orphaned on the default socket
beside the live coordinator sessions — direct evidence that these tests mutate
the host.

## Exact challenge

Create a new-file-only inert substrate before validation repair; stack and ship
the repair on that substrate under the bootstrap exception; dispose existing
branches through the repaired gate; migrate the 21 legacy tests only after their
overlapping branches are resolved. Prove ambient tmux sessions are byte-identical
before and after Phase -0A/-0B.
