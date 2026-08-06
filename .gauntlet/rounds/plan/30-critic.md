# Plan critic — round 30

## Winner

Quality bar. The mutation seam could not distinguish broken from working code.

## Largest gap

`sgt-wake-test.sh` wrapped all 21 cases in bare subshells. Assertion failure
exited only the child; the parent continued and printed success. Eight failures
under Bash 3.2 still returned exit 0.

## Exact challenge

Explicitly propagate every case status, add a forced-assertion self-test that
must exit nonzero, and add a dedicated Bash 3.2 compatibility test that captures
the associative-array error without stderr suppression. Safe parser must then
reach and evaluate a named wake condition.
