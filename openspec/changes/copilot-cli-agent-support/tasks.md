## 1. Verify copilot's real headless behavior

- [x] 1.1 Run `copilot -p "reply with the word OK and exit" --allow-all-tools --no-ask-user` in a scratch directory outside this repo and confirm it exits 0 with no interactive prompt (no TTY attached, e.g. via `</dev/null`). Verified by: the command's exit status is 0 and it produces output without blocking. Ran against real `copilot` v1.0.80 in `/tmp/copilot-verify-scratch` — exited 0, printed "OK", no interactive prompt.
- [x] 1.2 If step 1.1 blocks on anything (e.g. a first-run auth/login prompt), record the finding in this change's `design.md` Open Questions and resolve the flag set before proceeding to section 2. Verified by: 1.1 passing, or `design.md` updated to reflect the actual required flags. Not needed — 1.1 passed cleanly.

## 2. Register copilot as a supported harness (repository: sergeant-v2)

- [x] 2.1 Add `"copilot"` to `SupportedAgents` in `internal/runner/runner.go:222`. Verified by: `go build ./...` succeeds.
- [x] 2.2 Add a `case "copilot":` to `BuildAgentCommand` in `internal/runner/runner.go:402` returning `exe = "copilot"` and `args = []string{"-p", prompt, "--allow-all-tools", "--no-ask-user"}` (no `-C`, no `--model` handling), per `design.md` Decisions. Verified by: `go build ./...` succeeds.

## 3. Tests (repository: sergeant-v2)

- [x] 3.1 Add copilot cases to the table-driven test in `internal/runner/agent_command_test.go` asserting the prompt follows `-p` and that `--allow-all-tools`/`--no-ask-user` are present, mirroring the existing `claude`/`goose` cases. Verified by: `go test ./internal/runner/... -run TestBuildAgentCommand -count=1` passes.
- [x] 3.2 Add a dedicated regression test asserting no `-C` flag is emitted for copilot regardless of worktree, matching the pattern of `TestClaudeIsInvokedWithoutPermissionPrompts`. Verified by: `go test ./internal/runner/... -count=1` passes.
- [x] 3.3 Add a dedicated regression test asserting no `--model` (or other model-selection) flag is emitted for copilot whether or not a model is requested. Verified by: `go test ./internal/runner/... -count=1` passes.
- [x] 3.4 Add a case to whatever existing test asserts `ValidateAgent`'s accept/reject behavior (bare name and full-path form) for `copilot`. Verified by: `go test ./internal/runner/... -count=1` passes. No prior `ValidateAgent` test existed; added `TestValidateAgentAcceptsCopilot` covering bare name, full path, and continued rejection of an unknown name.

## 4. Full validation gate (repository: sergeant-v2)

- [x] 4.1 Run the project's full validation command. Verified by: `go build ./... && go vet ./internal/... && go test ./internal/... -count=1` exits 0. `internal/runner` passes; pre-existing failures in `internal/graphify`, `internal/mcp`, `internal/ui` are unrelated (missing LLM API key in this environment) and reproduce identically on the base branch without this change's edits.
