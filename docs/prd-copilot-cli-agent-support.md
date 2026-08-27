# Product Requirements: Copilot CLI as a Supported Agent Backend

Status: Draft, awaiting explicit human PRD approval

Extends: `docs/prd-sergeant-v2.md` §3.1's agent-driven model, which already
names opencode, codex, goose, pi, and claude as CLI harnesses an operator may
run. This PRD adds GitHub's `copilot` CLI as a sixth harness the
coordinator-driven path (`internal/runner/runner.go`) can dispatch headlessly,
using the same `BuildAgentCommand`/`SupportedAgents` mechanism already used for
the other five.

## Summary

`internal/runner/runner.go` is the single place that knows how to invoke each
supported agent CLI non-interactively: a fixed allowlist (`SupportedAgents`,
line 222) that `ValidateAgent` checks before any dispatch creates a run,
worktree, or branch record, and a switch statement (`BuildAgentCommand`, line
402) that builds the exact non-interactive, permission-bypassing argv/env for
each named harness. Everything downstream of those two — `RunAgentPhase`, the
dispatch and refine APIs, output capture, redaction, and timeout handling — is
already agent-agnostic once a harness is registered there. This PRD adds
`copilot` (GitHub's Copilot CLI, confirmed headless-capable as of the locally
installed v1.0.80) as a seventh recognized harness, following the same pattern
already established for `claude`, `codex`, `goose`, `opencode`/`oc`, and `pi`.

## Problem

An operator whose day-to-day agent CLI is `copilot` cannot use it for
coordinator-driven dispatch today. Naming `copilot` as the agent on a dispatch
or refine request is rejected outright by `ValidateAgent` before a process is
ever spawned ("unsupported agent \"copilot\": this engine can drive opencode,
oc, claude, goose, codex, pi"). Even absent that guard, `BuildAgentCommand` has
no `case "copilot"`, so it would fall through to the bare positional-prompt
default (`args = []string{prompt}`) — the same failure mode `SupportedAgents`
was introduced to prevent (see the comment at line 220-221): a malformed
invocation with no headless flag and no permission-approval bypass, which in a
no-TTY dispatch either hangs waiting for an approval prompt that has nowhere
to go, or exits having done nothing, in a way indistinguishable from the agent
itself failing.

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
- **No other file changes.** `ValidateAgent`, `RunAgentPhase`, the dispatch API
  (`internal/ui/dispatch.go`), the refine API (`internal/ui/refine.go`), and
  output capture/redaction/timeout handling are already agent-agnostic once
  `copilot` is registered in the two places above.

## Out of scope

- Any UI change. There is no agent picker/dropdown for any harness today —
  agent name is a free-text field on the dispatch/refine request bodies, and
  will accept `"copilot"` the same way it accepts `"claude"` once
  `SupportedAgents` is updated.
- **Model-selection support.** No `--model`-equivalent flag was found among
  `copilot`'s documented scripting flags. Confirming whether one exists (and
  what it is, if so) is left to implementation/design, not decided here — see
  Open questions.
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

## Open questions

- **Does `copilot` expose any per-invocation model-selection mechanism** (flag
  or env var)? This needs to be confirmed against the installed binary before
  `BuildAgentCommand`'s case is finalized — this repo's existing convention
  (see README's harness-transport table) is to measure a harness's real
  behavior rather than infer it from documentation. If no such mechanism
  exists, does a dispatch that requests a specific model for `copilot` need to
  fail closed (reject at `ValidateAgent`/dispatch time), or is the model
  request silently ignored for this harness only?
- **Does `--allow-all-tools` plus `--no-ask-user` fully eliminate blocking
  behavior in a no-TTY context**, or is there another interactive surface
  (e.g., a first-run auth/login prompt) that needs to be ruled out
  empirically first — the same way `goose`'s positional-prompt argument was
  discovered to fail outright before its case was fixed?
- **Should `copilot` request `--output-format json`** the way `goose` does, to
  make per-session usage/cost machine-readable and reachable from the phase
  record, or is plain text output (matching `claude`'s convention) sufficient
  for a first version?
- **What is the minimum required `copilot` CLI version?** The flags in this
  PRD were observed against the locally installed v1.0.80. Whether that is a
  hard floor, and how/whether Sergeant should detect or document a version
  mismatch, is not decided here.
