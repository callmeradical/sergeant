# graphify-exclusion Specification

## Purpose
Let a project's `exclude_patterns` keep noise (vendored dependencies,
generated output) out of its published graph: matching files' nodes, links,
and hyperedges are removed with no dangling references left behind,
directory-recursive patterns are honored, and an empty exclude list is
guaranteed to change nothing.
## Requirements
### Requirement: A file matching an exclude pattern does not appear in the published graph

Decision D9 declares `exclude_patterns` as part of a project's graphify
configuration. A node, link, or hyperedge whose source file matches a
configured pattern SHALL NOT appear in the published graph, regardless of
which participating repository it came from.

#### Scenario: A node from an excluded file is removed

- **WHEN** a project declares an exclude pattern matching a file that
  contributed a node to the graph
- **THEN** the published graph contains no node for that file

#### Scenario: An edge from an excluded file is removed

- **WHEN** a project declares an exclude pattern matching a file that
  contributed a link or hyperedge to the graph
- **THEN** the published graph contains no such link or hyperedge

#### Scenario: A dangling reference left by an excluded node is also removed

- **WHEN** excluding a file removes a node that a surviving link or
  hyperedge referenced
- **THEN** that link or hyperedge is also absent from the published graph,
  not left pointing at a node that no longer exists

### Requirement: Exclude patterns support recursive directory matching

Matching by exact file name alone is not sufficient for the noise this
field exists to filter (vendored dependencies, generated output
directories). Patterns SHALL support matching a whole directory and
everything beneath it, not only exact file names.

#### Scenario: A directory-recursive pattern excludes its whole contents

- **WHEN** a project declares an exclude pattern shaped to match an entire
  directory and everything under it
- **THEN** every file under that directory is excluded, not only files
  directly in it

### Requirement: An empty exclude list changes nothing

A project that declares no exclude patterns SHALL see no change in its
published graph. This is a correctness constraint on the filtering
mechanism itself, not merely a description of its default.

#### Scenario: No exclude patterns configured produces the same graph as before this change

- **WHEN** a project declares no `exclude_patterns` (or omits the field)
- **THEN** the published graph is unchanged from what it would have been
  without this capability

