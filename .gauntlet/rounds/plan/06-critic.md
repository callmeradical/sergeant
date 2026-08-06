# Plan critic — round 6

## Winner

Quality bar. The critical path was valid but still duplicated existing owners.

## Largest gap

Three preserved branches already edit `bin/sgt-validation-worker` and its tests:
one with four commits and two with one. Phase -0A was exempt from the overlap
rule and would have created a fourth implementation before Phase -0B disposed
the first three.

## Ordering defect

Phase -1 planned to rewrite 21 tmux-touching tests before Phase -0B integrated
19 existing branches, several of which edit those same large test files. The
result would be guaranteed conflict and duplicate ownership.

## Exact challenge

Extend overlap enforcement to every phase. Inventory first; adopt one existing
validation branch as canonical and ship it under the bootstrap exception;
dispose all remaining branches through the repaired gate; only then build the
hermetic substrate. A phase-specific overlap check must fail today naming all
three branches and pass only when their disposition is durable.
