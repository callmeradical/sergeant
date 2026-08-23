# Tasks — Phases record their model and provider

One repository, `sergeant-v2`, so one task.

## Task 1 — parse and attach real model/provider evidence to a phase's payload

Repository: `sergeant-v2`. Depends on: nothing in this repo's open work
(dispatch this only once R5 bullet 3, dead-lettering, has already merged —
both bullets edit `internal/runner/runner.go`'s `RunAgentPhase`, and
dispatching in parallel with an in-flight change to the same function risks a
conflicting merge).

- Add `detectModelProvider(agentExe, rawOutput string) (provider, model
  string)` to `internal/runner/runner.go`. Switch on `filepath.Base(agentExe)`
  the same way `BuildAgentCommand` does. Implement only the `"goose"` case:
  match `rawOutput` against a regexp equivalent to `` new session\s*·\s*(\S+)\s+(\S+) ``
  (goose's banner line is `● new session · anthropic claude-sonnet-4-6`,
  unrelated to ANSI codes, so matching before or after ANSI-stripping is
  equally correct). No match, or any other agent: return `"", ""`. This
  function must never panic or return an error — an unparseable banner is an
  empty result, not a failure.
- Add `annotatePayloadWithProvenance(payload json.RawMessage, model, provider
  string) json.RawMessage` to the same file. Unmarshal `payload` into
  `map[string]interface{}`; if that fails, return `payload` unchanged. Set
  `"model"` and `"provider"` keys (even when both are empty strings — an
  explicit empty is the honest "not knowable for this agent" signal, distinct
  from the key being absent). Re-marshal and return.
- In `RunAgentPhase`, call `detectModelProvider(exe, outBuf.String())`
  immediately after `cmd.Run()` returns (both `provider`/`model` are needed
  regardless of which of the two `env`-building branches runs next). After
  the existing `if data, err := os.ReadFile(envelopePath); err == nil &&
  !failed { ... } else { ... }` block produces `env`, call
  `env.Payload = annotatePayloadWithProvenance(env.Payload, model, provider)`
  once, before `Router.SaveEnvelope` is called — this must cover both the
  agent-authored-envelope branch and the sergeant-synthesized branch, not just
  the synthesized one.
- Do not add parsing for `opencode`, `claude`, `codex`, or `pi`. Do not add
  token/cost fields. Do not add any CLI/UI/MCP surface. Do not change
  `pr.Model`/`GOOSE_MODEL` request-side behavior.

Verification: `go build ./... && go vet ./... && go test ./internal/... -count=1`.
Tests must cover every scenario in
`openspec/changes/phases-record-their-model-and-provider/specs/phase-provenance/spec.md`:
a goose phase's raw output containing the banner line produces `model`/
`provider` in its recorded payload; an agent this project has no parser for
produces empty `model`/`provider` rather than a guess; a successful phase
whose envelope was read from an agent-authored `envelope.json` (not
synthesized) still has `model`/`provider` attached; malformed or
banner-less output does not fail the phase and produces empty `model`/
`provider`. Exit status decides the outcome.
