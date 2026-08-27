## Context

One repository: `sergeant-v2`. All of this change lives in
`internal/runner/runner.go`, the single file that already knows how to
validate and invoke every supported agent harness (`opencode`/`oc`, `claude`,
`goose`, `codex`, `pi`). No other repository is involved and there is no
merge-order question.

The mechanism is already established and does not need to be redesigned:
`SupportedAgents` (a package-level `[]string`) gates which names
`ValidateAgent` accepts before any dispatch creates state, and
`BuildAgentCommand` is a single switch statement, one `case` per harness,
returning `(exe string, args []string, env []string)`. Everything downstream
(`RunAgentPhase`, the dispatch/refine APIs, output capture and redaction) is
agent-agnostic once a harness is registered in those two places. This design
is therefore narrow: it pins down the exact `case "copilot":` contents, not a
new architecture.

## Goals / Non-Goals

**Goals:**
- Register `copilot` as a supported harness with a headless, non-blocking
  invocation shape, following the existing per-harness pattern exactly.
- Make the specific flag choices explicit and testable before implementation,
  so `agent_command_test.go`'s table-driven tests can assert on them the same
  way they already do for `claude`/`goose`.

**Non-Goals:**
- Model-selection transport for copilot. No confirmed flag/env var exists
  (see Open Questions); this change deliberately omits one rather than guess.
- `--output-format json` / provenance parsing (`detectModelProvider`). Only
  `goose` and `claude` have observed, parseable output today; adding copilot
  there is separate future work, contingent on actually observing its output.
- Any change to `ValidateAgent`, `RunAgentPhase`, the dispatch API, the refine
  API, or the UI — all already agent-agnostic once the two edits below land.
- Session-chaining (`--session-id`/`--resume`/`--continue`) or transcript
  export (`--share`/`--share-gist`) — not needed for a first dispatch.

## Decisions

- **Argv shape: `[]string{"-p", prompt, "--allow-all-tools", "--no-ask-user"}`.**
  `-p` takes the prompt as its value (unlike `claude --print`, which takes no
  value and relies on a trailing positional prompt), so the prompt must
  immediately follow `-p` rather than be appended last. `--allow-all-tools`
  and `--no-ask-user` are order-independent flags and are appended after.
  Alternative considered: fine-grained `--allow-tool`/`--deny-tool` lists
  instead of the blanket flag. Rejected for this change — every other
  harness's dispatch-time bypass (`claude --dangerously-skip-permissions`,
  `opencode --auto`) is a blanket bypass justified by the same fact (dispatch
  always runs in an isolated worktree on its own branch), so a narrower
  allowlist would be an inconsistent, unrequested policy decision for this
  one harness only.
- **No `--model` handling.** `model != ""` is a no-op for the `copilot` case
  — the argument list is built identically whether or not a model was
  requested. Alternative considered: reject the dispatch at `ValidateAgent`
  time if a model is requested for `copilot`. Rejected: `ValidateAgent`
  validates the harness name, not the (harness, model) pair, and every other
  harness already accepts a model argument it may or may not use (e.g. `pi`
  vs. `goose`'s env-var special case) — silently omitting is consistent with
  that existing shape, not a new validation axis.
- **No `-C` flag.** Working directory is supplied exclusively via
  `cmd.Dir = pr.Worktree` at the shared call site
  (`internal/runner/runner.go:545-547`), matching every other harness.
  Passing both `-C` and `cmd.Dir` would risk disagreement between the two if
  they were ever set to different values; using only one mechanism removes
  that possibility entirely.
- **Registration point in `SupportedAgents`:** append `"copilot"` as a sixth
  entry, preserving existing order (no reason to reorder the other five).

## Risks / Trade-offs

- **Flags are drawn from a user-reported description of `copilot` v1.0.80's
  help output, not yet independently exercised against a real dispatch in
  this repo's worktree/timeout/output-capture path.** → Mitigation: before
  marking the tasks below complete, run one real headless invocation
  (`copilot -p "<trivial prompt>" --allow-all-tools --no-ask-user` in a
  scratch directory) and confirm it exits 0 without a TTY and without any
  interactive prompt (e.g. a first-run auth/login flow that neither
  `--allow-all-tools` nor `--no-ask-user` would suppress). If it does not,
  the flag set in this design must be revised before implementation, not
  after.
- **`--allow-all-tools` is a blanket bypass.** Same trade-off already
  accepted for `claude`'s `--dangerously-skip-permissions` and `opencode`'s
  `--auto` → Mitigation: same one that already justifies those — dispatch
  never runs against the operator's own checkout, only an isolated worktree
  on its own branch.
- **Silent model omission could surprise an operator who explicitly requests
  a model for `copilot` and gets no error and no model pin.** → Mitigation:
  covered by a dedicated spec scenario (`agent-harnesses` capability) so the
  behavior is at least documented and tested, not merely undocumented
  fallthrough; revisit once a real transport is confirmed.

## Migration Plan

Purely additive — no existing behavior for any other harness changes, no
schema/data migration, no config format change. Rollback is reverting the
two edits (`SupportedAgents` entry, `BuildAgentCommand` case); no durable
state depends on `copilot` having been dispatchable.

## Open Questions

Carried over from `docs/prd-copilot-cli-agent-support.md`, unresolved by this
design and not required to land it:
- Does `copilot` expose any real model-selection transport? If one is later
  confirmed, a follow-up change adds it the same way `goose`'s `GOOSE_MODEL`
  env var was added for that harness.
- Is there a first-run interactive surface (login/auth) that
  `--allow-all-tools`/`--no-ask-user` do not suppress? Must be ruled out by
  the manual verification step under Risks before implementation is
  considered done.
- Is `--output-format json` worth adopting later for usage/cost capture, the
  way `goose`'s is used today? Left for a future change.
