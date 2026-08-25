# Proposal — Export runner starts when a backend is registered

## Repository

One repository: `sergeant` (v2).

## Requirements served

`docs/prd-export-runner-wiring.md` — closes the gap the independent critic
review of `task-tracking-is-a-readonly-export` found (`progress.html`,
Review 026): "`export.Runner` is fully built and fully tested but never
actually constructed/started in `cmd/sergeant/main.go` — it just logs a
warning."

This is not new product scope. `docs/prd-task-tracking-export.md` already
required exporting to be wired into the running process; the caveat is that
the wiring stopped at "recognize a configured project" and never reached
"start exporting for it."

## Problem

`cmd/sergeant/main.go:177-189`, `startExportRunners`, reads every configured
project via `config.ListProjects()` and, for each one with a non-nil
`Export` block, does exactly one thing: prints
`"export: project %q configures backend %q, but no export target
implementation is registered yet; skipping"` to stderr. It never calls
`export.Runner.Run`, never constructs a `Target`, and has no mechanism by
which it ever could — there is no registry, switch statement, or lookup of
any kind mapping a `Backend` name to anything.

This means: if a future change added a real `Target` implementation
tomorrow (a Linear backend, a webhook target, anything), nothing in
`main.go` would start using it. That future change would have to
rediscover this exact gap and fix `startExportRunners` itself, as
unplanned scope bolted onto whatever it was actually trying to add.

## Proposal

Add `internal/export.Backends`, a package-level registry
(`map[string]export.Constructor`, where `Constructor` is
`func(config.Export) (Target, error)`), starting empty. Change
`startExportRunners` to accept that registry as a parameter, look up each
configured project's `Export.Backend` name in it, and:

- **Found:** call the constructor, build an `export.Runner{Store: st,
  Target: target}`, and start `runner.Run(ctx)` in its own goroutine.
- **Not found** (true for every backend name today, since the registry
  starts empty): keep exactly today's warning, unchanged.

`main()` calls `startExportRunners(st, export.Backends)`. A future change
that adds a real backend registers it into `export.Backends` (via an
`init()` in its own package, or an explicit line where it's constructed) —
no change to `startExportRunners` itself is needed at that point.

## Out of scope

- **Implementing any real `Target` backend.** `docs/prd-task-tracking-export.md`
  already deferred this; this change does not revisit that decision.
- **Changing `export.Runner`, `export.Target`, `export.Record`, or the
  cursor/redaction mechanism.** Those are unchanged; this change only adds
  how a `Runner` gets constructed and started.
- **Stopping a running `Runner` on config reload, project removal, or
  process shutdown beyond context cancellation.** Today's process model
  starts exporters once at `startUI` and relies on process exit to stop
  them; graceful mid-process reconfiguration is not addressed here.
