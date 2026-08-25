# Tasks — A green bullet awaits independent review

One repository, `sergeant-v2`, so one task.

## Task 1 — special-case a review phase, route blocking findings through the existing blocked path

Repository: `sergeant-v2`. Depends on: nothing (reuses
`a-stuck-bullet-is-blocked-not-failed`'s already-merged mechanism as-is,
does not modify it). Read first: `internal/dag/engine.go`'s `RunStage`
(the `"test"` case, lines ~332-365, is the pattern to mirror),
`internal/handoff/envelope.go`'s `BlockedReason` (the pattern to mirror for
`ReviewFindings`), and `internal/ui/server.go`'s `recordTerminalRun` /
`bulletStatusForRunOutcome` / `blockedReasonForRun` (lines ~2250-2320, the
existing path this task's blocking case must land in without modification
to its bullet-status logic, only to how it sources a reason).

- Add `ReviewFinding` (fields `Axis`, `Severity`, `Summary`, `Disposition`,
  all `string`), `ReviewFindings(payload json.RawMessage) []ReviewFinding`,
  and `HasBlockingFinding(findings []ReviewFinding) bool` to
  `internal/handoff/envelope.go`, exactly as specified in design.md.
- Add `PhaseRunner.DiffAgainstBase(ctx) (string, error)` to
  `internal/runner/runner.go`, exactly as specified in design.md
  (`git diff --merge-base HEAD` in `pr.Worktree`).
- Add a `reviewPrompt` helper and a `"review"` case to `RunStage`'s phase
  switch in `internal/dag/engine.go`, exactly as specified in design.md:
  skip if already passed (`e.phasePassed`, same as every other phase),
  collect the diff, build the prompt from diff + stage/repo only (no
  envelope parameter — this is what makes independence structural, not
  conventional), dispatch via the existing `PhaseRunner.RunAgentPhase`, and
  return an error (failing the phase, matching `"test"`'s existing
  behavior for a failed gate) when `handoff.HasBlockingFinding` is true for
  the returned envelope's payload.
- In `internal/ui/server.go`'s `blockedReasonForRun`, when an envelope's
  `Stage` is `"review"` and `handoff.ReviewFindings` on its payload
  contains any blocking finding, use those findings' summaries (joined) as
  the reason instead of falling through to `handoff.BlockedReason` /the
  synthesized string for that envelope — preserve the existing "last
  envelope naming a reason wins" precedence for envelopes overall.
- Do not add `"review"` to `DefaultPipeline()`. Do not change
  `AdvanceBulletsForRun`, `UpdateBulletStatus`, `bulletStatusForRunOutcome`,
  or any bullet status/schema. Do not add a dashboard UI element for
  findings. Do not implement per-axis review phases.

Verification: `go build ./... && go vet ./internal/... && go test ./internal/... -count=1`.
`internal/graphify`, `internal/mcp`, and `internal/ui` have pre-existing
environmental test failures (missing `ANTHROPIC_API_KEY`) unrelated to this
task — confirm no new failures beyond that known set, do not attempt to fix
them.

Tests must cover every scenario in `specs/independent-review/spec.md` by
name:

- "A pipeline with no review phase runs unchanged" — a `RunStage` test with
  no `"review"` in `Factory.Pipeline` asserting no review-related call
  occurs and the run's outcome is identical to today's behavior (a
  regression-style test against existing pipeline test fixtures).
- "A review phase is dispatched with the diff, not prior envelopes" and
  "The review prompt builder has no access to prior envelopes" need **the
  same test, exercised directly against `reviewPrompt`'s real function
  signature** — call it directly with a diff string and assert the earlier
  phases' actual envelope summary text is absent from the result. Testing
  only through `RunStage`'s full pipeline would not prove the exclusion is
  structural (the function's signature, not a convention); test the
  function's signature directly as well.
- "A blocking finding blocks the bullet with the finding's summary as the
  reason" and "Multiple blocking findings still produce one recorded
  reason" — call the real mechanism directly: construct a review-phase
  envelope with one and with multiple `severity: "error"` findings, run it
  through `blockedReasonForRun` and `AdvanceBulletsForRun` (or the full
  `recordTerminalRun` path, whichever the existing blocked-bullet tests
  already exercise) and assert the resulting `BulletRecord.BlockedReason`.
- "An info or warning finding does not block the bullet" — assert
  `HasBlockingFinding` returns false for an all-non-error findings slice,
  and that a `RunStage` review phase with only such findings does not
  return an error.
- "Recorded findings are readable after the run concludes" — assert
  `handoff.ReviewFindings` correctly round-trips a findings payload written
  through the same envelope-recording path other phases already use
  (`ListEnvelopesForRun` or equivalent), not just via a hand-built
  in-memory struct.

Exit status of the verification command decides the outcome.
