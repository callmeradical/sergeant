# Design — Export runner starts when a backend is registered

## Ownership

One repository, `sergeant` (v2). Standalone. Adds
`internal/export/registry.go` (new file) and changes
`cmd/sergeant/main.go`'s `startExportRunners` and its one call site.

## `internal/export.Backends`: a package-level registry, not a threaded parameter

```go
// internal/export/registry.go
package export

import "github.com/callmeradical/sergeant/internal/config"

// Constructor builds a Target for one project's export configuration.
type Constructor func(cfg config.Export) (Target, error)

// Backends is the process-wide registry of named export backend
// constructors, keyed by config.Export.Backend. It starts empty — no
// Target implementation exists yet, which docs/prd-task-tracking-export.md
// already decided is correctly out of scope until a concrete external
// tracker is chosen. A future backend registers into this map from its own
// package (an init(), or an explicit call before cmd/sergeant/main.go's
// startExportRunners runs), so adding a backend never requires editing
// startExportRunners again.
var Backends = map[string]Constructor{}
```

`internal/config` does not import `internal/export` or `internal/store`
(confirmed: neither name appears in `internal/config/*.go` outside a
comment), so `internal/export` importing `internal/config` for the
`Constructor` signature introduces no import cycle.

A package-level map, not a parameter threaded from `main()` through every
call site down to wherever a backend is implemented: every future backend
needs to reach the same registry regardless of how deep in the call graph
it's constructed, and a write-once-at-process-startup registration is
exactly the shape a package-level variable already fits elsewhere in Go's
standard library convention (`database/sql`'s driver registry is the same
shape). `startExportRunners` itself, however, takes the registry as a
parameter — see below — so a test never has to touch the shared global.

## `startExportRunners` takes the registry as a parameter

```go
// cmd/sergeant/main.go
func startExportRunners(st *store.Store, backends map[string]export.Constructor) {
	projects, err := config.ListProjects()
	if err != nil {
		fmt.Fprintf(os.Stderr, "export: listing projects: %v\n", err)
		return
	}
	for _, proj := range projects {
		if proj.Export == nil {
			continue
		}
		ctor, ok := backends[proj.Export.Backend]
		if !ok {
			fmt.Fprintf(os.Stderr, "export: project %q configures backend %q, but no export target implementation is registered yet; skipping\n", proj.Name, proj.Export.Backend)
			continue
		}
		target, err := ctor(*proj.Export)
		if err != nil {
			fmt.Fprintf(os.Stderr, "export: project %q backend %q: %v\n", proj.Name, proj.Export.Backend, err)
			continue
		}
		runner := &export.Runner{Store: st, Target: target}
		go func(projectName string) {
			if err := runner.Run(context.Background()); err != nil {
				fmt.Fprintf(os.Stderr, "export: runner for project %q stopped: %v\n", projectName, err)
			}
		}(proj.Name)
	}
}
```

Call site (`startUI`, line 162): `startExportRunners(st, export.Backends)`.

Taking `backends` as a parameter — rather than reading `export.Backends`
directly inside the function — means a test can pass a local map
containing only a test-registered `Constructor`, proving the lookup →
construct → start path works without ever mutating the shared package-level
registry, so no test can leak a registration into another test's run.

`export.Runner.Run` (existing, unchanged) already calls `r.Tick(ctx)`
**before** entering its `select` on the ticker — the first tick happens
immediately when `Run` starts, not after waiting out the first poll
interval. This matters for testability: a test starting the goroutine can
observe at least one delivery attempt with a short bounded wait (well under
a second in practice), not a wait tied to `defaultInterval` (5s).

## Rejected alternatives

**A hardcoded `switch proj.Export.Backend { case "...": ... }` instead of a
registry.** Rejected: there is no real backend name to switch on yet — any
case added now would have to name an invented, non-existent backend just to
have something to switch on, which is exactly the kind of guessed scope the
originating PRD explicitly deferred. A registry that starts empty needs no
such invention and is equally ready the day a real backend exists.

**Reading `export.Backends` directly inside `startExportRunners` instead of
taking it as a parameter.** Rejected for testability: a global registry
read directly would force every test to mutate (and clean up after
mutating) shared package state, risking cross-test leakage the moment two
tests run without careful ordering. Taking it as a parameter costs nothing
in production (`main()` passes the real registry once) and buys tests full
isolation.

**Registering a fake/no-op backend in production code so the registry
"has something in it."** Rejected: `docs/prd-export-runner-wiring.md`
explicitly keeps implementing any real `Target` out of scope; inventing a
fake one to populate the registry would be scope creep disguised as
completeness. The registry is fully testable empty, via a test-local
registration that never touches production code (see
`specs/export-wiring/spec.md`).

**Storing the started `*export.Runner`s somewhere for later inspection or
graceful shutdown.** Rejected: `docs/prd-export-runner-wiring.md`
explicitly puts "stopping a running Runner on config reload" out of scope;
adding storage for a capability nothing yet needs would be speculative.
