# Product Requirements: Export Runner Wiring

Status: Draft, awaiting explicit human PRD approval

Extends: `docs/prd-task-tracking-export.md` (task-tracking-is-a-readonly-export),
whose independent critic review (`progress.html`, Review 026) found this gap.

## Summary

`task-tracking-is-a-readonly-export` built `internal/export.Runner` — a poll
loop that delivers intent/bullet transitions to a configured `Target` —
fully implemented and fully tested. It also correctly deferred choosing a
concrete `Target` backend, since no external tracker was specified. But
`cmd/sergeant/main.go`'s `startExportRunners` never constructs or starts a
`Runner` at all; it only logs a warning for a project that configures an
export backend. This PRD closes that gap: when a backend a future change
registers exists, the process must actually start exporting for it, with no
further wiring work required at that point.

## Problem

Today, even if a future change added a working `Target` implementation
tomorrow, nothing in `cmd/sergeant/main.go` would ever construct one or call
`Runner.Run`. The wiring gap is independent of which backend eventually
exists — it's a missing registration/dispatch mechanism, not a missing
backend. Left as-is, the first change to implement a real `Target` would
also have to rediscover and fix this same wiring gap, duplicating this
PRD's work as an unplanned side effect of unrelated scope.

## Proposal

Add a backend registry that decouples "a `Target` implementation exists"
from "a project's `export.backend` name is known": a name-keyed map of
constructors (`func(config.Export) (export.Target, error)`), starting empty
(no backends registered yet — that remains correctly out of scope, per the
originating PRD). `startExportRunners` looks a configured project's backend
name up in the registry:

- **Registered:** construct the `Target`, build an `export.Runner`, and
  start `Runner.Run` in its own goroutine alongside the HTTP server —
  exactly the wiring design.md already described for
  task-tracking-is-a-readonly-export, just actually executed.
- **Not registered** (today, always — the registry starts empty): keep the
  existing behavior of logging that the project configures an unknown
  backend, unchanged.

Because the registry can start with zero entries, this PRD is fully
testable without any real backend: a test-only `Target` registered in a
test, not in production code, is enough to prove the registry-to-running-
goroutine path actually works end to end.

## Out of scope

- **Implementing any real `Target` backend.** Still deferred, as the
  originating PRD already decided.
- **Changing `export.Runner`, `export.Target`, or the cursor/redaction
  mechanism task-tracking-is-a-readonly-export already built and shipped.**
  This PRD is purely about the registration/startup path.
- **Stopping a running `Runner` on config reload or project removal.**
  Today's process model starts exporters once at `startUI`; graceful
  reconfiguration without a restart is not addressed here.

## Open questions

None blocking — the registry itself needs no backend-specific decision to
implement or test.
