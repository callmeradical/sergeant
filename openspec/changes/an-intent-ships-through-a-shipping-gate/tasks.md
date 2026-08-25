# Tasks — An intent ships through a shipping gate

One repository, `sergeant-v2`, so one task.

## Task 1 — intent-scoped shipping gate: config, store, runner, trigger

Repository: `sergeant-v2`. Depends on: nothing already merged is changed
by this task, but read the actual current code of
`a-sealed-bullet-awaits-explicit-approval` (`Store.SealBulletForRun`,
`internal/ui/server.go`'s `handleCreatePR`) and
`a-stuck-bullet-is-blocked-not-failed` (`BulletRecord.BlockedReason`'s
pattern) FIRST — this task extends the first's trigger point and mirrors
the second's field pattern; do not re-derive either from the proposal
prose alone, confirm the real merged signatures in `internal/store/store.go`
and `internal/ui/server.go` before writing new code against them, since
either could have changed shape since this change was drafted.

- Add `Project.ShippingGates map[string]string` to `internal/config/config.go`
  exactly as `design.md` specifies. No validation beyond what YAML
  unmarshaling already gives a `map[string]string` — an unset key is fine,
  matching `FactoryConfig.Gates`.
- Add `IntentRecord.ShippingGateStatus` and `ShippingGateReason` to
  `internal/store/store.go`, plus the `shipping_gate_status`/
  `shipping_gate_reason` columns via this file's existing
  `migrateAddColumns` idempotent-column pattern — read that pattern's
  current call site first and match it, do not invent a new migration
  mechanism.
- Add `AllBulletsSealedOrMerged(bullets []BulletRecord) bool` immediately
  after `DeriveIntentStatus`, exactly as specified (empty-set case returns
  `false`, unlike `DeriveIntentStatus`'s empty-set `"in_progress"` — the
  two functions answer different questions and must not share the same
  empty-case answer).
- Add `Store.RecordShippingGateResult(intentID string, passed bool, reason
  string) error`. A pass MUST overwrite any previously stored reason with
  empty, matching `BlockedReason`'s "empty unless status is blocked/failed"
  rule.
- Add `runner.RunShippingGate(ctx context.Context, name, command string,
  worktrees []string) (*GateResult, error)` to `internal/runner/runner.go`,
  sibling to (not a method on) `RunCodeGate`. Reuse `GateResult`,
  `redact.Text`, `redact.Truncate`, `maxRawOutputBytes`, `stripANSI`,
  `superviseGroup` exactly as `RunCodeGate` already does — read
  `RunCodeGate`'s real current body first, this task's implementation must
  match its redaction/timeout/output-capture behavior precisely, not
  approximate it.
- Wire the trigger into `handleCreatePR`: after the existing
  `SealBulletForRun` call succeeds, list the intent's bullets, check
  `AllBulletsSealedOrMerged`, and if true run the project's `ShippingGates`
  (or record an immediate pass if none configured) via
  `RecordShippingGateResult`, exactly as `design.md`'s trigger section
  specifies. Do not change `POST /api/create-pr`'s existing response shape
  or its handling of the PR-creation action itself — this is additive
  bookkeeping after the existing logic, not a replacement for any of it.

Do not implement: a dashboard UI element, a new HTTP endpoint (the new
`IntentRecord` fields are visible wherever an intent is already serialized
to JSON), re-evaluation triggered by anything other than the seal that
completes `AllBulletsSealedOrMerged`, or any change to `BulletRecord`,
`AdvanceBulletsForRun`, or `RunCodeGate`.

Verification: `go build ./... && go vet ./... && go test ./internal/... -count=1`.
(`go test ./internal/...` has pre-existing environmental failures in
`internal/graphify`, `internal/mcp`, `internal/ui` from a missing
`ANTHROPIC_API_KEY` — known, unrelated to this task; do not attempt to fix
them, confirm only that no NEW failures appear.)

Tests must cover every scenario in `specs/shipping-gate/spec.md` by name:

- "An intent with some bullets not yet sealed has no shipping-gate status"
  and "An intent with all bullets sealed evaluates its shipping gate" —
  call `AllBulletsSealedOrMerged` directly with constructed `[]BulletRecord`
  fixtures covering both cases; do not rely only on an HTTP-level test to
  exercise this predicate's branches.
- "No shipping gates configured records a pass with no command run" —
  assert via a real `RecordShippingGateResult` call and a recording wrapper
  (or equivalent seam) around wherever `RunShippingGate` would be invoked,
  proving zero invocations, not just checking the final stored status.
- "A shipping-gate failure leaves every bullet sealed" — a real
  `POST /api/create-pr` request completing the last seal of a multi-bullet
  intent, with a shipping gate configured to fail, followed by
  `ListBulletsForIntent` proving every bullet is still `sealed`.
- "A failed shipping gate records which check failed" and "A passing
  shipping gate records no reason" — call `RecordShippingGateResult`
  directly for both the pass and fail cases, asserting the stored
  `ShippingGateReason` in each.
- "A passing shipping gate triggers no merge action" — assert via the same
  no-subprocess-invocation recording seam used elsewhere in this project
  for asserting "did not call `gh`" (see
  `a-sealed-bullet-awaits-explicit-approval`'s test for the precedent): a
  passing shipping gate must not invoke `gh` or any merge-related command.

Exit status decides the outcome.
