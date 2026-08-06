# Plan critic — round 26

## Winner

Quality bar. The terminal shell gate could never exit zero.

## Largest gap

`shellcheck bin/* tests/*.sh` included Python `bin/sgt-callback` and a tracked
`bin/__pycache__` directory, producing SC1071/directory errors before shell
findings. Phase -2's baseline used an explicit shell list, so phases disagreed.

## Exact challenge

Use one committed shell inventory everywhere; route Python through Ruff and
compile checks; untrack/ignore bytecode; drive the ShellCheck baseline to zero
before terminal closure.
