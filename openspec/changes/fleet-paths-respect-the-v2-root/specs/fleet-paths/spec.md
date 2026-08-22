# Fleet paths

## ADDED Requirements

### Requirement: One helper owns the fleet root

Every path under a run's fleet directory SHALL be derived from a single helper that
honours `SERGEANT_FLEET_DIR`. Decision D7 forbids v2 writing into v1's
`~/.local/share/sergeant/fleet`, and four hand-built copies of the path are how
three of them came to point there.

#### Scenario: The helper honours the environment override

- **WHEN** `SERGEANT_FLEET_DIR` is set to a directory
- **THEN** the fleet root helper returns that directory

#### Scenario: The helper defaults to the v2 root, never v1's

- **WHEN** `SERGEANT_FLEET_DIR` is unset
- **THEN** the fleet root helper returns a path ending `share/sergeant-v2/fleet`
  and containing no `share/sergeant/fleet` segment

#### Scenario: FleetDir agrees with the helper

- **WHEN** a run directory is resolved for a run id and repository
- **THEN** it equals the helper's root joined with that run id and repository

Two independent resolutions of the same root are how the current defect arose, so
they must be one expression rather than two that happen to match.

#### Scenario: No source outside the helper names v1's fleet root

- **WHEN** the Go sources under `internal/` are scanned for the path literal
  `share/sergeant/fleet`
- **THEN** no non-test occurrence exists outside the helper itself

Fails today: `internal/ui/server.go` contains three. This is the scenario that
holds the invariant — a test pinning the known call sites would pass again the
moment a fifth was added.

### Requirement: The worktree pane and prune operate on this engine's own runs

Worktree enumeration SHALL read the same root the engine writes to.

#### Scenario: A dispatched run's worktree is visible to the fleet listing

- **WHEN** a run has created a worktree under the configured fleet root
- **THEN** the fleet listing includes that worktree

Fails today: enumeration reads v1's root, so no v2 worktree ever appears. The
orphaned worktree from run sgt-1787427981 was invisible to prune for this reason.

#### Scenario: Prune never offers a worktree outside the configured root

- **WHEN** worktrees are enumerated for cleanup
- **THEN** every path offered is under the configured fleet root

Fails today: prune enumerates v1's directory and offers its contents for deletion,
which is both wrong and destructive to a directory D7 forbids touching.

#### Scenario: Handoff artifacts are written under the configured root

- **WHEN** a dispatch routes a handoff artifact for a run
- **THEN** the artifact path is under the configured fleet root

Fails today: the handoff router is built from v1's root, so artifacts land outside
the tree the rest of the engine reads.
