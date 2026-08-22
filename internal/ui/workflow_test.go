package ui

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/callmeradical/sergeant/internal/config"
	"github.com/callmeradical/sergeant/internal/dag"
	"github.com/callmeradical/sergeant/internal/store"
)

// workflowFixture points SERGEANT_CONFIG at a temp dir holding one project file
// and returns a handler. The config is written per-test so a test can prove the
// graph follows the file rather than the code.
func workflowFixture(t *testing.T, projectFile, projectYAML string) http.Handler {
	t.Helper()

	base := t.TempDir()
	cfgDir := filepath.Join(base, "config")
	if err := os.MkdirAll(cfgDir, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SERGEANT_CONFIG", cfgDir)

	if err := os.WriteFile(filepath.Join(cfgDir, projectFile), []byte(projectYAML), 0o644); err != nil {
		t.Fatal(err)
	}

	st, err := store.Open(filepath.Join(base, "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	return NewServer(st, 0).Handler()
}

func getWorkflow(t *testing.T, mux http.Handler, query string) (*httptest.ResponseRecorder, WorkflowGraph) {
	t.Helper()
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest("GET", "/api/workflow?"+query, nil))

	var graph WorkflowGraph
	if w.Code == http.StatusOK {
		if err := json.Unmarshal(w.Body.Bytes(), &graph); err != nil {
			t.Fatalf("response is not a workflow graph: %v\n%s", err, w.Body.String())
		}
	}
	return w, graph
}

// labelsOf renders the graph as "kind:label" strings so an assertion can state
// the whole expected sequence in one literal.
func labelsOf(nodes []WorkflowNode) []string {
	out := make([]string, 0, len(nodes))
	for _, n := range nodes {
		out = append(out, n.Kind+":"+n.Label)
	}
	return out
}

func labelsOfKind(nodes []WorkflowNode, kind string) []string {
	var out []string
	for _, n := range nodes {
		if n.Kind == kind {
			out = append(out, n.Label)
		}
	}
	return out
}

// assertConnectedChain checks the edges form exactly one path visiting every
// node once, in node order. A graph with a missing edge renders as disconnected
// islands, which is worse than no graph: it implies steps that never run.
func assertConnectedChain(t *testing.T, graph WorkflowGraph) {
	t.Helper()

	if len(graph.Edges) != len(graph.Nodes)-1 {
		t.Fatalf("got %d edges for %d nodes, want exactly %d for a single chain",
			len(graph.Edges), len(graph.Nodes), len(graph.Nodes)-1)
	}
	for i, e := range graph.Edges {
		if e.From != graph.Nodes[i].ID {
			t.Errorf("edge %d from = %q, want %q", i, e.From, graph.Nodes[i].ID)
		}
		if e.To != graph.Nodes[i+1].ID {
			t.Errorf("edge %d to = %q, want %q", i, e.To, graph.Nodes[i+1].ID)
		}
	}

	seen := map[string]bool{}
	for _, n := range graph.Nodes {
		if n.ID == "" {
			t.Errorf("node %+v has no id; the client cannot address it", n)
		}
		if seen[n.ID] {
			t.Errorf("duplicate node id %q: two steps would collapse into one", n.ID)
		}
		seen[n.ID] = true
	}
}

// The whole point of serving the definition: every declared stage and gate is a
// node before anything has run, and they form one connected left-to-right chain.
func TestWorkflowGraphReturnsDeclaredPipelineGatesAndLifecycle(t *testing.T) {
	mux := workflowFixture(t, "graph.yaml", `
name: graph
repos:
  - name: svc
    path: /tmp/svc
    factory:
      pipeline: ["plan", "build", "test", "review"]
      gates:
        unit-tests: "go test ./..."
        lint: "golangci-lint run"
`)

	w, graph := getWorkflow(t, mux, "project=graph&repo=svc")
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", w.Code, w.Body.String())
	}

	if graph.Project != "graph" || graph.Repo != "svc" {
		t.Errorf("graph identifies project %q repo %q, want graph/svc", graph.Project, graph.Repo)
	}

	want := []string{
		"stage:plan", "stage:build", "stage:test", "stage:review",
		"gate:lint", "gate:unit-tests",
		"lifecycle:pending", "lifecycle:red", "lifecycle:green",
		"lifecycle:sealed", "lifecycle:merged",
	}
	if got := labelsOf(graph.Nodes); !equalStrings(got, want) {
		t.Errorf("nodes =\n  %v\nwant\n  %v", got, want)
	}

	for _, n := range graph.Nodes {
		if n.Group != "svc" {
			t.Errorf("node %q group = %q, want svc", n.ID, n.Group)
		}
	}

	assertConnectedChain(t, graph)
}

// A repo with no factory block still has a workflow — the engine's default — and
// an operator must be able to see it. The expected list is read from
// dag.DefaultPipeline so this test cannot drift from the engine either.
func TestWorkflowGraphUsesTheEngineDefaultPipelineWhenNoFactoryIsConfigured(t *testing.T) {
	mux := workflowFixture(t, "bare.yaml", `
name: bare
repos:
  - name: svc
    path: /tmp/svc
`)

	w, graph := getWorkflow(t, mux, "project=bare&repo=svc")
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", w.Code, w.Body.String())
	}

	want := dag.DefaultPipeline()
	if got := labelsOfKind(graph.Nodes, NodeKindStage); !equalStrings(got, want) {
		t.Errorf("stage nodes = %v, want the engine default %v", got, want)
	}
	if want[0] != "plan" || want[len(want)-1] != "test" {
		t.Errorf("dag.DefaultPipeline() = %v, which no longer matches the documented plan/build/test default", want)
	}

	if got := labelsOfKind(graph.Nodes, NodeKindGate); len(got) != 0 {
		t.Errorf("gate nodes = %v, want none for a repo that configures no gates", got)
	}
	if got := labelsOfKind(graph.Nodes, NodeKindLifecycle); !equalStrings(got, store.BulletProgression()) {
		t.Errorf("lifecycle nodes = %v, want %v", got, store.BulletProgression())
	}

	assertConnectedChain(t, graph)
}

// Gate order in the graph is a claim about what runs first. The engine runs gates
// in sorted name order, so a graph that orders them any other way misinforms the
// operator. The expectation is taken from dag.SortedGateNames, the function the
// engine itself calls.
func TestWorkflowGraphGateOrderMatchesTheEngineExecutionOrder(t *testing.T) {
	mux := workflowFixture(t, "gates.yaml", `
name: gates
repos:
  - name: svc
    path: /tmp/svc
    factory:
      gates:
        zebra: "echo z"
        alpha: "echo a"
        Middle: "echo M"
        middle: "echo m"
        10-first: "echo 10"
`)

	w, graph := getWorkflow(t, mux, "project=gates&repo=svc")
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", w.Code, w.Body.String())
	}

	proj := loadFixtureProject(t, "gates")
	want := dag.SortedGateNames(proj.Repos["svc"])
	if len(want) != 5 {
		t.Fatalf("fixture lost gates: %v", want)
	}
	if got := labelsOfKind(graph.Nodes, NodeKindGate); !equalStrings(got, want) {
		t.Errorf("gate nodes = %v, want the engine's execution order %v", got, want)
	}

	// Stated independently of the helper, so a change to the engine's ordering
	// cannot make both sides agree on something wrong.
	explicit := []string{"10-first", "Middle", "alpha", "middle", "zebra"}
	if got := labelsOfKind(graph.Nodes, NodeKindGate); !equalStrings(got, explicit) {
		t.Errorf("gate nodes = %v, want byte-sorted %v", got, explicit)
	}
}

// The requirement that nothing is hardcoded, asserted the only way it can be:
// change the config, not the code, and the graph must change.
func TestWorkflowGraphFollowsProjectConfigWithNoCodeChange(t *testing.T) {
	base := t.TempDir()
	cfgDir := filepath.Join(base, "config")
	if err := os.MkdirAll(cfgDir, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SERGEANT_CONFIG", cfgDir)
	cfgPath := filepath.Join(cfgDir, "evolving.yaml")

	st, err := store.Open(filepath.Join(base, "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	mux := NewServer(st, 0).Handler()

	writeConfig := func(yaml string) {
		if err := os.WriteFile(cfgPath, []byte(yaml), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	writeConfig(`
name: evolving
repos:
  - name: svc
    path: /tmp/svc
    factory:
      pipeline: ["plan", "build"]
      gates:
        unit-tests: "go test ./..."
`)
	w, before := getWorkflow(t, mux, "project=evolving&repo=svc")
	if w.Code != http.StatusOK {
		t.Fatalf("first call: status %d, body=%s", w.Code, w.Body.String())
	}

	// Same binary, same handler, only the YAML differs: one gate added, one
	// pipeline entry added.
	writeConfig(`
name: evolving
repos:
  - name: svc
    path: /tmp/svc
    factory:
      pipeline: ["plan", "build", "harden"]
      gates:
        unit-tests: "go test ./..."
        audit: "govulncheck ./..."
`)
	w, after := getWorkflow(t, mux, "project=evolving&repo=svc")
	if w.Code != http.StatusOK {
		t.Fatalf("second call: status %d, body=%s", w.Code, w.Body.String())
	}

	if got, want := labelsOfKind(before.Nodes, NodeKindStage), []string{"plan", "build"}; !equalStrings(got, want) {
		t.Errorf("stages before = %v, want %v", got, want)
	}
	if got, want := labelsOfKind(after.Nodes, NodeKindStage), []string{"plan", "build", "harden"}; !equalStrings(got, want) {
		t.Errorf("stages after = %v, want %v", got, want)
	}

	if got, want := labelsOfKind(before.Nodes, NodeKindGate), []string{"unit-tests"}; !equalStrings(got, want) {
		t.Errorf("gates before = %v, want %v", got, want)
	}
	if got, want := labelsOfKind(after.Nodes, NodeKindGate), []string{"audit", "unit-tests"}; !equalStrings(got, want) {
		t.Errorf("gates after = %v, want %v", got, want)
	}

	if len(after.Nodes) != len(before.Nodes)+2 {
		t.Errorf("node count went %d -> %d, want +2", len(before.Nodes), len(after.Nodes))
	}

	// Ids of steps that did not change must not move, or the client's progress
	// overlay would detach on every config edit.
	if before.Nodes[0].ID != after.Nodes[0].ID {
		t.Errorf("first node id changed from %q to %q", before.Nodes[0].ID, after.Nodes[0].ID)
	}

	assertConnectedChain(t, before)
	assertConnectedChain(t, after)
}

// An unknown project or repo is refused, and the message names what was missing.
// Answering with an empty graph would read as "this repo has no workflow".
func TestWorkflowGraphRejectsUnknownProjectAndRepo(t *testing.T) {
	mux := workflowFixture(t, "known.yaml", `
name: known
repos:
  - name: svc
    path: /tmp/svc
  - name: web
    path: /tmp/web
`)

	cases := []struct {
		name     string
		query    string
		contains []string
	}{
		{"unknown project", "project=ghost&repo=svc", []string{"ghost", "not found"}},
		{"unknown repo", "project=known&repo=ghost-repo", []string{"ghost-repo", "known", "svc", "web"}},
		{"missing project", "repo=svc", []string{"project"}},
		{"missing repo", "project=known", []string{"repo", "svc", "web"}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			w, _ := getWorkflow(t, mux, tc.query)
			if w.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, want 400; body=%s", w.Code, w.Body.String())
			}
			for _, want := range tc.contains {
				if !strings.Contains(w.Body.String(), want) {
					t.Errorf("error does not mention %q: %s", want, w.Body.String())
				}
			}
		})
	}
}

// loadFixtureProject reads back the project the fixture wrote, so a test can
// derive its expectation from the same config the handler saw.
func loadFixtureProject(t *testing.T, name string) *config.Project {
	t.Helper()
	proj, err := config.LoadProject(name)
	if err != nil {
		t.Fatalf("loading fixture project %q: %v", name, err)
	}
	return proj
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
