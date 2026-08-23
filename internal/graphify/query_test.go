package graphify

import (
	"errors"
	"path/filepath"
	"strings"
	"testing"

	"github.com/callmeradical/sergeant/internal/config"
)

func buildFixtureGraph(t *testing.T) *config.Graphify {
	t.Helper()
	repo := newTestRepo(t, "svc", "lib.py", "def add(a, b):\n    return a + b\n")
	output := filepath.Join(t.TempDir(), "published")
	proj := &config.Project{
		Name:     "query-fixture",
		Repos:    map[string]config.Repo{"svc": {Path: repo}},
		Graphify: &config.Graphify{Output: output},
	}
	if err := BuildProjectGraph(proj); err != nil {
		t.Fatalf("BuildProjectGraph: %v", err)
	}
	return proj.Graphify
}

// --- Scenario: Querying a built graph returns an answer ---

func TestQueryAgainstABuiltGraphReturnsAnAnswer(t *testing.T) {
	g := buildFixtureGraph(t)
	out, err := Query(g, "add()")
	if err != nil {
		t.Fatalf("Query: %v", err)
	}
	if !strings.Contains(out, "add()") {
		t.Errorf("Query output = %q, want it to mention add()", out)
	}
}

// --- Scenario: Explain and affected are distinct operations from query ---

func TestExplainAndAffectedAreDistinctFromQuery(t *testing.T) {
	g := buildFixtureGraph(t)

	explainOut, err := Explain(g, "add()")
	if err != nil {
		t.Fatalf("Explain: %v", err)
	}
	if !strings.HasPrefix(strings.TrimSpace(explainOut), "Node:") {
		t.Errorf("Explain output = %q, want it to start with 'Node:' (graphify explain's own format)", explainOut)
	}

	affectedOut, err := Affected(g, "add()")
	if err != nil {
		t.Fatalf("Affected: %v", err)
	}
	if !strings.Contains(affectedOut, "Affected nodes for add()") {
		t.Errorf("Affected output = %q, want it to mention 'Affected nodes for add()' (graphify affected's own format)", affectedOut)
	}

	queryOut, err := Query(g, "add()")
	if err != nil {
		t.Fatalf("Query: %v", err)
	}

	if explainOut == affectedOut || explainOut == queryOut || affectedOut == queryOut {
		t.Error("expected query, explain, and affected to each produce their own distinct output")
	}
}

// --- Scenario: Querying a project with no graph built yet is a clear error ---

func TestQueryWithNoGraphBuiltIsAClearError(t *testing.T) {
	g := &config.Graphify{Output: filepath.Join(t.TempDir(), "never-built")}

	var invocations int
	orig := runCommand
	runCommand = func(name string, args ...string) ([]byte, error) {
		invocations++
		return orig(name, args...)
	}
	defer func() { runCommand = orig }()

	if _, err := Query(g, "anything"); !errors.Is(err, ErrNoGraph) {
		t.Errorf("Query error = %v, want ErrNoGraph", err)
	}
	if _, err := Explain(g, "anything"); !errors.Is(err, ErrNoGraph) {
		t.Errorf("Explain error = %v, want ErrNoGraph", err)
	}
	if _, err := Affected(g, "anything"); !errors.Is(err, ErrNoGraph) {
		t.Errorf("Affected error = %v, want ErrNoGraph", err)
	}
	if invocations != 0 {
		t.Errorf("expected no graphify subprocess to be spawned for a missing graph, got %d invocations", invocations)
	}
}
