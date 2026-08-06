# Plan critic — round 32

## Winner

Quality bar. A shipped fleet status had no owner in the plan.

## Largest gap

`drained` is written by workers, rejected as nonterminal by cleanup, but omitted
from inventory/adjudication. Four worktrees were unreachable; two held fourteen
dirty paths.

## Exact challenge

Inventory and adjudicate drained records. Cleanup refuses open/unpreserved cases
and accepts only closed, content-merged, preserved/clean cases with durable
evidence. Removing any safety predicate must fail. Correct the state taxonomy.
