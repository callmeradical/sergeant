# Tasks — A stuck bullet is blocked, not failed

One repository, `sergeant-v2`, so one task.

## Task 1 — blocked status, reason capture, redaction

Repository: `sergeant-v2`. Depends on: nothing. Read
`internal/ui/server.go`'s `bulletStatusForRunOutcome`/`recordTerminalRun`,
`internal/store/store.go`'s `BulletStatuses`/`AdvanceBulletsForRun`, and
`internal/runner/runner.go`'s agent-authored-envelope branch and its
existing `redact.JSON(env.Payload)` call first.

- Add `"blocked"` to `store.BulletStatuses()`, documented the same way
  `"failed"` is (reachable from any earlier state).
- Add `BlockedReason string` to `BulletRecord`.
- In `RunAgentPhase`, read an optional `blocked_reason` string out of
  `env.Payload` (after it has already been redacted) when present, and
  make it available to the caller alongside the existing return value —
  do not add a new top-level `Envelope` field for this (see design.md's
  rejected alternatives).
- Change `bulletStatusForRunOutcome`'s `"failed"` case to `"blocked"`, and
  thread a reason through to the bullet write: the agent-reported one when
  present, otherwise a synthesized one that is never empty.
- Do not change the `"passed"` (`green`) or default (no-op) cases.
- Do not build a resume/unblock action, a reason taxonomy, or any
  historical-row migration.

Verification: `go build ./... && go vet ./... && go test ./internal/... -count=1`.
Tests must cover every scenario in `specs/blocked-bullets/spec.md`: an
agent-reported reason is recorded verbatim on the bullet; a run with no
agent-reported reason still produces `blocked` with a non-empty synthesized
reason; a passing run still produces `green` (regression check); a
cancelled run still moves no bullet (regression check); a secret-shaped
agent-reported reason is redacted in the persisted `BlockedReason`, not
left verbatim — assert this the same way this session has asserted
redaction elsewhere: the specific secret is absent AND the placeholder is
present, not merely that *some* transformation occurred. Exit status
decides the outcome.
