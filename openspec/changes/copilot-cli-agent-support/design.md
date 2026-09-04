## Context

One repository owns the change: `sergeant`. No other repository is involved
and there is no merge-order question.

Runtime support is centralized in `internal/runner/runner.go`:
`SupportedAgents` gates validation and `BuildAgentCommand` builds each
harness's argv/env. Operator prerequisite discovery is separately implemented
in `mise.toml` because it must run before the Go binary exists. That unavoidable
duplication requires a parity test: every entry accepted by the runner must
also satisfy `mise run check` when it is the only harness on `PATH`.

## Goals / Non-Goals

**Goals:**
- Register `copilot` as a supported harness with a headless, non-blocking
  invocation shape, following the existing per-harness pattern exactly.
- Recognize Copilot as an installed harness in `mise run check`.
- Forward an explicitly requested model through Copilot's measured
  `--model <model>` transport.
- Keep runtime support, prerequisite checks, regression coverage, and live
  operator documentation consistent.

**Non-Goals:**
- `--output-format json` / provenance parsing (`detectModelProvider`). Only
  `goose` and `claude` have observed, parseable output today; adding copilot
  there belongs to the subsequent SDK/observability work.
- `--usage-output-file` integration or usage/cost capture.
- Minimum Copilot CLI version enforcement.
- Copilot SDK integration for issue #1.
- Any change to `ValidateAgent`, `RunAgentPhase`, the dispatch API, the refine
  API, or the UI — all are already agent-agnostic across the runtime and
  prerequisite changes below.
- Session-chaining (`--session-id`/`--resume`/`--continue`) or transcript
  export (`--share`/`--share-gist`) — not needed for a first dispatch.

## Decisions

- **Base argv shape: `[]string{"-p", prompt, "--allow-all-tools", "--no-ask-user"}`.**
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
- **Forward requested models with `--model`.** Copilot CLI v1.0.82's real help
  output documents `--model <model>` as its per-invocation selector. When
  `model != ""`, append `--model`, then the exact requested value. When empty,
  emit no model flag and allow Copilot to choose its configured/default model.
- **Keep prerequisite discovery aligned by test.** `mise.toml` cannot import a
  Go variable before Sergeant is built, so its shell list remains explicit.
  `internal/repopolicy/mise_check_test.go` iterates over
  `runner.SupportedAgents` and runs the real extracted check task against a
  controlled `PATH`; adding a runtime harness without updating `mise.toml`
  therefore fails deterministically.
- **Live docs list every supported harness.** `README.md`, `AGENTS.md`, and the
  v2 PRD are current operator/product guidance, not historical records.
- **No `-C` flag.** Working directory is supplied exclusively via
  `cmd.Dir = pr.Worktree` at the shared call site
  (`internal/runner/runner.go:545-547`), matching every other harness.
  Passing both `-C` and `cmd.Dir` would risk disagreement between the two if
  they were ever set to different values; using only one mechanism removes
  that possibility entirely.
- **Registration point in `SupportedAgents`:** append `"copilot"` as the sixth
  harness family and seventh accepted executable name (`opencode` and `oc` are
  aliases), preserving existing order.

## Risks / Trade-offs

- **Headless flags were initially measured against Copilot CLI v1.0.80 and
  model selection was confirmed against v1.0.82's real help output.** →
  Mitigation: before marking the tasks below complete, run one real headless invocation
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
- **The shell prerequisite list and Go runtime list can drift.** → Mitigation:
  the repository-policy test treats `runner.SupportedAgents` as the source set
  and requires the extracted `mise run check` task to accept each entry.

## Migration Plan

No schema/data migration or config format change is required. Existing Copilot
dispatches without a requested model keep the same argv. Dispatches with a
requested model begin honoring that request instead of silently dropping it.
Rollback is limited to the Copilot command case, prerequisite list, parity
tests, and live documentation.

## Open Questions

Deferred to the subsequent SDK change and not required to land this gap
closure:
- Should the SDK path replace CLI subprocess invocation or coexist as a
  separately selected harness?
- Should `--output-format json` or `--usage-output-file` be used for
  machine-readable provenance and cost capture?
- What minimum Copilot CLI version, if any, should Sergeant enforce?
