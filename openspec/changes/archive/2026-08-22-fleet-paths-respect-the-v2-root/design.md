# Design — Every fleet path resolves through one helper

## Ownership and merge order

One repository, `sergeant-v2`, so a single bullet and no cross-repo merge order.

## The helper

`internal/dag` already owns this knowledge. Add:

```go
// FleetRoot is the base directory for all run state.
func FleetRoot() string
```

It resolves `SERGEANT_FLEET_DIR`, else `~/.local/share/sergeant-v2/fleet`.
`FleetDir(runID, repoName)` becomes `filepath.Join(FleetRoot(), runID, repoName)`,
so the two cannot disagree.

Export it rather than keeping it internal, because `internal/ui` is the package
getting it wrong and needs to call it.

## Call sites

Replace all four hand-built paths in `internal/ui/server.go` with `dag.FleetRoot()`
or a join on it. The already-correct one at line 1507 is included: leaving a
correct duplicate in place preserves the failure mode this change exists to
remove, and the next edit to it can silently drift.

`internal/ui` already imports `internal/dag`, so no new dependency is introduced
and no import cycle is possible — `dag` does not import `ui`.

## Enforcement

A unit test walks the Go sources under `internal/` and fails on any occurrence of
the v1 fleet root outside `FleetRoot` itself and outside test files that assert
against it. A test that pins the four current call sites would pass again the
moment someone adds a fifth; scanning the tree is what actually holds the
invariant.

The scan must not reject the string appearing in `FleetRoot`'s own documentation
comment explaining which root is wrong, so match on the path literal in code.

## Rejected alternatives

**Fixing the three wrong literals and leaving them as literals.** Restores correct
behaviour today and leaves the cause in place. Four copies of a path is why three
of them drifted.

**A package-level `var fleetRoot` computed at init.** Breaks the tests, which set
`SERGEANT_FLEET_DIR` per test with `t.Setenv`. Resolution has to happen per call.

**Making the fleet root a field on Server.** Wider change, and it would leave
`internal/dag` resolving the root independently — two authorities instead of one.
