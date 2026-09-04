## ADDED Requirements

### Requirement: Copilot is a recognized agent harness

The engine SHALL accept `"copilot"` as a valid agent harness name for
coordinator-driven dispatch, both as a bare name and as a full path whose
final path element is `copilot`, matching how every other supported harness
is already recognized.

#### Scenario: Dispatching with agent "copilot" passes validation

- **WHEN** a dispatch or refine request names `"copilot"` as the agent
- **THEN** validation accepts it and no "unsupported agent" error is returned

#### Scenario: A full path to the copilot binary is also accepted

- **WHEN** a dispatch names the agent as a full path ending in `copilot`
  (e.g. `/Users/lcromley/.local/bin/copilot`)
- **THEN** validation accepts it, matching the existing basename-matching
  behavior used for every other supported harness

#### Scenario: An unrecognized agent name still fails validation

- **WHEN** a dispatch names an agent that is neither `copilot` nor any other
  entry in the supported-harness list
- **THEN** validation rejects it with an error naming the supported harnesses,
  and no run, worktree, or branch is created

### Requirement: Copilot is invoked non-interactively with tool-approval bypassed

Building the invocation for the `copilot` harness SHALL produce a command
that runs to completion without a TTY: it SHALL use copilot's headless
prompt entry point, SHALL bypass per-tool approval prompts, and SHALL
disable copilot's interactive clarification tool, so a dispatched phase
never blocks on a prompt with nowhere to go.

#### Scenario: The prompt is passed via the headless entry point

- **WHEN** the engine builds a copilot invocation for a given prompt
- **THEN** the built arguments contain `-p` immediately followed by that
  exact prompt text

#### Scenario: Tool-approval prompts are bypassed

- **WHEN** the engine builds a copilot invocation
- **THEN** the built arguments contain `--allow-all-tools`

#### Scenario: Interactive clarification is disabled

- **WHEN** the engine builds a copilot invocation
- **THEN** the built arguments contain `--no-ask-user`

### Requirement: Copilot's working directory comes from the caller, not a harness flag

Building the invocation for the `copilot` harness SHALL NOT include copilot's
own working-directory flag (`-C`). Every supported harness receives its
working directory from the shared caller-side mechanism (the process's
working directory is set to the run's worktree at the point every harness is
executed), and copilot SHALL follow that same contract rather than
introducing a second, harness-specific way to set it.

#### Scenario: No -C flag is emitted for copilot

- **WHEN** the engine builds a copilot invocation, regardless of prompt or
  model input
- **THEN** the built arguments do not contain `-C`

### Requirement: A requested model is forwarded to copilot

Copilot CLI exposes `--model <model>` as its per-invocation model selector.
Building the invocation for `copilot` SHALL forward a non-empty requested model
through that measured transport and SHALL omit the flag when no model is
requested.

#### Scenario: A model request is forwarded

- **WHEN** the engine builds a copilot invocation with a non-empty requested
  model
- **THEN** the built arguments contain `--model` immediately followed by the
  exact requested model

#### Scenario: No model request emits no model flag

- **WHEN** the engine builds a copilot invocation with no requested model
- **THEN** the built arguments do not contain `--model`

### Requirement: Prerequisite discovery recognizes every supported harness

The repository's prerequisite check SHALL recognize every harness accepted by
the runtime, including Copilot, so an operator is never told that no agent is
installed when a usable supported agent is present.

#### Scenario: Copilot alone satisfies the agent prerequisite

- **WHEN** `mise run check` runs with required tools and `copilot` as the only
  supported agent harness on `PATH`
- **THEN** the check succeeds and reports Copilot as the available agent

#### Scenario: Missing-agent guidance includes Copilot

- **WHEN** `mise run check` runs with no supported agent harness on `PATH`
- **THEN** the check fails and its supported-harness guidance includes
  `copilot`
