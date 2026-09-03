## 1. Verify copilot's real headless behavior

- [x] 1.1 Run `copilot -p "reply with the word OK and exit" --allow-all-tools --no-ask-user` in a scratch directory outside this repo and confirm it exits 0 with no interactive prompt (no TTY attached, e.g. via `</dev/null`). Verified by: the command's exit status is 0 and it produces output without blocking. Ran against real `copilot` v1.0.80 in `/tmp/copilot-verify-scratch` — exited 0, printed "OK", no interactive prompt.
- [x] 1.2 If step 1.1 blocks on anything (e.g. a first-run auth/login prompt), record the finding in this change's `design.md` Open Questions and resolve the flag set before proceeding to section 2. Verified by: 1.1 passing, or `design.md` updated to reflect the actual required flags. Not needed — 1.1 passed cleanly.

## 2. Register copilot as a supported harness (repository: sergeant-v2)

- [x] 2.1 Add `"copilot"` to `SupportedAgents` in `internal/runner/runner.go:222`. Verified by: `go build ./...` succeeds.
- [x] 2.2 Add a `case "copilot":` to `BuildAgentCommand` in `internal/runner/runner.go:402` with base args `[]string{"-p", prompt, "--allow-all-tools", "--no-ask-user"}` and no `-C`, per `design.md` Decisions. Task 7.1 later extends this base argv with measured conditional model forwarding. Verified by: `go build ./...` succeeds.

## 3. Tests (repository: sergeant-v2)

- [x] 3.1 Add copilot cases to the table-driven test in `internal/runner/agent_command_test.go` asserting the prompt follows `-p` and that `--allow-all-tools`/`--no-ask-user` are present, mirroring the existing `claude`/`goose` cases. Verified by: `go test ./internal/runner/... -run TestBuildAgentCommand -count=1` passes.
- [x] 3.2 Add a dedicated regression test asserting no `-C` flag is emitted for copilot regardless of worktree, matching the pattern of `TestClaudeIsInvokedWithoutPermissionPrompts`. Verified by: `go test ./internal/runner/... -count=1` passes.
- [x] 3.3 The initial implementation added a regression asserting no model flag was emitted. This historical decision was superseded after Copilot CLI v1.0.82 exposed a measured `--model` transport; task 6.1 replaces the obsolete assertion.
- [x] 3.4 Add a case to whatever existing test asserts `ValidateAgent`'s accept/reject behavior (bare name and full-path form) for `copilot`. Verified by: `go test ./internal/runner/... -count=1` passes. No prior `ValidateAgent` test existed; added `TestValidateAgentAcceptsCopilot` covering bare name, full path, and continued rejection of an unknown name.

## 4. Historical validation record (repository: sergeant-v2)

The original task list claimed the full validation command exited 0 while also
recording failures. That contradictory record is not treated as a completed
gate. Task 9.2 owns the current full-gate requirement.

## 5. Reopen the incomplete contract (repository: sergeant)

- [x] 5.1 Expand the proposal, design, and agent-harness specification to cover Copilot prerequisite discovery and measured `--model` forwarding. Explicitly defer JSON/usage/provenance, minimum-version enforcement, and SDK integration. Verified by: `openspec validate copilot-cli-agent-support --strict` exits 0.

## 6. Add red-capable gap regressions (repository: sergeant)

- [x] 6.1 Replace the obsolete no-model regression with cases requiring `--model <requested-model>` for a non-empty model and no flag for an empty model. Before implementation, `go test ./internal/runner -run TestCopilotForwardsRequestedModel -count=1` failed because the built argv omitted `--model`.
- [x] 6.2 Extend the controlled-PATH prerequisite test so every entry in `runner.SupportedAgents`, including `copilot`, must satisfy the real extracted `mise run check` task. Before implementation, `go test ./internal/repopolicy -run TestMiseCheckValidatesV2EnginePrerequisites -count=1` failed for both Copilot discovery and the stale missing-agent diagnostic.

## 7. Close runtime and prerequisite gaps (repository: sergeant)

- [x] 7.1 Forward a non-empty Copilot model request as `--model <model>` without changing `-p`, `--allow-all-tools`, `--no-ask-user`, or caller-owned working-directory behavior. Verified by: `go test ./internal/runner -run 'Test(BuildAgentCommand|Copilot|ValidateAgent)' -count=1` exits 0.
- [x] 7.2 Add `copilot` to `mise.toml`'s supported-harness discovery and missing-agent diagnostic. Verified by: `go test ./internal/repopolicy -run TestMiseCheckValidatesV2EnginePrerequisites -count=1` and `mise run check` both exit 0 in a Copilot-only harness environment.

## 8. Correct live documentation (repository: sergeant)

- [x] 8.1 Add Copilot to supported-harness guidance in `README.md`, `AGENTS.md`, and `docs/prd-sergeant-v2.md`; update `docs/prd-copilot-cli-agent-support.md` for the expanded scope and measured model flag. Do not edit historical archives. Verified by: `git grep -n 'copilot' -- README.md AGENTS.md docs/prd-sergeant-v2.md docs/prd-copilot-cli-agent-support.md` exits 0 and each live document names Copilot.

## 9. Re-run validation before SDK work (repository: sergeant)

- [x] 9.1 Validate the reopened OpenSpec and focused implementation with `openspec validate copilot-cli-agent-support --strict && go test ./internal/runner -run 'Test(BuildAgentCommand|Copilot|ValidateAgent)' -count=1 && go test ./internal/repopolicy -run TestMiseCheckValidatesV2EnginePrerequisites -count=1 && go build ./... && go vet ./internal/...`.
- [ ] 9.2 Run `go test ./internal/... -count=1`. Do not mark this task or the change complete if the full gate fails; current baseline failures include unavailable `graphify` and unrelated repository skill-inventory drift.
- [x] 9.3 Confirm the diff contains no Copilot SDK implementation with `test -z "$(git diff --name-only origin/v2 | grep -Ev '^(README.md|AGENTS.md|docs/prd-(sergeant-v2|copilot-cli-agent-support).md|internal/(runner/(runner.go|agent_command_test.go)|repopolicy/mise_check_test.go)|mise.toml|openspec/changes/copilot-cli-agent-support/)')"`.
