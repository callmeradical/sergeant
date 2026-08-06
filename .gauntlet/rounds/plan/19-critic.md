# Plan critic — round 19

## Winner

Quality bar. Bootstrap validation still mutated the live tmux server.

## Largest gap

Phase -0A had to run `sgt-validation-worker-test.sh`, and Phase -0B had to test
existing branches, before Phase -1 migrated their bare tmux calls. A leaked
two-window validation test session was present on the live server; cleanup tests
previously leaked 249 fake agents.

## Exact challenge

Phase -2 provides `factory-env-run` so unchanged tests inherit isolated
TMUX_TMPDIR/HOME/fleet/shims and process-group cleanup. Running validation and
cleanup tests through it must leave ambient tmux sessions, real fleet hashes and
leaked-process baseline unchanged, while the sandbox leaves zero children.
