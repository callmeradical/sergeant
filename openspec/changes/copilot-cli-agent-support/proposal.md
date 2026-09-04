## Why

The initial implementation registered GitHub's `copilot` CLI in Sergeant's
coordinator-driven runner, but stopped short of end-to-end operator support.
`mise run check` still rejects a machine where Copilot is the only installed
agent harness, its policy test cannot detect that mismatch, and live setup
documentation omits Copilot. The implementation also silently drops requested
models even though the locally installed Copilot CLI v1.0.82 exposes a measured
`--model <model>` transport. The change must be reopened so its "Complete"
status reflects the behavior operators actually receive.

## What Changes

- Keep `"copilot"` registered in `SupportedAgents` and keep its headless
  `-p <prompt> --allow-all-tools --no-ask-user` invocation.
- Forward a non-empty requested model as `--model <model>`, using Copilot's
  measured per-invocation model transport. Omit the flag when no model is
  requested.
- Add Copilot to `mise run check`'s supported-harness discovery and diagnostic,
  with a repository-policy regression test that keeps prerequisite discovery
  aligned with `runner.SupportedAgents`.
- Add Copilot to live operator-facing supported-harness documentation.
- Keep working-directory handling unchanged: Copilot uses the same
  `cmd.Dir = pr.Worktree` mechanism every other harness already relies on
  (`internal/runner/runner.go:545-547`), not its own `-C` flag.
- Defer JSON output, usage/provenance capture, minimum-version enforcement, and
  Copilot SDK integration to the subsequent SDK change for issue #1.

## Capabilities

### New Capabilities
- `agent-harnesses`: the set of agent CLIs Sergeant can discover as installed,
  validate, and invoke headlessly. The contract covers prerequisite discovery,
  a recognized runtime name, a headless/non-interactive entry point, a
  tool-approval bypass suitable for a no-TTY process, caller-supplied working
  directory, and measured model forwarding when the harness supports it.

### Modified Capabilities
(none)

## Impact

- `internal/runner/runner.go` — `SupportedAgents` (line 222), `BuildAgentCommand`
  (line 402).
- `internal/runner/agent_command_test.go` — Copilot argv and model-forwarding
  regression coverage.
- `mise.toml` — prerequisite discovery and missing-agent diagnostic.
- `internal/repopolicy/mise_check_test.go` — controlled-PATH parity coverage.
- `README.md`, `AGENTS.md`, `docs/prd-sergeant-v2.md`, and
  `docs/prd-copilot-cli-agent-support.md` — live operator and product guidance.
- No API, schema, or UI changes — `internal/ui/dispatch.go` and
  `internal/ui/refine.go` already pass the agent name through `ValidateAgent`
  unchanged, and there is no agent picker UI to update (agent name is a
  free-text field today).
- No Copilot SDK implementation is included.
