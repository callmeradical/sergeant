# Plan critic — round 27

## Winner

Quality bar. The pinned Bash 3.2 environment could not run its assigned proof.

## Largest gap

The base image had Bash 3.2 and flock but lacked git, tmux and Python; the plan
also invoked a nonexistent `bash-3.2` executable.

## Exact challenge

Phase -2 owns a derived image installing required tools without upgrading bash,
plus a writable disposable checkout runner. Verify Bash remains 3.2 and run wake
and factory tests through its `bash`.
