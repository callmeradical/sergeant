# project-graph Specification

## Purpose
Make graphify a native v2 capability per decision D9, not a call out to v1's
`sgt-graphify`: a project declares its graphify configuration
(output/include_groups), the system builds and atomically publishes one
merged cross-repository graph so a reader never observes a partial write, and
a dispatched agent navigates that graph over MCP through query, explain, and
affected operations.
## Requirements
### Requirement: A project declares its graphify configuration

`config.Project` SHALL carry an optional graphify configuration naming an
output location and which repository groups participate. Decision D9
requires a project to declare a `graphify:` block with `output` and
`include_groups`.

#### Scenario: A project's graphify block is parsed into a typed field

- **WHEN** a project's YAML declares a `graphify:` block with an output path
  and include_groups
- **THEN** loading that project exposes both as fields on the project, not
  only as raw YAML

#### Scenario: A project without a graphify block has none, not a zero value standing in for absence

- **WHEN** a project's YAML declares no `graphify:` block
- **THEN** the loaded project's graphify configuration is absent, distinct
  from a project that declared an empty block

### Requirement: Building a project's graph produces one cross-repository graph, published atomically

The system SHALL build a graph for each participating repository, merge them
into one cross-repository graph, and publish the result such that a reader
never observes a partially-written graph. Decision D9 requires this, and
requires it without calling v1's `sgt-graphify`.

#### Scenario: Building a project's graph merges every participating repo

- **WHEN** a project with two or more participating repositories has its
  graph built
- **THEN** the published graph reflects all of them, not only one

#### Scenario: include_groups scopes which repos participate

- **WHEN** a project names include_groups and only some repos belong to a
  named group
- **THEN** only those repos' content is reflected in the published graph

#### Scenario: An empty project or a group matching nothing is an error

- **WHEN** a graph build has no participating repository to extract
- **THEN** the build fails with an error, not a silently empty success

#### Scenario: A reader never observes a partial graph

- **WHEN** a graph build is in progress
- **THEN** the previously published graph (if any) remains readable and
  complete until the moment the new one replaces it, never a mix of the two

#### Scenario: The build does not shell out to v1's sgt-graphify

- **WHEN** a project's graph is built
- **THEN** no process named `sgt-graphify` is ever invoked

### Requirement: A dispatched agent can query the graph over MCP

The graph SHALL be exposed to agents over MCP as query, explain, and
affected operations, so an agent navigates a project by its graph rather
than by searching files. Decision D9 requires these three operations by
name.

#### Scenario: Querying a built graph returns an answer

- **WHEN** an MCP query tool is called against a project with a published
  graph
- **THEN** it returns the underlying graph tool's answer, not an error

#### Scenario: Querying a project with no graph built yet is a clear error, not empty success

- **WHEN** an MCP graph tool is called for a project whose graph has never
  been built
- **THEN** it reports that no graph exists for this project, rather than
  silently returning an empty or fabricated answer

#### Scenario: Explain and affected are distinct operations from query

- **WHEN** explain and affected are each called against a built graph
- **THEN** each invokes its own corresponding graph operation, not a relabel
  of query's behavior

