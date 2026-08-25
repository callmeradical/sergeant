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
