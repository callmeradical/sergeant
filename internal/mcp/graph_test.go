package mcp

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/callmeradical/sergeant/internal/config"
	"github.com/callmeradical/sergeant/internal/graphify"
)

// writeGraphProject writes a project YAML at an absolute path (so
// config.LoadProject uses it directly, bypassing SERGEANT_CONFIG) declaring
// a graphify block whose output points at outputDir.
func writeGraphProject(t *testing.T, name, repoPath, outputDir string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name+".yaml")
	yaml := "project: " + name + "\n" +
		"repos:\n" +
		"  svc:\n" +
		"    path: " + repoPath + "\n" +
		"graphify:\n" +
		"  output: " + outputDir + "\n"
	if err := os.WriteFile(path, []byte(yaml), 0644); err != nil {
		t.Fatal(err)
	}
	return path
}

func gitRepoWithOneFile(t *testing.T) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "repo")
	if err := os.MkdirAll(dir, 0755); err != nil {
		t.Fatal(err)
	}
	run := func(args ...string) {
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	run("init", "-q")
	run("config", "user.email", "test@example.com")
	run("config", "user.name", "test")
	if err := os.WriteFile(filepath.Join(dir, "lib.py"), []byte("def add(a, b):\n    return a + b\n"), 0644); err != nil {
		t.Fatal(err)
	}
	run("add", "-A")
	run("commit", "-q", "-m", "init")
	return dir
}

// The three graph tools are advertised, so a client can discover them
// without them being implemented-but-unreachable.
func TestGraphToolsAreAdvertised(t *testing.T) {
	names := map[string]bool{}
	for _, tool := range Tools() {
		names[tool.Name] = true
	}
	for _, want := range []string{"sergeant_graph_query", "sergeant_graph_explain", "sergeant_graph_affected"} {
		if !names[want] {
			t.Errorf("expected %s to be advertised in Tools()", want)
		}
	}
}

// --- Scenario: Querying a built graph returns an answer (MCP layer) ---

func TestMCPGraphQueryAgainstABuiltGraphReturnsAnswer(t *testing.T) {
	s, _ := mcpFixture(t)

	repo := gitRepoWithOneFile(t)
	output := filepath.Join(t.TempDir(), "published")
	projPath := writeGraphProject(t, "graph-built", repo, output)

	proj, err := config.LoadProject(projPath)
	if err != nil {
		t.Fatalf("LoadProject: %v", err)
	}
	if err := graphify.BuildProjectGraph(proj); err != nil {
		t.Fatalf("BuildProjectGraph: %v", err)
	}

	out, err := s.executeTool("sergeant_graph_query", map[string]interface{}{
		"project":  projPath,
		"question": "add()",
	})
	if err != nil {
		t.Fatalf("sergeant_graph_query returned an error: %v", err)
	}
	if !strings.Contains(out, "add()") {
		t.Errorf("query output = %q, want it to mention add()", out)
	}

	explainOut, err := s.executeTool("sergeant_graph_explain", map[string]interface{}{
		"project": projPath,
		"node":    "add()",
	})
	if err != nil {
		t.Fatalf("sergeant_graph_explain returned an error: %v", err)
	}
	if !strings.HasPrefix(strings.TrimSpace(explainOut), "Node:") {
		t.Errorf("explain output = %q, want graphify explain's own format", explainOut)
	}

	affectedOut, err := s.executeTool("sergeant_graph_affected", map[string]interface{}{
		"project": projPath,
		"node":    "add()",
	})
	if err != nil {
		t.Fatalf("sergeant_graph_affected returned an error: %v", err)
	}
	if !strings.Contains(affectedOut, "Affected nodes for add()") {
		t.Errorf("affected output = %q, want graphify affected's own format", affectedOut)
	}
}

// --- Scenario: Querying a project with no graph built yet is a clear error ---

func TestMCPGraphToolsWithNoGraphBuiltReturnClearError(t *testing.T) {
	s, _ := mcpFixture(t)

	repo := gitRepoWithOneFile(t)
	output := filepath.Join(t.TempDir(), "never-built")
	projPath := writeGraphProject(t, "graph-missing", repo, output)

	for _, tc := range []struct {
		tool string
		args map[string]interface{}
	}{
		{"sergeant_graph_query", map[string]interface{}{"project": projPath, "question": "x"}},
		{"sergeant_graph_explain", map[string]interface{}{"project": projPath, "node": "x"}},
		{"sergeant_graph_affected", map[string]interface{}{"project": projPath, "node": "x"}},
	} {
		_, err := s.executeTool(tc.tool, tc.args)
		if err == nil {
			t.Errorf("%s: expected an error for a project with no graph built, got none", tc.tool)
			continue
		}
		if !strings.Contains(err.Error(), "no graph built") {
			t.Errorf("%s: error = %q, want it to say no graph has been built", tc.tool, err.Error())
		}
	}

	// The output directory must never have been created by these calls —
	// they must not shell out to graphify for a missing graph file.
	if _, err := os.Stat(output); !os.IsNotExist(err) {
		t.Errorf("expected %s to remain absent, err=%v", output, err)
	}
}
