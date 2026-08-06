// cmd/sergeant-mcp/main.go — MCP stdio server wrapping all sgt-* scripts.
//
// Each Sergeant shell script is exposed as an MCP tool. Tools accept an "args"
// string (raw CLI arguments, shell-quoted as needed) plus a "stdin" string for
// commands that read from standard input (sgt-respond).
//
// The binary must live in the same directory as the sgt-* scripts (bin/) so
// that scriptDir() resolves correctly. Build with:
//
//	go build -o bin/sergeant-mcp ./cmd/sergeant-mcp/
package main

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"
)

// scriptDir returns the directory containing this binary, which must be the
// same bin/ directory that holds the sgt-* shell scripts.
func scriptDir() string {
	exe, err := os.Executable()
	if err != nil {
		// Fall back to the working directory.
		wd, _ := os.Getwd()
		return filepath.Join(wd, "bin")
	}
	// Resolve symlinks so the path is stable.
	resolved, err := filepath.EvalSymlinks(exe)
	if err != nil {
		resolved = exe
	}
	return filepath.Dir(resolved)
}

// shellSplit splits a shell-style argument string honouring single and double
// quotes. It does not handle backslash escapes or variable expansion — agents
// should quote values that contain spaces.
func shellSplit(s string) []string {
	var args []string
	var cur strings.Builder
	inSingle, inDouble := false, false

	for _, r := range s {
		switch {
		case r == '\'' && !inDouble:
			inSingle = !inSingle
		case r == '"' && !inSingle:
			inDouble = !inDouble
		case (r == ' ' || r == '\t') && !inSingle && !inDouble:
			if cur.Len() > 0 {
				args = append(args, cur.String())
				cur.Reset()
			}
		default:
			cur.WriteRune(r)
		}
	}
	if cur.Len() > 0 {
		args = append(args, cur.String())
	}
	return args
}

// runScript shells out to a named script in the same directory as this binary.
// stdin is optional — pass an empty string when not needed.
func runScript(ctx context.Context, scriptName, rawArgs, stdinData string) (*mcp.CallToolResult, error) {
	bin := filepath.Join(scriptDir(), scriptName)

	var argv []string
	if strings.TrimSpace(rawArgs) != "" {
		argv = shellSplit(rawArgs)
	}

	cmd := exec.CommandContext(ctx, bin, argv...)
	cmd.Env = os.Environ()

	if stdinData != "" {
		cmd.Stdin = strings.NewReader(stdinData)
	}

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err := cmd.Run()
	if err != nil {
		errMsg := strings.TrimSpace(stderr.String())
		if errMsg == "" {
			errMsg = err.Error()
		}
		// Include any stdout in the error for diagnostics.
		if out := strings.TrimSpace(stdout.String()); out != "" {
			errMsg = out + "\n" + errMsg
		}
		return mcp.NewToolResultError(errMsg), nil
	}

	out := strings.TrimSpace(stdout.String())
	if out == "" {
		out = "(no output)"
	}
	return mcp.NewToolResultText(out), nil
}

// toolDef describes one Sergeant script exposed as an MCP tool.
type toolDef struct {
	scriptName  string
	toolName    string
	description string
	argsDesc    string
	needsStdin  bool
	stdinDesc   string
}

var tools = []toolDef{
	{
		scriptName:  "sgt-dispatch",
		toolName:    "sgt-dispatch",
		description: "Dispatch subagents across repos in a project. Creates an isolated git worktree per repo, writes a mission brief, and spawns an agent in a local tmux window.",
		argsDesc:    `CLI args: <project> "<brief>" --repos repo1,repo2 [--td <id>] [--branch <name>] [--adopt-branch] [--deps "r1>r2"] [--agent opencode|goose|claude] [--model <tuple>] [--stage <name>] [--coordinator-pane <id>] [--managed-coordinator-pane] [--intent-file <path>] [--origin-profile <name>] [--correlation-id <id>] [--dry-run]`,
	},
	{
		scriptName:  "sgt-watch",
		toolName:    "sgt-watch",
		description: "Monitor a dispatched fleet and report outcomes. Supports snapshot, list, sync, and background modes.",
		argsDesc:    `CLI args: <task-id> [--snapshot] [--list] [--sync] [--sync-all] [--background]`,
	},
	{
		scriptName:  "sgt-wake",
		toolName:    "sgt-wake",
		description: "Evaluate a durable wake condition and resume a waiting worker. Supports not_before, github_check, fleet_dependency, td_dependency, deployment, and human_response conditions.",
		argsDesc:    `CLI args: <task-id> <repo>`,
	},
	{
		scriptName:  "sgt-respond",
		toolName:    "sgt-respond",
		description: "Deliver a response to a waiting worker and resume it if dead. The response text is passed via the stdin parameter.",
		argsDesc:    `CLI args: <task-id> <repo>`,
		needsStdin:  true,
		stdinDesc:   "The response text to deliver to the worker.",
	},
	{
		scriptName:  "sgt-review-findings",
		toolName:    "sgt-review-findings",
		description: "Route structured independent-review findings to td (task database).",
		argsDesc:    `CLI args: <project> <repo> --input <json> --axis <axis> --source <source> --branch <branch> --head-sha <sha> --parent-task <id> --task-id <fleet-id> --worktree <path>`,
	},
	{
		scriptName:  "sgt-validate",
		toolName:    "sgt-validate",
		description: "Launch coordinator-owned no-mistakes validation beside an interactive worker.",
		argsDesc:    `CLI args: <task-id> <repo> [--skip <steps>] [--claim-ownership] [--release-ownership] [--allow-argv-intent]`,
	},
	{
		scriptName:  "sgt-drain",
		toolName:    "sgt-drain",
		description: "Set or remove a persistent drain on a Sergeant project or globally. When drained, new pane starts are refused; responses are stored for later delivery.",
		argsDesc:    `CLI args: [<project>] [--reason <text>] [--wait] [--timeout <s>] [--global] [--undrain] [--status]`,
	},
	{
		scriptName:  "sgt-drain-force",
		toolName:    "sgt-drain-force",
		description: "Force-stop workers that failed cooperative drain. Requires an active drain. Use --dry-run to preview; --yes to confirm.",
		argsDesc:    `CLI args: --global [--dry-run] [--yes]  OR  --project <project> [--dry-run] [--yes]`,
	},
	{
		scriptName:  "sgt-cleanup",
		toolName:    "sgt-cleanup",
		description: "Remove worktrees and fleet state for a completed task. Handles both treehouse-leased and plain git worktrees.",
		argsDesc:    `CLI args: <task-id> [<repo>]`,
	},
	{
		scriptName:  "sgt-recover",
		toolName:    "sgt-recover",
		description: "Attempt one bounded stall recovery for a stalled in-progress worker. Kills the stalled pane and relaunches a fresh worker.",
		argsDesc:    `CLI args: <task-id> <repo>`,
	},
	{
		scriptName:  "sgt-ack-response",
		toolName:    "sgt-ack-response",
		description: "Acknowledge and clear one consumed worker response.",
		argsDesc:    `CLI args: <task-id> <repo> <response-id>`,
	},
	{
		scriptName:  "sgt-list",
		toolName:    "sgt-list",
		description: "List all known Sergeant projects from ~/.config/sergeant/.",
		argsDesc:    `CLI args: (none)`,
	},
	{
		scriptName:  "sgt-status",
		toolName:    "sgt-status",
		description: "Show git status across every repo in a Sergeant project.",
		argsDesc:    `CLI args: <project>`,
	},
	{
		scriptName:  "sgt-context",
		toolName:    "sgt-context",
		description: "Emit a structured agent context block for a project. Resolves instruction layering (defaults → group → repo) and prints an orientation block.",
		argsDesc:    `CLI args: <project>`,
	},
	{
		scriptName:  "sgt-callback",
		toolName:    "sgt-callback",
		description: "Durable, profile-bound callback events for Sergeant fleet tasks. Records needs_input, blocked, failed, and done events with tamper-evident chaining.",
		argsDesc:    `CLI args: pass all sgt-callback subcommand and flags as a single args string (e.g. "emit --profile <profile> --task-id <id> --event done --payload <text>")`,
	},
	{
		scriptName:  "sgt-notify",
		toolName:    "sgt-notify",
		description: `Inject a worker update into the primary Sergeant session. Records a wake marker for the fleet watcher. Message prefixes: done|failed for completion, needs_input|blocked for escalation.`,
		argsDesc:    `CLI args: <task-id> "<message>"`,
	},
	{
		scriptName:  "sgt-sync",
		toolName:    "sgt-sync",
		description: "Clone missing repos and pull existing ones for a Sergeant project.",
		argsDesc:    `CLI args: <project>`,
	},
	{
		scriptName:  "sgt-td-create",
		toolName:    "sgt-td-create",
		description: "Create td tasks in project repos for a cross-repo brief. All-or-nothing: rolls back on partial failure.",
		argsDesc:    `CLI args: <project> "<title>" --repos repo1,repo2 [--description "<text>"] [--type bug|feature|task|chore] [--priority P0-P4] [--parent <id>] [--json]`,
	},
	{
		scriptName:  "sgt-td-list",
		toolName:    "sgt-td-list",
		description: "Show td tasks across all repos in a Sergeant project.",
		argsDesc:    `CLI args: <project> [--all] [--status open|done|...] [--priority P0-P4] [--repos repo1,repo2] [--json]`,
	},
	{
		scriptName:  "sgt-td-memory",
		toolName:    "sgt-td-memory",
		description: "Record non-secret worker recovery pointers in td. Called by the fleet supervisor to attach handoff or response evidence to a task.",
		argsDesc:    `CLI args: <handoff|response> <repo-state-dir> <worktree>`,
	},
	{
		scriptName:  "sgt-graphify",
		toolName:    "sgt-graphify",
		description: "Run graphify across all repos in a Sergeant project and publish the merged graph atomically.",
		argsDesc:    `CLI args: <project>`,
	},
	{
		scriptName:  "sgt-no-mistakes-finding",
		toolName:    "sgt-no-mistakes-finding",
		description: "Apply a disposition (gate|td|ignore|ask-user) to one no-mistakes finding.",
		argsDesc:    `CLI args: <project> <repo> --run-id <id> --head-sha <sha> --finding-id <id> --severity <error|warning|info> --kind <kind> --description <text> --intent <text> [--file <path>] [--line <line>] --disposition <gate|td|ignore|ask-user>`,
	},
	{
		scriptName:  "sgt-undrain",
		toolName:    "sgt-undrain",
		description: "Remove a drain record for a project or globally, restoring admission for that scope. Idempotent.",
		argsDesc:    `CLI args: --global  OR  <project>`,
	},
	{
		scriptName:  "sgt-treehouse-init",
		toolName:    "sgt-treehouse-init",
		description: "Initialize treehouse worktree pools in a project's repos. After running, sgt-dispatch will automatically use treehouse for those repos.",
		argsDesc:    `CLI args: <project> [--groups group1,group2,...]`,
	},
	{
		scriptName:  "wiki-daily-digest",
		toolName:    "wiki-daily-digest",
		description: "Synthesize a daily wiki session digest from AI agent history. Reads opencode, goose, and claude sessions, enriches with PRs and td completions, and writes to ~/wiki/sessions/.",
		argsDesc:    `CLI args: [--date YYYY-MM-DD|yesterday] [--dry-run] [--since YYYY-MM-DD]`,
	},
	{
		scriptName:  "sgt-dag-dispatch-hook",
		toolName:    "sgt-dag-dispatch-hook",
		description: "Stage hook called by dagr when a stage becomes ready. Calls sgt-dispatch and writes dagr tracking files so sgt-watch can auto-advance the DAG on completion.",
		argsDesc:    `CLI args: (same as sgt-dispatch; requires DAGR_RUN_ID and DAGR_STAGE_ID env vars)`,
	},
	{
		scriptName:  "sgt-dag-run",
		toolName:    "sgt-dag-run",
		description: "Create and start a dagr run from a Sergeant project's DAG definition. Reads the dag: block from the project YAML and dispatches initially ready stages.",
		argsDesc:    `CLI args: <project> [--dry-run]`,
	},
	{
		scriptName:  "sgt-interactive-worker",
		toolName:    "sgt-interactive-worker",
		description: "Own one persistent interactive agent pane. NOTE: requires a real TTY — this tool will fail when invoked via MCP stdio; use sgt-dispatch to launch workers instead.",
		argsDesc:    `CLI args: <repo-state-dir> <worktree> <agent>`,
	},
	{
		scriptName:  "sgt-validation-worker",
		toolName:    "sgt-validation-worker",
		description: "Run coordinator-owned no-mistakes in an interactive pane. NOTE: requires a real TTY — use sgt-validate to launch this indirectly via sgt-dispatch.",
		argsDesc:    `CLI args: <repo-state-dir> <worktree> <intent-revision> <intent-transport> [skip]`,
	},
	{
		scriptName:  "sgt-msg-send",
		toolName:    "sgt-msg-send",
		description: "Send a message to an agent inbox in a project. Creates a SQLite-backed durable message for inter-agent communication.",
		argsDesc:    `CLI args: <project> --from <agent> --to <agent|broadcast> \"<message>\" [--metadata <json>]`,
	},
	{
		scriptName:  "sgt-msg-recv",
		toolName:    "sgt-msg-recv",
		description: "Read messages for an agent in a project inbox. Returns a JSON array of message objects.",
		argsDesc:    `CLI args: <project> --agent <agent> [--unread-only] [--mark-read] [--limit N]`,
	},
	{
		scriptName:  "sgt-msg-ack",
		toolName:    "sgt-msg-ack",
		description: "Acknowledge (mark read) a specific message by ID in a project inbox.",
		argsDesc:    `CLI args: <project> <message-id>`,
	},
	{
		scriptName:  "sgt-msg-list",
		toolName:    "sgt-msg-list",
		description: "List messages in a project inbox in a human-readable table. Shows id, from, to, sent_at, read status, and body preview.",
		argsDesc:    `CLI args: <project> [--all] [--agent <agent>]`,
	},
}

func main() {
	s := server.NewMCPServer(
		"sergeant",
		"1.0.0",
		server.WithToolCapabilities(false),
	)

	for _, td := range tools {
		td := td // capture loop variable

		opts := []mcp.ToolOption{
			mcp.WithDescription(td.description),
			mcp.WithString("args",
				mcp.Description(td.argsDesc),
			),
		}
		if td.needsStdin {
			opts = append(opts, mcp.WithString("stdin",
				mcp.Description(td.stdinDesc),
			))
		}

		tool := mcp.NewTool(td.toolName, opts...)

		s.AddTool(tool, func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			rawArgs := req.GetString("args", "")
			stdinData := ""
			if td.needsStdin {
				stdinData = req.GetString("stdin", "")
			}
			return runScript(ctx, td.scriptName, rawArgs, stdinData)
		})
	}

	fmt.Fprintf(os.Stderr, "sergeant-mcp: %d tools registered (Go %s, pid %d)\n",
		len(tools), runtime.Version(), os.Getpid())

	if err := server.ServeStdio(s); err != nil {
		fmt.Fprintf(os.Stderr, "sergeant-mcp: fatal: %v\n", err)
		os.Exit(1)
	}
}
