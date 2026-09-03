# Product Requirements: Copilot CLI as a Supported Agent Backend

Status: Reopened for CLI gap closure before Copilot SDK implementation

Extends: `docs/prd-sergeant-v2.md` §3.1's agent-driven model, which already
names opencode, codex, goose, pi, and claude as CLI harnesses an operator may
run. This PRD adds GitHub's `copilot` CLI as a sixth harness the
coordinator-driven path (`internal/runner/runner.go`) can dispatch headlessly,
using the same `BuildAgentCommand`/`SupportedAgents` mechanism already used for
the other five.

## Summary

`internal/runner/runner.go` owns runtime validation and non-interactive command
construction for supported agent CLIs. `mise.toml` separately discovers
installed harnesses before the Go binary exists, so repository-policy tests
must keep that prerequisite list aligned with `runner.SupportedAgents`.
This PRD defines `copilot` (GitHub's Copilot CLI, confirmed headless-capable with
v1.0.80 and confirmed to expose `--model <model>` with v1.0.82) across both
surfaces and the live operator documentation.

## Problem

The first implementation registered and invoked Copilot correctly in the
runner, but left three user-visible gaps:

1. `mise run check` still reported no agent when Copilot was the only supported
   harness on `PATH`.
2. The repository-policy test exercised only OpenCode and Claude, so runtime
   and prerequisite allowlists could drift without failing.
3. `BuildAgentCommand` silently discarded a requested model even though current
   Copilot exposes a measured `--model <model>` transport.

Live setup documentation also omitted Copilot, contradicting the runtime.

## Proposal

- **Add `"copilot"` to `SupportedAgents`** (`internal/runner/runner.go:222`),
  alongside the existing five entries, so `ValidateAgent` accepts it before
  any run state is created.
- **Add a `case "copilot":` to `BuildAgentCommand`** that builds a headless,
  non-interactive invocation in the same spirit as the existing `claude` case:
  - `-p <prompt>` (or `--prompt`) as the non-interactive entry point —
    `copilot`'s equivalent of `claude --print` / `codex exec`.
  - `--allow-all-tools` as the tool-approval bypass a no-TTY dispatch
    requires — the same role `--dangerously-skip-permissions` plays for
    `claude`, and safe for the same reason: every dispatch already runs in an
    isolated git worktree on its own branch, never the operator's checkout.
  - `--no-ask-user` so `copilot`'s `ask_user` tool can never stall a headless
    run waiting on interactive clarification that has nowhere to go.
- **Working directory is set the same way it already is for every other
  harness** — `cmd.Dir = pr.Worktree` at the shared call site
  (`internal/runner/runner.go:545-547`) — not via `copilot`'s own `-C` flag.
  This keeps `copilot` consistent with the agent-agnostic caller contract
  every existing case already relies on, rather than introducing a
  per-harness way of setting the working directory.
- **Forward a requested model with `--model <model>`**, the transport measured
  from Copilot CLI v1.0.82. Omit the flag when no model is requested.
- **Recognize Copilot in `mise run check`** and make its controlled-PATH policy
  test exercise every entry in `runner.SupportedAgents`.
- **Update live supported-harness documentation** in `README.md`, `AGENTS.md`,
  and the v2 PRD.

## Out of scope

- Any UI change. There is no agent picker/dropdown for any harness today —
  agent name is a free-text field on the dispatch/refine request bodies, and
  accepts `"copilot"` the same way it accepts `"claude"`.
- **Provenance/model detection from `copilot`'s own output**
  (`detectModelProvider`, line 79). Today this is only implemented for
  `goose` (parses a startup banner) and `claude` (reads an env var); adding a
  `copilot` case there is optional and only worth doing if `copilot` is
  observed to print a parseable model/provider line. Not required for basic
  dispatch support.
- **`--output-format json`, `-s`/`--silent`, `--share`/`--share-gist`, and
  `--session-id`/`--resume`/`--continue`.** These are real, useful flags for
  observability or session-chaining, but none of the other five harnesses'
  cases use anything beyond a headless flag, an optional model flag, and a
  permission bypass for a first working integration. Adding them is a later,
  separate improvement, not required to make `copilot` dispatchable.
- **Choosing between the `copilot` binary and the `gh copilot --` wrapper.**
  Sergeant will invoke whatever binary name the operator configures as the
  agent (resolved via `PATH`, exactly like every other harness today) — it
  does not special-case `gh` as a wrapper.
- **The README's "measured harness" model/variant-transport table** (a
  different, older invocation path than `internal/runner/runner.go`'s
  `BuildAgentCommand`). Updating that table for `copilot` is documentation
  hygiene, not a functional requirement of this PRD.
- **Copilot SDK integration.** Issue #1's SDK work begins only after this CLI
  contract is complete.

## Open questions

- **Should `copilot` request `--output-format json`** the way `goose` does, to
  make per-session usage/cost machine-readable and reachable from the phase
  record, or is plain text output (matching `claude`'s convention) sufficient
  for a first version?
- **What is the minimum required `copilot` CLI version?** The flags in this
  PRD's headless base invocation were observed against v1.0.80, while
  `--model` was confirmed against v1.0.82. Whether either is a hard floor, and
  how/whether Sergeant should detect or document a version mismatch, is not
  decided here.
- **Should the SDK replace the subprocess harness or coexist as a separately
  selected backend?** This belongs to issue #1's SDK OpenSpec, not this CLI
  gap-closure.
