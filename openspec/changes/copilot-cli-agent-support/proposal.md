## Why

Sergeant's coordinator-driven dispatch path (`internal/runner/runner.go`)
only recognizes a fixed allowlist of headless agent CLIs — `opencode`, `oc`,
`claude`, `goose`, `codex`, `pi`. An operator whose day-to-day agent is
GitHub's `copilot` CLI cannot dispatch through it today: `ValidateAgent`
rejects the name outright before any run, worktree, or branch exists. Per
`docs/prd-copilot-cli-agent-support.md`, `copilot` (confirmed locally at
v1.0.80) has a real headless mode with the flags a no-TTY dispatch needs, so
there is no technical blocker to adding it — only the missing registration.

## What Changes

- Add `"copilot"` to `SupportedAgents` (`internal/runner/runner.go:222`), so
  `ValidateAgent` accepts it before dispatch creates any state.
- Add a `case "copilot":` to `BuildAgentCommand` (`internal/runner/runner.go:402`)
  building copilot's non-interactive invocation: `-p <prompt>` as the
  headless entry point, `--allow-all-tools` as the tool-approval bypass a
  no-TTY dispatch requires (the same role `--dangerously-skip-permissions`
  plays for `claude`), and `--no-ask-user` so copilot's `ask_user` tool can
  never stall waiting on clarification that has nowhere to go.
- No change to working-directory handling: copilot uses the same
  `cmd.Dir = pr.Worktree` mechanism every other harness already relies on
  (`internal/runner/runner.go:545-547`), not its own `-C` flag.
- No change to any other file. `ValidateAgent`, `RunAgentPhase`, the dispatch
  API (`internal/ui/dispatch.go`), and the refine API (`internal/ui/refine.go`)
  are already agent-agnostic once `copilot` is registered above.

## Capabilities

### New Capabilities
- `agent-harnesses`: the set of agent CLIs Sergeant's coordinator-driven
  dispatch path can validate and invoke headlessly, and the non-interactive
  invocation contract each one must satisfy — a recognized name in the
  allowlist, a headless/non-interactive entry point, a tool-approval bypass
  suitable for a no-TTY process, and a working directory supplied by the
  caller rather than the harness's own flag. This is the first spec covering
  that behavior; today it exists only as code (`SupportedAgents`,
  `BuildAgentCommand`) with no corresponding spec.

### Modified Capabilities
(none — no existing `openspec/specs/` capability currently documents agent
harness selection or invocation)

## Impact

- `internal/runner/runner.go` — `SupportedAgents` (line 222), `BuildAgentCommand`
  (line 402).
- `internal/runner/agent_command_test.go` — new table-driven cases asserting
  copilot's argv shape (headless flag present, tool-approval flags present,
  no permission-prompting default flags).
- No API, schema, or UI changes — `internal/ui/dispatch.go` and
  `internal/ui/refine.go` already pass the agent name through `ValidateAgent`
  unchanged, and there is no agent picker UI to update (agent name is a
  free-text field today).
- Model-selection support for `copilot` is explicitly out of scope for this
  change (see `docs/prd-copilot-cli-agent-support.md` Open questions) pending
  confirmation of whether copilot exposes any model flag or env var.
