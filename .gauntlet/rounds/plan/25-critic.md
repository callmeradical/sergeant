# Plan critic — round 25

## Winner

Quality bar. A shipped Bash 3.2 defect had no owner.

## Largest gap

`sgt-wake` uses `declare -A`; under Bash 3.2 every condition field silently
collapses to the last-written value. Existing pinned coverage omits wake. Full
ShellCheck also fails on pre-existing findings, so the new CI gate was not
executable.

## Exact challenge

Give the bootstrap narrow authority to replace the wake parser with Bash-3.2-
safe logic and prove restoring the associative array fails. Record existing
ShellCheck findings as a no-regression baseline, then require backlog waves to
reduce it to zero before terminal closure.
