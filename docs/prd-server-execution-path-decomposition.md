# Product Requirements: Server Execution-Path Decomposition

Status: Draft, awaiting explicit human PRD approval

Extends: the `internal/ui/server.go` decomposition already landed this
session (`refine.go`, `bulletstate.go`, `fleet.go`, `gitutil.go`,
`delivery.go`), which stopped deliberately before this exact block.

## Summary

The prior decomposition pass reduced `server.go` from 2,536 to 1,842 lines
(68 to 43 functions) by extracting four cohesive, lower-risk groups behind
small interface seams. It stopped before the largest and highest-stakes
block — `handleDispatch`/`createRunAndDispatch`/`executeRun` (the actual
run-execution state machine) and the plans/bullets-approval,
workflow/DAG-discovery, and run-cancel/resume/delete groups — because
splitting them safely requires characterization tests pinning today's
external behavior first, and a single pass didn't have room to do that
rigorously for the riskiest code in the file without rushing it. This PRD
authorizes that follow-up work explicitly.

## Problem

`handleDispatch` and its companions remain the largest undivided block in
`internal/ui/server.go`, reaching directly into `*store.Store` and
constructing `*runner.PhaseRunner`/dag engine calls inline, the same
"awkward, untestable-in-isolation dependency" shape the already-extracted
groups had before their own seams were added. This is also the code every
dispatch in today's four-change implementation batch actually ran through —
the highest-traffic, most load-bearing path in the file, and currently the
least independently testable one.

## Proposal

Apply the same discipline the prior pass already established, to the
remaining groups:

1. **Characterize before touching.** For each group (dispatch/execution;
   plans and bullets-approval; workflow/DAG-discovery; run-cancel/resume/
   delete), write tests pinning its current externally-observable behavior
   — HTTP routes, response shapes, status codes, background timing — before
   any code moves. A group with no existing test already covering a given
   behavior gets one first; this PRD does not accept "it looked the same"
   as verification.
2. **Extract one cohesive group at a time**, each into its own file, with a
   small (1-3 method) interface seam defined at the group's actual
   dependency need — mirroring `fleetRunSource`/`runGetter` exactly, not a
   larger or more speculative abstraction.
3. **No external behavior change.** Every route, response shape, and
   background loop must behave identically before and after each
   extraction, proven by the characterization tests from step 1 passing
   unmodified afterward.
4. **One extraction per commit**, `go build && go vet && go test` clean
   after each, matching how the prior pass was done.

## Out of scope

- **Changing any HTTP contract, route, or response shape.** This is a pure
  internal restructuring; if a genuine behavior change is warranted, that's
  a separate PRD.
- **A full rewrite or a different execution model for dispatch.** This PRD
  is about testability and file organization, not the run-execution design
  itself.
- **Extracting groups this PRD doesn't name**, if the implementer finds
  them while working. A tempting adjacent group is a new PRD, not scope
  creep on this one.

## Open questions

- Should the four groups this PRD names be four separate OpenSpec changes
  (mirroring the one-cohesive-group-per-commit granularity the prior pass
  used) or one change with four tasks? Given `handleDispatch` and its
  companions are the largest, riskiest group, splitting it into its own
  change — separate from the other three — may be warranted so a
  characterization-test gap discovered there doesn't block the smaller,
  lower-risk groups. Left to OpenSpec's `design.md`/`tasks.md` to decide.
