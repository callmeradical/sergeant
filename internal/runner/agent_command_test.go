package runner

import (
	"strings"
	"testing"
)

// The prompt must reach the agent. Every supported harness has its own way of
// accepting one, and passing it the wrong way fails in a manner that looks like
// agent failure rather than a malformed command.
//
// goose is the regression this test exists for. BuildAgentCommand produced
// `goose run <prompt>`, but `goose run` has no positional text argument — it
// takes -t/--text or -i/--instructions. Every goose dispatch therefore died with
// "error: unexpected argument", and goose had never worked in v2.
func TestBuildAgentCommandPassesThePromptInAFormTheHarnessAccepts(t *testing.T) {
	const prompt = "implement the thing"

	cases := []struct {
		agent     string
		wantFlag  string // the flag that must immediately precede the prompt
		wantExtra []string
	}{
		{agent: "goose", wantFlag: "-t", wantExtra: []string{"run", "--no-session"}},
		{agent: "claude", wantFlag: "", wantExtra: []string{"--print"}},
		{agent: "opencode", wantFlag: "", wantExtra: []string{"run"}},
		{agent: "copilot", wantFlag: "-p", wantExtra: []string{"--allow-all-tools", "--no-ask-user"}},
	}

	for _, tc := range cases {
		t.Run(tc.agent, func(t *testing.T) {
			_, args, _ := BuildAgentCommand(tc.agent, "", prompt)

			idx := -1
			for i, a := range args {
				if a == prompt {
					idx = i
				}
			}
			if idx < 0 {
				t.Fatalf("%s: the prompt does not appear in args %q", tc.agent, args)
			}

			if tc.wantFlag != "" {
				if idx == 0 || args[idx-1] != tc.wantFlag {
					t.Errorf("%s: prompt must be preceded by %q, got args %q; a bare positional prompt is rejected by the CLI",
						tc.agent, tc.wantFlag, args)
				}
			}
			for _, want := range tc.wantExtra {
				var found bool
				for _, a := range args {
					if a == want {
						found = true
					}
				}
				if !found {
					t.Errorf("%s: args %q missing %q", tc.agent, args, want)
				}
			}
		})
	}
}

// R2.3: agent invocations use non-interactive flags, so no phase depends on
// terminal input. goose stays interactive after processing its input unless told
// otherwise, which in a headless run means the phase hangs until its context is
// cancelled rather than finishing.
func TestGooseIsInvokedNonInteractively(t *testing.T) {
	_, args, _ := BuildAgentCommand("goose", "", "do the thing")
	joined := strings.Join(args, " ")

	if !strings.Contains(joined, "--no-session") {
		t.Errorf("goose args %q lack --no-session; a dispatched run must not leave session state behind", args)
	}
	for _, forbidden := range []string{"-s", "--interactive"} {
		for _, a := range args {
			if a == forbidden {
				t.Errorf("goose args %q contain %q, which keeps the process interactive after input", args, forbidden)
			}
		}
	}
}

// Usage and cost are recorded per session by goose itself, keyed by working
// directory. Asking for JSON output keeps that data reachable from the phase
// rather than only from goose's database after the fact.
func TestGooseRequestsMachineReadableOutput(t *testing.T) {
	_, args, _ := BuildAgentCommand("goose", "", "do the thing")
	joined := strings.Join(args, " ")
	if !strings.Contains(joined, "--output-format") {
		t.Errorf("goose args %q do not request a machine-readable output format; "+
			"per-phase token and cost metadata is discarded", args)
	}
}

// A dispatched claude phase has no TTY, so claude's default permission mode
// cannot prompt for approval of the Write/Edit tools an implementation phase
// needs — it can only print a request for approval and exit, producing zero
// code changes while still consuming a full agent-phase attempt. This
// regression was found running the real CLI headlessly: `claude --print
// <prompt>` alone printed "I need your approval to write files in this
// repo..." and returned, with no commit and no diff. The isolated worktree
// D3/D4 already require for any dispatched work (internal/dag/engine.go) is
// exactly the safety boundary that makes bypassing the prompt here safe.
func TestClaudeIsInvokedWithoutPermissionPrompts(t *testing.T) {
	_, args, _ := BuildAgentCommand("claude", "", "do the thing")
	joined := strings.Join(args, " ")
	if !strings.Contains(joined, "--dangerously-skip-permissions") {
		t.Errorf("claude args %q lack --dangerously-skip-permissions; a headless dispatch "+
			"cannot answer a permission prompt and will exit having written nothing", args)
	}
}

// A dispatched copilot phase has no TTY, so --allow-all-tools bypasses
// per-tool approval prompts the same way --dangerously-skip-permissions does
// for claude, and --no-ask-user disables copilot's ask_user tool so it can
// never stall a headless run waiting on clarification that has nowhere to
// go. Verified against the real `copilot` v1.0.80 binary run headlessly with
// both flags: it completed and exited 0 with no interactive prompt.
func TestCopilotIsInvokedWithoutPermissionPromptsOrClarificationStalls(t *testing.T) {
	_, args, _ := BuildAgentCommand("copilot", "", "do the thing")
	joined := strings.Join(args, " ")
	if !strings.Contains(joined, "--allow-all-tools") {
		t.Errorf("copilot args %q lack --allow-all-tools; a headless dispatch "+
			"cannot answer a tool-approval prompt and will exit having written nothing", args)
	}
	if !strings.Contains(joined, "--no-ask-user") {
		t.Errorf("copilot args %q lack --no-ask-user; a headless dispatch has no TTY "+
			"to answer an interactive clarification request", args)
	}
}

// Working directory comes from cmd.Dir at the shared call site, the same way
// every other harness gets it. Copilot's own -C flag is a second way to set
// the same thing; using both risks disagreement between them, so copilot
// must never receive -C from BuildAgentCommand.
func TestCopilotDoesNotReceiveAWorkingDirectoryFlag(t *testing.T) {
	_, args, _ := BuildAgentCommand("copilot", "", "do the thing")
	for _, a := range args {
		if a == "-C" {
			t.Errorf("copilot args %q contain -C; working directory must come only from cmd.Dir", args)
		}
	}
}

// Copilot CLI exposes --model as its per-invocation model selector. Sergeant
// must honor an explicit model without forcing a flag when the operator wants
// Copilot's configured default.
func TestCopilotForwardsRequestedModel(t *testing.T) {
	const requestedModel = "claude-sonnet-4.6"

	_, withModel, _ := BuildAgentCommand("copilot", requestedModel, "do the thing")
	modelFlag := -1
	for i, arg := range withModel {
		if arg == "--model" {
			modelFlag = i
			break
		}
	}
	if modelFlag < 0 || modelFlag+1 >= len(withModel) || withModel[modelFlag+1] != requestedModel {
		t.Errorf("copilot args %q do not forward --model %q", withModel, requestedModel)
	}

	_, withoutModel, _ := BuildAgentCommand("copilot", "", "do the thing")
	for _, arg := range withoutModel {
		if arg == "--model" {
			t.Errorf("copilot args %q contain --model without a requested model", withoutModel)
		}
	}
}

// copilot must be accepted the same way every other supported harness
// already is: by bare name and by a full path whose final element is the
// harness name, and an unrelated, unregistered name must still be rejected.
func TestValidateAgentAcceptsCopilot(t *testing.T) {
	if err := ValidateAgent("copilot"); err != nil {
		t.Errorf("ValidateAgent(\"copilot\") = %v, want nil", err)
	}
	if err := ValidateAgent("/Users/lcromley/.local/bin/copilot"); err != nil {
		t.Errorf("ValidateAgent(full path to copilot) = %v, want nil", err)
	}
	if err := ValidateAgent("not-a-real-agent"); err == nil {
		t.Error("ValidateAgent(\"not-a-real-agent\") = nil, want an error naming the supported harnesses")
	}
}
