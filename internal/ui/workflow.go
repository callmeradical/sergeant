package ui

import (
	"fmt"
	"net/http"
	"sort"
	"strings"

	"github.com/callmeradical/sergeant/internal/config"
	"github.com/callmeradical/sergeant/internal/dag"
	"github.com/callmeradical/sergeant/internal/store"
)

// The workflow graph is served from the project *definition*, not from phase
// records.
//
// The stage matrix derives its columns from phases that have already been
// written, so it can only ever show history: a stage that has not started yet is
// invisible, and an operator cannot see what the run is going to do. A run view
// worth checking instead of reading logs has to show the whole planned path with
// progress marked on it, the way a CI provider renders a workflow.
//
// So this endpoint answers "what will run", derived entirely from configuration.
// "What did run" stays where it is, in the phase records. The two are joined in
// the client by node id.

// Node kinds. The client styles by kind, so these strings are part of the
// endpoint's contract.
const (
	// NodeKindStage is one entry of a repo's factory.pipeline.
	NodeKindStage = "stage"
	// NodeKindGate is one entry of a repo's factory.gates.
	NodeKindGate = "gate"
	// NodeKindLifecycle is one bullet status from store.BulletStatuses.
	NodeKindLifecycle = "lifecycle"
)

// WorkflowNode is one step an operator can see before it has started.
//
// Group is the repository the node belongs to. Every node in this response
// carries the same group; the field exists so a future cross-repo graph
// (td-c66393) can concatenate per-repo graphs without changing this shape.
type WorkflowNode struct {
	ID    string `json:"id"`
	Label string `json:"label"`
	Kind  string `json:"kind"`
	Group string `json:"group"`
}

// WorkflowEdge is a directed dependency: To runs after From.
type WorkflowEdge struct {
	From string `json:"from"`
	To   string `json:"to"`
}

// WorkflowGraph is the left-to-right dependency graph for one repository.
type WorkflowGraph struct {
	Project string         `json:"project"`
	Repo    string         `json:"repo"`
	Nodes   []WorkflowNode `json:"nodes"`
	Edges   []WorkflowEdge `json:"edges"`
}

// chain accumulates a single connected path, wiring each appended node to the
// one before it. Building nodes and edges together is what makes an orphaned
// node impossible to produce by accident.
type chain struct {
	group string
	nodes []WorkflowNode
	edges []WorkflowEdge
	used  map[string]bool
}

func newChain(group string) *chain {
	return &chain{group: group, used: map[string]bool{}}
}

// add appends one node to the tail of the chain.
//
// Ids are derived from group, kind and label so they are stable across requests
// and can be matched against phase records by the client. A repo may legally
// list the same pipeline entry twice, and a pipeline entry may share its name
// with a gate; the kind prefix separates the second case and the numeric suffix
// separates the first, because two nodes sharing an id would silently collapse
// into one in the rendered graph.
func (c *chain) add(kind, label string) {
	id := c.group + ":" + kind + ":" + label
	if c.used[id] {
		for n := 2; ; n++ {
			candidate := fmt.Sprintf("%s#%d", id, n)
			if !c.used[candidate] {
				id = candidate
				break
			}
		}
	}
	c.used[id] = true

	if len(c.nodes) > 0 {
		c.edges = append(c.edges, WorkflowEdge{From: c.nodes[len(c.nodes)-1].ID, To: id})
	}
	c.nodes = append(c.nodes, WorkflowNode{ID: id, Label: label, Kind: kind, Group: c.group})
}

// buildWorkflowGraph derives a repo's graph from its configuration.
//
// Ordering is not this function's decision to make:
//   - stages come from dag.PipelineFor, which is the same resolution the engine
//     performs, including the default pipeline for a repo with no factory block;
//   - gates come from dag.SortedGateNames, which is the exact order the engine
//     executes them in;
//   - the lifecycle tail comes from store.BulletStatuses.
//
// Nothing here hardcodes a stage, gate or status name. Adding a gate to the
// project YAML changes this graph with no code change.
//
// The gates are emitted after the pipeline rather than nested inside its "test"
// entry, which is where the engine actually runs them. That is a deliberate
// simplification of a flat chain: the execution order the graph shows is
// correct, but it does not express containment.
func buildWorkflowGraph(projectName, repoName string, repoCfg config.Repo) WorkflowGraph {
	c := newChain(repoName)

	for _, stage := range dag.PipelineFor(repoCfg) {
		c.add(NodeKindStage, stage)
	}
	for _, gate := range dag.SortedGateNames(repoCfg) {
		c.add(NodeKindGate, gate)
	}
	for _, status := range store.BulletStatuses() {
		c.add(NodeKindLifecycle, status)
	}

	// Never nil: the client iterates these, and a JSON null would make an empty
	// graph indistinguishable from a broken response.
	if c.nodes == nil {
		c.nodes = []WorkflowNode{}
	}
	if c.edges == nil {
		c.edges = []WorkflowEdge{}
	}

	return WorkflowGraph{
		Project: projectName,
		Repo:    repoName,
		Nodes:   c.nodes,
		Edges:   c.edges,
	}
}

// handleWorkflow serves GET /api/workflow?project=<name>&repo=<name>.
//
// A project or repo that does not exist is refused rather than answered with an
// empty graph, and the error names what was not found — an empty graph would
// read to the operator as "this repo has no workflow", which is a different and
// false statement.
func (srv *Server) handleWorkflow(w http.ResponseWriter, r *http.Request) {
	projectName := strings.TrimSpace(r.URL.Query().Get("project"))
	repoName := strings.TrimSpace(r.URL.Query().Get("repo"))

	if projectName == "" {
		http.Error(w, "missing project: /api/workflow requires ?project=<name>&repo=<name>", http.StatusBadRequest)
		return
	}

	proj, err := config.LoadProject(projectName)
	if err != nil {
		http.Error(w, fmt.Sprintf("project %q not found: %v", projectName, err), http.StatusBadRequest)
		return
	}

	if repoName == "" {
		http.Error(w, fmt.Sprintf("missing repo: /api/workflow requires ?repo=<name>; project %q configures %s",
			proj.Name, describeRepoSet(proj)), http.StatusBadRequest)
		return
	}

	repoCfg, ok := proj.Repos[repoName]
	if !ok {
		http.Error(w, fmt.Sprintf("repo %q not found in project %q, which configures %s",
			repoName, proj.Name, describeRepoSet(proj)), http.StatusBadRequest)
		return
	}

	writeJSON(w, http.StatusOK, buildWorkflowGraph(proj.Name, repoName, repoCfg))
}

// describeRepoSet lists a project's repos for an error message, sorted so the
// message is reproducible.
func describeRepoSet(proj *config.Project) string {
	if len(proj.Repos) == 0 {
		return "no repositories"
	}
	names := make([]string, 0, len(proj.Repos))
	for name := range proj.Repos {
		names = append(names, name)
	}
	sort.Strings(names)
	return "repositories: " + strings.Join(names, ", ")
}
