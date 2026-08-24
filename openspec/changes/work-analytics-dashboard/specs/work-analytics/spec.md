# Work analytics

## ADDED Requirements

### Requirement: The dashboard shows an aggregate view of all recorded work

An operator SHALL be able to see, from the dashboard, the total number of
runs, broken down by outcome and by work type, without reading individual
run records by hand.

#### Scenario: Total run count and outcome breakdown reflect complete history

- **WHEN** more than 50 runs exist for a project (exceeding the window
  other "recent activity" endpoints use)
- **THEN** the analytics view's total run count and outcome breakdown
  include every one of them, not just the most recent 50

#### Scenario: Work type breakdown covers pre-migration runs

- **WHEN** a run recorded before decision O2 exists, with an empty `Type`
- **THEN** it is counted in an explicitly labeled bucket for unrecorded
  work type, not dropped from the total and not miscounted into any named
  type

### Requirement: The dashboard shows which agents, models, and providers did the work

An operator SHALL be able to see a breakdown of runs by agent, model, and
provider, using the provenance already captured per phase.

#### Scenario: A run with known provenance is counted under its agent/model/provider

- **WHEN** a run has at least one phase whose payload carries a non-empty
  `agent` field (and, where known, `model`/`provider`)
- **THEN** that run is counted under those values in the respective
  breakdowns

#### Scenario: A run with no captured provenance is counted as unknown, not omitted

- **WHEN** a run has no phase carrying agent/model/provider information
  (the current, disclosed state for every agent except goose)
- **THEN** that run is counted in an explicit "unknown" bucket in each of
  the agent, model, and provider breakdowns — the sum of each breakdown's
  counts equals the total run count

### Requirement: The dashboard shows how much recorded work actually shipped

An operator SHALL be able to see how many bullets have reached `merged`
against how many bullets exist in total.

#### Scenario: Merged and total bullet counts are both shown

- **WHEN** bullets exist in one or more statuses, including some at
  `merged`
- **THEN** the analytics view shows both the count at `merged` and the
  total bullet count

#### Scenario: Zero bullets renders without error

- **WHEN** no bullets exist yet for the scoped project
- **THEN** the analytics view states that no bullets have been recorded
  yet, rather than showing a division-by-zero result such as `NaN%`

### Requirement: Analytics respects project scope

The analytics view SHALL be scoped by project exactly as the rest of the
dashboard already is.

#### Scenario: A specific project shows only that project's data

- **WHEN** the dashboard's project filter names one specific project
- **THEN** every count in the analytics view reflects only that project's
  runs and bullets

#### Scenario: "All projects" combines every project's data

- **WHEN** the dashboard's project filter is set to the existing "all
  projects" option
- **THEN** the analytics view's counts combine every project's runs and
  bullets, with no project's data silently excluded
