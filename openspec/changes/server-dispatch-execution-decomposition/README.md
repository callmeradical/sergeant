# server-dispatch-execution-decomposition

Extracts `handleDispatch`/`createRunAndDispatch`/`executeRun` and their
support functions — the run-execution state machine, the largest and
riskiest undivided block left in `internal/ui/server.go` — into their own
file, characterization-tested first, behind one narrow interface seam that
lets a test substitute a fake stage runner instead of a real `*dag.Engine`.
