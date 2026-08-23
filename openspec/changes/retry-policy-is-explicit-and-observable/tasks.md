# Tasks — Retry policy is explicit and observable

One repository, `sergeant-v2`, so one task and no cross-repo merge order.

## Task 1 — configure, apply and record agent phase retry

Repository: `sergeant-v2`. Depends on: nothing.

- Add `retries` to `config.Defaults` and `config.Repo`, resolved repository-first
  then project default then zero, matching how the agent name resolves today.
- Pass the resolved value at the call site in `internal/dag/engine.go` that
  currently hardcodes `0`.
- Leave deterministic gates unretried.
- Record an attempt number on each phase record and populate it per attempt.
- Do not change behaviour for a configuration that omits the field.

Verification: `go build ./... && go vet ./... && go test ./internal/... -count=1`.
Tests must cover the absent case preserving one attempt, a repository override, a
failing phase stopping at the configured limit, a gate running exactly once under
a non-zero policy, and a retried phase leaving both a failed and a passed record
with different attempt numbers. Exit status decides the outcome.
