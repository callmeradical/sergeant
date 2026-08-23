# Design — Phases record their model and provider

## Ownership and merge order

One repository, `sergeant-v2`. Standalone — does not depend on the R5 bullets
and they do not depend on it, but it touches the same function
(`runner.RunAgentPhase`) that R5 bullet 2 (merged) and bullet 3 (in flight at
the time this is written) also touch. To avoid a conflicting concurrent edit
to that function, this bullet is dispatched only after bullet 3 has merged,
not in parallel with it.

## Where the evidence actually is

goose's own stdout, captured today into `outBuf` and only ever stored as an
opaque string, contains this line before its JSON payload:

```
    __( O)>  ● new session · anthropic claude-sonnet-4-6
```

`anthropic` is the provider, `claude-sonnet-4-6` is the model. This is the
actual invocation's own report of what it used, not sergeant's request for
what it wanted — the distinction R4.6 exists to capture. No other supported
agent (`opencode`, `claude`, `codex`, `pi`) has a known equivalent line in this
codebase; none is invented here.

## `detectModelProvider` is agent-aware and fails soft

```go
// detectModelProvider extracts the model and provider an agent actually used
// from its own output, where that is knowable. It returns empty strings when
// the agent is not one this function recognises, or when recognised output
// does not match the expected shape — a phase's provenance being unknown is
// honest; a phase failing because provenance parsing panicked is not.
func detectModelProvider(agentExe, rawOutput string) (provider, model string)
```

Switches on `filepath.Base(agentExe)`, the same dispatch `BuildAgentCommand`
already uses. Only the `"goose"` case is implemented, with a regexp matching
`new session\s*·\s*(\S+)\s+(\S+)` against the raw (not yet ANSI-stripped)
output — goose's banner uses plain characters, not ANSI codes, around the
model/provider text, so stripping first is not required. No match: two empty
strings. Every other agent: two empty strings, immediately, no attempted
parse.

## Provenance applies regardless of which envelope `RunAgentPhase` uses

`RunAgentPhase` has two paths to a phase's `env`: the agent wrote its own
`envelope.json` (used verbatim when the phase did not fail), or sergeant
synthesizes one from `outBuf` (every failure, and any success where the agent
wrote nothing). Today only the synthesized path's payload carries
`agent`/`attempt`/`worktree`/`branch` — the agent-authored path's payload is
whatever the agent chose to write, which does not include sergeant's own
provenance fields at all.

`model`/`provider` must be attached after both paths converge on a single
`env`, not inside the synthesized branch's map literal — attaching only there
would silently omit provenance for the (common, successful) case where the
agent wrote its own envelope. A small helper:

```go
// annotatePayloadWithProvenance adds model and provider to an existing
// envelope payload without disturbing whatever else it carries. If payload is
// not a JSON object (an agent-authored envelope could in principle write
// something else), it is returned unchanged — provenance is additive
// metadata, not a reason to reject a payload sergeant did not itself produce.
func annotatePayloadWithProvenance(payload json.RawMessage, model, provider string) json.RawMessage
```

Called once, right after the `if/else` that produces `env`, before
`Router.SaveEnvelope`/`Store.DeliverEnvelope`/`Store.RecordPhase` all consume
`env.Payload` — one call site updates what all three readers see, the same
reasoning bullet 2 used for generating the envelope id once and reusing it.

## Rejected alternatives

**A new column on `PhaseRecord`/`EnvelopeRecord` instead of a payload key.**
`Payload`/`Data` are already unstructured JSON precisely because a phase's
metadata shape varies by agent and by what that agent chooses to report — the
same reasoning that keeps `raw_output`/`agent`/`attempt` there today.
Model/provider are one more fact about the same event, not a new queryable
dimension anything joins on; R4.6 does not ask for a CLI/UI filter by model,
only for the fact to be recorded.

**Parsing goose's JSON body instead of its banner text.** The JSON metadata
block (`total_tokens`, `input_tokens`, `output_tokens`, `status`) does not
include the model or provider name — confirmed by reading a captured
response; only the banner text names them. Parsing has to target where the
fact actually is.

**Reading goose's own config file (`~/.config/goose/config.yaml`) instead of
its output.** The config file says what goose is currently set to use, which
can change between dispatch and now, and does not prove what a specific past
invocation actually used. The banner is that invocation's own report, in the
same captured output this project already treats as the evidence of record
for everything else about the phase.
