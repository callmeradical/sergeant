package graphify

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/callmeradical/sergeant/internal/config"
)

// writeGraphFixture writes raw (a hand-authored graph.json body) to a fresh
// file in t.TempDir() and returns its path.
func writeGraphFixture(t *testing.T, raw string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "graph.json")
	if err := os.WriteFile(path, []byte(raw), 0644); err != nil {
		t.Fatalf("writing graph fixture: %v", err)
	}
	return path
}

// readGraphFixture parses the graph.json at path into the shape the tests
// need to make assertions against: node ids, and the raw source/target/
// nodes ids each link/hyperedge still carries.
type fixtureNode struct {
	ID         string `json:"id"`
	SourceFile string `json:"source_file"`
}
type fixtureLink struct {
	Source     string `json:"source"`
	Target     string `json:"target"`
	SourceFile string `json:"source_file"`
}
type fixtureHyperedge struct {
	Nodes      []string `json:"nodes"`
	SourceFile string   `json:"source_file"`
}
type fixtureGraph struct {
	Nodes      []fixtureNode      `json:"nodes"`
	Links      []fixtureLink      `json:"links"`
	Hyperedges []fixtureHyperedge `json:"hyperedges"`
}

func readGraphFixture(t *testing.T, path string) fixtureGraph {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading filtered graph: %v", err)
	}
	var g fixtureGraph
	if err := json.Unmarshal(data, &g); err != nil {
		t.Fatalf("parsing filtered graph: %v", err)
	}
	return g
}

func nodeIDs(nodes []fixtureNode) []string {
	ids := make([]string, len(nodes))
	for i, n := range nodes {
		ids[i] = n.ID
	}
	return ids
}

func containsID(ids []string, id string) bool {
	for _, v := range ids {
		if v == id {
			return true
		}
	}
	return false
}

// --- Scenario: A node from an excluded file is removed ---

func TestExcludedFileNodeIsRemoved(t *testing.T) {
	path := writeGraphFixture(t, `{
		"nodes": [
			{"id": "n1", "source_file": "keep.go"},
			{"id": "n2", "source_file": "drop.go"}
		],
		"links": [],
		"hyperedges": []
	}`)

	if err := filterGraphFile(path, []string{"drop.go"}); err != nil {
		t.Fatalf("filterGraphFile: %v", err)
	}

	g := readGraphFixture(t, path)
	ids := nodeIDs(g.Nodes)
	if len(ids) != 1 || !containsID(ids, "n1") {
		t.Errorf("nodes = %v, want only n1 (n2 came from an excluded file)", ids)
	}
}

// --- Scenario: An edge from an excluded file is removed ---

func TestExcludedFileLinkAndHyperedgeAreRemoved(t *testing.T) {
	path := writeGraphFixture(t, `{
		"nodes": [
			{"id": "n1", "source_file": "keep.go"},
			{"id": "n2", "source_file": "keep.go"}
		],
		"links": [
			{"source": "n1", "target": "n2", "source_file": "drop.go"}
		],
		"hyperedges": [
			{"id": "h1", "nodes": ["n1", "n2"], "source_file": "drop.go"}
		]
	}`)

	if err := filterGraphFile(path, []string{"drop.go"}); err != nil {
		t.Fatalf("filterGraphFile: %v", err)
	}

	g := readGraphFixture(t, path)
	if len(g.Nodes) != 2 {
		t.Errorf("nodes = %v, want both n1 and n2 to survive (neither came from drop.go)", g.Nodes)
	}
	if len(g.Links) != 0 {
		t.Errorf("links = %v, want empty (the only link's own source_file matched an exclude pattern)", g.Links)
	}
	if len(g.Hyperedges) != 0 {
		t.Errorf("hyperedges = %v, want empty (the only hyperedge's own source_file matched an exclude pattern)", g.Hyperedges)
	}
}

// --- Scenario: A dangling reference left by an excluded node is also removed ---

func TestDanglingLinkAndHyperedgeAfterNodeExclusionAreRemoved(t *testing.T) {
	path := writeGraphFixture(t, `{
		"nodes": [
			{"id": "n1", "source_file": "keep.go"},
			{"id": "n2", "source_file": "drop.go"}
		],
		"links": [
			{"source": "n1", "target": "n2", "source_file": "keep.go"}
		],
		"hyperedges": [
			{"id": "h1", "nodes": ["n1", "n2"], "source_file": "keep.go"}
		]
	}`)

	if err := filterGraphFile(path, []string{"drop.go"}); err != nil {
		t.Fatalf("filterGraphFile: %v", err)
	}

	g := readGraphFixture(t, path)
	ids := nodeIDs(g.Nodes)
	if len(ids) != 1 || !containsID(ids, "n1") {
		t.Errorf("nodes = %v, want only n1", ids)
	}
	if len(g.Links) != 0 {
		t.Errorf("links = %v, want empty — the link's own source_file (keep.go) didn't match, but its target node (n2) was excluded, leaving it dangling", g.Links)
	}
	if len(g.Hyperedges) != 0 {
		t.Errorf("hyperedges = %v, want empty — only n1 survives as an endpoint, fewer than the 2 required", g.Hyperedges)
	}
}

// --- Scenario: A directory-recursive pattern excludes its whole contents ---

func TestRecursivePatternExcludesEntireDirectory(t *testing.T) {
	path := writeGraphFixture(t, `{
		"nodes": [
			{"id": "n1", "source_file": "src/a.go"},
			{"id": "n2", "source_file": "vendor/lib.go"},
			{"id": "n3", "source_file": "vendor/nested/deep/file.go"}
		],
		"links": [],
		"hyperedges": []
	}`)

	if err := filterGraphFile(path, []string{"vendor/**"}); err != nil {
		t.Fatalf("filterGraphFile: %v", err)
	}

	g := readGraphFixture(t, path)
	ids := nodeIDs(g.Nodes)
	if len(ids) != 1 || !containsID(ids, "n1") {
		t.Errorf("nodes = %v, want only n1 — vendor/** must exclude both a direct child (vendor/lib.go) and a deeply nested file (vendor/nested/deep/file.go)", ids)
	}
}

// --- Scenario: No exclude patterns configured produces the same graph as before this change ---

func TestEmptyExcludePatternsIsStructuralNoOp(t *testing.T) {
	raw := `{
		"directed": true,
		"multigraph": false,
		"graph": {"label": "example"},
		"built_at_commit": "abc123",
		"nodes": [
			{"id": "n1", "source_file": "a.go", "extra_field": "x"},
			{"id": "n2", "source_file": "b.go", "extra_field": "y"}
		],
		"links": [
			{"source": "n1", "target": "n2", "source_file": "a.go", "weight": 1.0}
		],
		"hyperedges": [
			{"id": "h1", "nodes": ["n1", "n2"], "source_file": "a.go", "relation": "participate_in"}
		]
	}`
	path := writeGraphFixture(t, raw)

	var before interface{}
	if err := json.Unmarshal([]byte(raw), &before); err != nil {
		t.Fatalf("parsing fixture: %v", err)
	}

	for _, patterns := range [][]string{nil, {}} {
		if err := filterGraphFile(path, patterns); err != nil {
			t.Fatalf("filterGraphFile(patterns=%v): %v", patterns, err)
		}

		after := readRawGraph(t, path)
		if !reflect.DeepEqual(before, after) {
			t.Errorf("patterns=%v: filtered graph structurally differs from the unfiltered input.\nbefore: %#v\nafter:  %#v", patterns, before, after)
		}
	}
}

func readRawGraph(t *testing.T, path string) interface{} {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading graph: %v", err)
	}
	var v interface{}
	if err := json.Unmarshal(data, &v); err != nil {
		t.Fatalf("parsing graph: %v", err)
	}
	return v
}

// --- Scenario: BuildProjectGraph actually applies proj.Graphify.ExcludePatterns ---

func TestBuildProjectGraphAppliesExcludePatterns(t *testing.T) {
	repo := newTestRepo(t, "svc", "main.go", "package main\nfunc main() {}\n")
	// Add a second file so the repo has something to exclude and something
	// to keep.
	if err := os.WriteFile(filepath.Join(repo, "vendored.go"), []byte("package main\nfunc Vendored() {}\n"), 0644); err != nil {
		t.Fatalf("writing second file: %v", err)
	}
	run := func(args ...string) {
		cmd := exec.Command("git", args...)
		cmd.Dir = repo
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	run("add", "-A")
	run("commit", "-q", "-m", "add vendored file")

	output := filepath.Join(t.TempDir(), "published")
	proj := &config.Project{
		Name:  "excluding",
		Repos: map[string]config.Repo{"svc": {Path: repo}},
		Graphify: &config.Graphify{
			Output:          output,
			ExcludePatterns: []string{"vendored.go"},
		},
	}

	if err := BuildProjectGraph(proj); err != nil {
		t.Fatalf("BuildProjectGraph: %v", err)
	}

	files := mergedGraphSourceFiles(t, filepath.Join(output, "graph.json"))
	for _, f := range files {
		if f == "vendored.go" {
			t.Errorf("source files = %v, want no vendored.go (excluded by exclude_patterns)", files)
		}
	}
}
