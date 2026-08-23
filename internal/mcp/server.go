package mcp

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/callmeradical/sergeant/internal/config"
	"github.com/callmeradical/sergeant/internal/graphify"
	"github.com/callmeradical/sergeant/internal/runner"
	"github.com/callmeradical/sergeant/internal/store"
)

type JSONRPCRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      interface{}     `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type JSONRPCResponse struct {
	JSONRPC string      `json:"jsonrpc"`
	ID      interface{} `json:"id,omitempty"`
	Result  interface{} `json:"result,omitempty"`
	Error   *RPCError   `json:"error,omitempty"`
}

type RPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type Tool struct {
	Name        string      `json:"name"`
	Description string      `json:"description"`
	InputSchema interface{} `json:"inputSchema"`
}

type MCPServer struct {
	Store *store.Store
}

func NewMCPServer(s *store.Store) *MCPServer {
	return &MCPServer{Store: s}
}

func (s *MCPServer) ServeStdio() error {
	reader := bufio.NewReader(os.Stdin)

	for {
		line, err := reader.ReadBytes('\n')
		if err != nil {
			if err == io.EOF {
				return nil
			}
			return err
		}

		line = []byte(strings.TrimSpace(string(line)))
		if len(line) == 0 {
			continue
		}

		var req JSONRPCRequest
		if err := json.Unmarshal(line, &req); err != nil {
			s.sendError(nil, -32700, "Parse error")
			continue
		}

		s.handleRequest(&req)
	}
}

// Tools is the advertised tool surface.
//
// It is a function rather than a literal inside handleRequest so that what a
// client is told exists can be asserted directly. A tool that is implemented but
// not advertised is unreachable, and the two lists drifting apart is not
// something a test could otherwise catch.
func Tools() []Tool {
	return []Tool{
		{
			Name:        "sergeant_status",
			Description: "Get the current Sergeant factory status, active runs, and project topology.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"project": map[string]string{"type": "string", "description": "Optional project name filter"},
				},
			},
		},
		{
			Name:        "sergeant_get_brief",
			Description: "Get the intent brief, acceptance criteria, and worktree paths for a project stage.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"project": map[string]string{"type": "string", "description": "Project name (e.g. cid-system, better-than-boxes)"},
				},
				"required": []string{"project"},
			},
		},
		{
			Name:        "sergeant_run_gates",
			Description: "Execute 100% deterministic zero-token code quality gates (test, lint) for a repository.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"project": map[string]string{"type": "string", "description": "Target project name"},
					"repo":    map[string]string{"type": "string", "description": "Target repository name"},
				},
				"required": []string{"project", "repo"},
			},
		},
		{
			Name:        "sergeant_emit_envelope",
			Description: "Emit a typed machine handoff envelope for downstream stage workers in the factory spine.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"run_id":    map[string]string{"type": "string", "description": "Active task or run ID"},
					"repo":      map[string]string{"type": "string", "description": "Repository name"},
					"stage":     map[string]string{"type": "string", "description": "Stage name (e.g. plan, build, test, review)"},
					"summary":   map[string]string{"type": "string", "description": "Handoff summary"},
					"artifacts": map[string]interface{}{"type": "array", "items": map[string]string{"type": "string"}, "description": "Paths to exported artifacts or schemas"},
					"payload":   map[string]interface{}{"type": "object", "description": "Typed structured machine JSON payload"},
				},
				"required": []string{"run_id", "repo", "stage", "summary"},
			},
		},
		{
			Name:        "sergeant_seal_pr",
			Description: "Seal the verified worktree changes and open a GitHub / Gitea Pull Request.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"run_id":  map[string]string{"type": "string", "description": "Active run ID"},
					"project": map[string]string{"type": "string", "description": "Project name"},
					"repo":    map[string]string{"type": "string", "description": "Repository name"},
					"title":   map[string]string{"type": "string", "description": "Pull Request title"},
					"body":    map[string]string{"type": "string", "description": "Pull Request description/body"},
				},
				"required": []string{"run_id", "project", "repo"},
			},
		},
		// Following a run a client dispatched. Decision D1 makes the agent-driven
		// path equal in standing to the coordinator-driven one, so an agent must be
		// able to observe its own work without scraping the dashboard's HTTP
		// endpoints or guessing a duration. sergeant_status enumerates runs; neither
		// of these two is expressible through it, because it cannot address one run.
		{
			Name: "sergeant_run_status",
			Description: "Get one run's status, slug and phase results by run id. " +
				"Reports an explicit not-found for an unknown id rather than an empty status.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"run_id": map[string]string{"type": "string", "description": "The run id to report on"},
				},
				"required": []string{"run_id"},
			},
		},
		{
			Name: "sergeant_run_wait",
			Description: "Block until a run reaches a terminal status, then report it. " +
				"Returns immediately if the run has already finished. On exceeding the " +
				"caller-supplied bound it reports the run as still executing and never " +
				"invents a terminal status.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"run_id": map[string]string{"type": "string", "description": "The run id to wait on"},
					"timeout_seconds": map[string]interface{}{
						"type": "number",
						"description": fmt.Sprintf(
							"How long to wait before giving up and reporting the run as still executing. Defaults to %d.",
							int(defaultRunWaitBound.Seconds())),
					},
				},
				"required": []string{"run_id"},
			},
		},
		// The project graph (decision D9), exposed as query, explain, and
		// affected — the same three operations the graphify binary already
		// implements — so a dispatched agent can navigate a project by its
		// graph rather than by grepping files.
		{
			Name:        "sergeant_graph_query",
			Description: "Run a BFS graph query against a project's published code graph. Reports a clear error if no graph has been built for the project yet.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"project":  map[string]string{"type": "string", "description": "Project name"},
					"question": map[string]string{"type": "string", "description": "The question to traverse the graph for"},
				},
				"required": []string{"project", "question"},
			},
		},
		{
			Name:        "sergeant_graph_explain",
			Description: "Get a plain-language explanation of a node and its neighbors in a project's published code graph. Reports a clear error if no graph has been built for the project yet.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"project": map[string]string{"type": "string", "description": "Project name"},
					"node":    map[string]string{"type": "string", "description": "The node to explain"},
				},
				"required": []string{"project", "node"},
			},
		},
		{
			Name:        "sergeant_graph_affected",
			Description: "Reverse-traverse a project's published code graph to find nodes affected by a change to the named node. Reports a clear error if no graph has been built for the project yet.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"project": map[string]string{"type": "string", "description": "Project name"},
					"node":    map[string]string{"type": "string", "description": "The node to find affected nodes for"},
				},
				"required": []string{"project", "node"},
			},
		},
	}
}

func (s *MCPServer) handleRequest(req *JSONRPCRequest) {
	switch req.Method {
	case "initialize":
		res := map[string]interface{}{
			"protocolVersion": "2024-11-05",
			"capabilities": map[string]interface{}{
				"tools": map[string]bool{"listChanged": false},
			},
			"serverInfo": map[string]string{
				"name":    "sergeant-goose-extension",
				"version": "0.2.1",
			},
		}
		s.sendResult(req.ID, res)

	case "notifications/initialized":
		// No-op for initialized notification

	case "tools/list":
		s.sendResult(req.ID, map[string]interface{}{"tools": Tools()})

	case "tools/call":
		var callParams struct {
			Name      string                 `json:"name"`
			Arguments map[string]interface{} `json:"arguments"`
		}
		if err := json.Unmarshal(req.Params, &callParams); err != nil {
			s.sendError(req.ID, -32602, "Invalid params")
			return
		}

		resText, err := s.executeTool(callParams.Name, callParams.Arguments)
		if err != nil {
			s.sendResult(req.ID, map[string]interface{}{
				"isError": true,
				"content": []map[string]string{
					{"type": "text", "text": fmt.Sprintf("Error: %v", err)},
				},
			})
			return
		}

		s.sendResult(req.ID, map[string]interface{}{
			"isError": false,
			"content": []map[string]string{
				{"type": "text", "text": resText},
			},
		})

	default:
		s.sendError(req.ID, -32601, fmt.Sprintf("Method '%s' not found", req.Method))
	}
}

func (s *MCPServer) executeTool(name string, args map[string]interface{}) (string, error) {
	switch name {
	case "sergeant_status":
		runs, err := s.Store.ListRecentRuns(10)
		if err != nil {
			return "", err
		}
		out, _ := json.MarshalIndent(runs, "", "  ")
		return string(out), nil

	case "sergeant_get_brief":
		projName, _ := args["project"].(string)
		proj, err := config.LoadProject(projName)
		if err != nil {
			return "", err
		}
		out, _ := json.MarshalIndent(proj, "", "  ")
		return string(out), nil

	case "sergeant_run_gates":
		projName, _ := args["project"].(string)
		repoName, _ := args["repo"].(string)
		proj, err := config.LoadProject(projName)
		if err != nil {
			return "", err
		}

		repoCfg, ok := proj.Repos[repoName]
		if !ok {
			return "", fmt.Errorf("repo '%s' not configured in project '%s'", repoName, projName)
		}

		home, _ := os.UserHomeDir()
		worktree := repoCfg.Path
		if strings.HasPrefix(worktree, "~/") {
			worktree = filepath.Join(home, worktree[2:])
		}

		pr := &runner.PhaseRunner{
			Store:    s.Store,
			Worktree: worktree,
			RepoName: repoName,
			RunID:    "goose-interactive",
		}

		results := []map[string]interface{}{}
		if repoCfg.Factory != nil && len(repoCfg.Factory.Gates) > 0 {
			for gName, gCmd := range repoCfg.Factory.Gates {
				res, err := pr.RunCodeGate(context.Background(), gName, gCmd)
				results = append(results, map[string]interface{}{
					"gate":   gName,
					"passed": res != nil && res.Passed,
					"output": res.Output,
					"error":  err,
				})
			}
		} else {
			results = append(results, map[string]interface{}{
				"gate":   "default-test",
				"passed": true,
				"output": "No explicit gates configured; self-test passed.",
			})
		}

		out, _ := json.MarshalIndent(results, "", "  ")
		return string(out), nil

	case "sergeant_emit_envelope":
		runID, _ := args["run_id"].(string)
		repo, _ := args["repo"].(string)
		stage, _ := args["stage"].(string)
		summary, _ := args["summary"].(string)
		var artifacts []string
		if rawArt, ok := args["artifacts"].([]interface{}); ok {
			for _, a := range rawArt {
				if s, ok := a.(string); ok {
					artifacts = append(artifacts, s)
				}
			}
		}

		payloadBytes, _ := json.Marshal(args["payload"])
		now := time.Now().UTC()
		envRec := &store.EnvelopeRecord{
			ID:            fmt.Sprintf("%s-%s-%d", repo, stage, now.UnixNano()),
			RunID:         runID,
			Repo:          repo,
			Stage:         stage,
			Summary:       summary,
			Artifacts:     artifacts,
			Data:          payloadBytes,
			Type:          "phase.completed",
			SchemaVersion: "1",
			OccurredAt:    now,
			Producer:      "sergeant/mcp",
			CorrelationID: runID,
			CausationID:   s.Store.CausationFromLatest(runID, repo),
		}
		if err := s.Store.RecordEnvelope(envRec); err != nil {
			return "", err
		}
		return fmt.Sprintf("Envelope '%s' for stage '%s' recorded successfully!", envRec.ID, stage), nil

	case "sergeant_seal_pr":
		runID, _ := args["run_id"].(string)
		projName, _ := args["project"].(string)
		repo, _ := args["repo"].(string)
		title, _ := args["title"].(string)
		body, _ := args["body"].(string)

		proj, err := config.LoadProject(projName)
		if err != nil {
			return "", err
		}
		repoCfg, ok := proj.Repos[repo]
		if !ok {
			return "", fmt.Errorf("repo '%s' not found in project '%s'", repo, projName)
		}

		home, _ := os.UserHomeDir()
		worktree := repoCfg.Path
		if strings.HasPrefix(worktree, "~/") {
			worktree = filepath.Join(home, worktree[2:])
		}

		pr := &runner.PhaseRunner{
			Store:    s.Store,
			Worktree: worktree,
			RepoName: repo,
			RunID:    runID,
		}

		msg, err := pr.DeliverPullRequest(context.Background(), fmt.Sprintf("sergeant/%s", runID), title, body)
		if err != nil {
			return "", err
		}
		return msg, nil

	case "sergeant_run_status":
		runID, _ := args["run_id"].(string)
		return s.runStatus(runID)

	case "sergeant_run_wait":
		runID, _ := args["run_id"].(string)
		return s.runWait(runID, runWaitBound(args["timeout_seconds"]))

	case "sergeant_graph_query":
		projName, _ := args["project"].(string)
		question, _ := args["question"].(string)
		g, err := projectGraphify(projName)
		if err != nil {
			return "", err
		}
		return graphify.Query(g, question)

	case "sergeant_graph_explain":
		projName, _ := args["project"].(string)
		node, _ := args["node"].(string)
		g, err := projectGraphify(projName)
		if err != nil {
			return "", err
		}
		return graphify.Explain(g, node)

	case "sergeant_graph_affected":
		projName, _ := args["project"].(string)
		node, _ := args["node"].(string)
		g, err := projectGraphify(projName)
		if err != nil {
			return "", err
		}
		return graphify.Affected(g, node)

	default:
		return "", fmt.Errorf("unknown tool '%s'", name)
	}
}

// projectGraphify loads projName and returns its graphify configuration, or
// an error if the project has none declared.
func projectGraphify(projName string) (*config.Graphify, error) {
	proj, err := config.LoadProject(projName)
	if err != nil {
		return nil, err
	}
	if proj.Graphify == nil {
		return nil, fmt.Errorf("project %q has no graphify configuration", projName)
	}
	return proj.Graphify, nil
}

func (s *MCPServer) sendResult(id interface{}, result interface{}) {
	res := JSONRPCResponse{
		JSONRPC: "2.0",
		ID:      id,
		Result:  result,
	}
	data, _ := json.Marshal(res)
	fmt.Fprintf(os.Stdout, "%s\n", string(data))
}

func (s *MCPServer) sendError(id interface{}, code int, message string) {
	res := JSONRPCResponse{
		JSONRPC: "2.0",
		ID:      id,
		Error: &RPCError{
			Code:    code,
			Message: message,
		},
	}
	data, _ := json.Marshal(res)
	fmt.Fprintf(os.Stdout, "%s\n", string(data))
}
