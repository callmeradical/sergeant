# Workflow graph

## ADDED Requirements

### Requirement: The workflow is served from its definition, not inferred from history

`GET /api/workflow` SHALL return the workflow for a repository derived from project
configuration, so a stage that has not run is still present. Decision D8 requires
the dashboard to render the workflow as a definition with progress against it; a
view derived from recorded phases can only show history and cannot show what is
still to come.

#### Scenario: A configured pipeline is returned in declared order

- **WHEN** the workflow is requested for a repository declaring a pipeline
- **THEN** one stage node per pipeline entry is returned, in declared order

#### Scenario: A repository with no factory block gets the engine default

- **WHEN** the workflow is requested for a repository with no factory block or an
  empty pipeline
- **THEN** the engine's default pipeline is returned

The default is read from the same place the engine reads it, so a description of
the workflow cannot disagree with its execution.

#### Scenario: Gate order matches execution order

- **WHEN** a repository declares gates
- **THEN** the gate nodes are returned in the same deterministic order the engine
  executes them

Map iteration order would present a different first gate on each request, which
would misrepresent what runs first.

#### Scenario: Adding a gate changes the graph with no code change

- **WHEN** a gate is added to the project configuration and the workflow is
  requested again
- **THEN** the returned graph contains the new gate

This is the scenario that holds the requirement. A handler with a hardcoded stage
list would pass every other scenario here and fail this one.

#### Scenario: An unknown project or repository is refused by name

- **WHEN** the workflow is requested for a project or repository that is not
  configured
- **THEN** the response is a client error naming what was not found
