# Tasks — A restarted coordinator reconciles orphaned runs

One repository, `sergeant-v2`, so one task and no cross-repo merge order.

## Task 1 — reconcile orphaned runs and phases at startup

Repository: `sergeant-v2`. Depends on: nothing.

- Add `interrupted` as a run status, include it in `ResumableStatuses`, and keep
  it out of `BulletProgression`.
- Add a store method moving every `running` run to `interrupted` and reconciling
  their `running` phases, returning what it changed.
- Call it from the server's startup path before the listener accepts connections.
- Log the count when non-zero and append the transitions to the change sequence.
  Report nothing when nothing was reconciled.
- Never reconcile outside startup.

Verification: `go build ./... && go vet ./... && go test ./internal/... -count=1`.
Tests must cover a running run becoming interrupted, terminal runs untouched, a
reconciled phase being re-run rather than skipped on resume, `interrupted` being
absent from `BulletProgression`, and nothing being reported when nothing was
reconciled. Exit status decides the outcome.
