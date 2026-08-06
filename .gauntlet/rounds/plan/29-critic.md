# Plan critic — round 29

## Winner

Quality bar. The defect was real but its recorded mechanism was false.

## Evidence

`bin/sgt-wake` enables `set -euo pipefail`. Under pinned Bash 3.2,
`declare -A _COND=()` exits 2 immediately; no condition field is read. Silent
field collapse occurs only when errexit is removed, which production never does.

## Exact challenge

Restore the associative array and require the Bash 3.2 test to fail at the named
declaration compatibility error. Restore the safe parser and require the full
wake test to pass. Record all three refs editing the wake test.
