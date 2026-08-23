# Proposal — Phases record their model and provider

## Repository

One repository: `sergeant-v2`.

## Requirement served

**R4.6** (new, added alongside this proposal): every agent phase record
identifies the agent CLI, the model, and the model's provider that actually
executed it, derived from real evidence of that execution rather than only
from requested configuration. Raised directly by the project owner during
this session: sergeant currently has no record of which model or provider
touched a given piece of code, which matters for audit and attribution the
same way `R4.2`'s existing identifier list (project, run, stage, repo, phase,
attempt, ...) already matters.

## Problem

`PhaseRunner.RunAgentPhase` already knows which agent CLI it invoked
(`pr.AgentCLI`, defaulting to `opencode`) and which model was explicitly
requested (`pr.Model`, usually empty — this project's config sets no override
and lets goose pick its own default). Neither is enough to answer "what model
actually produced this result":

- `pr.AgentCLI`/`pr.Model` describe the *request*, not the *execution*. If
  goose's own configuration changes its default model between two runs that
  both leave `pr.Model` empty, sergeant's records cannot tell the difference.
- The actual model and provider **are** present in the captured output today
  — goose's startup banner reads `● new session · anthropic
  claude-sonnet-4-6` — but they sit unparsed inside `raw_output`, a single
  string blob in the phase/envelope payload. Answering "which model ran this
  phase" today means grepping raw terminal output by hand.

## Proposal

Parse the actual model and provider out of the agent's own output at the
point `RunAgentPhase` already has it in memory (`outBuf`), and add them as
first-class `model` and `provider` keys in the same payload map that already
carries `agent`, `attempt`, `worktree`, and `branch` — the same map that
becomes both the phase record's payload and the envelope's payload, so this
needs one call site, not two.

Scoped to what is actually knowable from real evidence today:

- **goose**: its banner line names both the provider and the model plainly.
  Parsed with a small, self-contained function that fails soft (empty
  strings) rather than crashing the phase on an unrecognised banner shape —
  goose's banner format is not a contract this project controls.
- **Every other supported agent** (`opencode`, `claude`, `codex`, `pi`): none
  currently emits a parseable model/provider line that this codebase reads
  anywhere else, and inventing a parser for output this project has not
  actually observed would be guessing. `model`/`provider` are empty strings
  for these agents, matching the honest-partial-implementation shape already
  used for `EnvelopeRecord.CausationID`/`Acknowledged` in the R5 bullets —
  present in the schema, populated only where real evidence supports it.

## Out of scope

- Adding model/provider parsing for `opencode`, `claude`, `codex`, or `pi`.
  Nothing in this codebase has observed what their output looks like well
  enough to parse it correctly; that is separate work when one of them is
  actually dispatched and its output can be inspected.
- Token counts or cost. Goose's JSON output includes `total_tokens`,
  `input_tokens`, and `output_tokens` in its `metadata` block, which is a
  natural follow-on now that this bullet establishes the pattern of parsing
  goose's structured output — but R4.6 asks for model/provider attribution,
  not cost capture, and cost capture is unspecified PRD scope.
- Any CLI/UI/MCP surface exposing `model`/`provider`. They land in the
  existing payload map, which every current reader (the dashboard, the API)
  already reads; no new surface is needed for the fields to be visible.
- Changing `pr.Model`/`GOOSE_MODEL` request-side behavior. This proposal is
  about recording what happened, not about how a model is requested.
