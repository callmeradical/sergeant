# Proposal — Every fleet path resolves through one helper

## Repository

One repository: `sergeant-v2`. It owns `internal/dag` (where the fleet root is
already resolved correctly) and `internal/ui` (where three copies get it wrong).

## Requirements and decisions served

- **D7 — v1 is not a dependency.** `AGENTS.md` states plainly: do not write into
  `~/.local/share/sergeant/fleet`. Three call sites in `internal/ui/server.go` do
  exactly that.
- **R4.2 — worktree and branch are recorded and shown.** The fleet listing reads
  the wrong root, so the Workers pane and prune describe a directory that holds
  none of v2's runs.

## Problem

`internal/dag.FleetDir` resolves the fleet root correctly: `SERGEANT_FLEET_DIR`
when set, otherwise `~/.local/share/sergeant-v2/fleet`. `engine_test.go` even
asserts the v1 root is never used.

Four other places build the same path by hand, and three build it wrongly:

| Location | Path built | Correct? |
|---|---|---|
| `internal/ui/server.go:611` | `~/.local/share/sergeant/fleet` | no — v1 root, ignores the env var |
| `internal/ui/server.go:680` | `~/.local/share/sergeant/fleet` | no — v1 root, ignores the env var |
| `internal/ui/server.go:1104` | `~/.local/share/sergeant/fleet/<task>/handoff` | no — v1 root, ignores the env var |
| `internal/ui/server.go:1507` | `~/.local/share/sergeant-v2/fleet/<run>/handoff` | root is right, still a hand-built duplicate |

Two consequences, and they cut in opposite directions:

1. **Prune cannot see v2's worktrees.** It enumerates v1's directory, so a real
   v2 worktree is never offered for cleanup. This is why the orphaned worktree
   from run `sgt-1787427981` was invisible to it.
2. **Prune can delete v1's worktrees.** It enumerates a directory this engine does
   not own and offers its contents for deletion. D7 forbids writing there at all.

The handoff router is the third case: handoff artifacts for every dispatched run
are being written under v1's root, so upstream artifacts land outside the tree the
rest of the engine reads.

A test asserting `FleetDir` avoids the v1 root is not enough, because the server
never calls `FleetDir`. The defect is the duplication, not any single literal.

## Proposal

Add one exported helper for the fleet root in `internal/dag`, express `FleetDir`
in terms of it, and replace all four hand-built paths in `internal/ui` with calls
to it. Assert that no path outside the helper mentions the v1 root.

## Out of scope

- The store's database path (`internal/store/store.go`), which also sits under
  `~/.local/share/sergeant/`. Moving a database is a migration with its own
  failure modes and does not belong in a path-deduplication change.
- Deleting anything already written under v1's root. This change stops writing
  there; reclaiming what is there is a separate operator decision.
