# Plan critic — round 24

## Winner

Quality bar. Bash 3.2 and CI were vacuous bar elements.

## Largest gap

No CI workflow existed. Only two of 42 test files ran under pinned Bash 3.2, and
one was scheduled for migration. All plan gates could pass after introducing
Bash-4-only syntax into the core substrate.

## Exact challenge

Phase -2 owns CI and a pinned Bash 3.2 runner for every new/migrated Gauntlet
file. Phases -1/7/8 rerun it. Adding `declare -A` to `factory-env.sh` must make
the Bash 3.2 gate fail, then restore green.
