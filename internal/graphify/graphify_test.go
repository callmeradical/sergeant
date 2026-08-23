package graphify

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"sync"
	"testing"

	"github.com/callmeradical/sergeant/internal/config"
)

// newTestRepo creates a minimal git repository containing one trivial file
// so graphify extract completes quickly regardless of which mode it runs in
// without an LLM key configured.
func newTestRepo(t *testing.T, name, fileName, contents string) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), name)
	if err := os.MkdirAll(dir, 0755); err != nil {
		t.Fatalf("mkdir repo dir: %v", err)
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
	if err := os.WriteFile(filepath.Join(dir, fileName), []byte(contents), 0644); err != nil {
		t.Fatalf("write file: %v", err)
	}
	run("add", "-A")
	run("commit", "-q", "-m", "init")
	return dir
}

// mergedGraphSourceFiles parses the graph.json at path and returns the
// distinct set of "source_file" values its nodes carry. graphify merge-graphs
// additionally tags nodes with a "repo" field when merging two or more
// graphs, but a single-repo build publishes that repo's raw extraction
// unchanged (merge-graphs requires at least two inputs), so source_file is
// the property present in both shapes and safe to assert on either way.
func mergedGraphSourceFiles(t *testing.T, path string) []string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading merged graph: %v", err)
	}
	var doc struct {
		Nodes []struct {
			SourceFile string `json:"source_file"`
		} `json:"nodes"`
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatalf("parsing merged graph: %v", err)
	}
	seen := map[string]bool{}
	var files []string
	for _, n := range doc.Nodes {
		if n.SourceFile != "" && !seen[n.SourceFile] {
			seen[n.SourceFile] = true
			files = append(files, n.SourceFile)
		}
	}
	sort.Strings(files)
	return files
}

// --- Scenario: Building a project's graph merges every participating repo ---

func TestBuildProjectGraphMergesEveryParticipatingRepo(t *testing.T) {
	backend := newTestRepo(t, "backend", "main.go", "package main\nfunc main() {}\n")
	frontend := newTestRepo(t, "frontend", "lib.py", "def add(a, b):\n    return a + b\n")

	output := filepath.Join(t.TempDir(), "published")
	proj := &config.Project{
		Name: "multi-repo",
		Repos: map[string]config.Repo{
			"backend":  {Path: backend},
			"frontend": {Path: frontend},
		},
		Graphify: &config.Graphify{Output: output},
	}

	if err := BuildProjectGraph(proj); err != nil {
		t.Fatalf("BuildProjectGraph: %v", err)
	}

	graphPath := filepath.Join(output, "graph.json")
	if info, err := os.Stat(graphPath); err != nil || info.Size() == 0 {
		t.Fatalf("expected non-empty graph.json at %s, err=%v", graphPath, err)
	}

	files := mergedGraphSourceFiles(t, graphPath)
	if len(files) != 2 || files[0] != "lib.py" || files[1] != "main.go" {
		t.Errorf("merged graph source files = %v, want [lib.py main.go]", files)
	}

	manifestPath := filepath.Join(output, "manifest.json")
	manifestData, err := os.ReadFile(manifestPath)
	if err != nil {
		t.Fatalf("reading manifest: %v", err)
	}
	var manifest struct {
		Repos   []string `json:"repos"`
		BuiltAt string   `json:"built_at"`
	}
	if err := json.Unmarshal(manifestData, &manifest); err != nil {
		t.Fatalf("parsing manifest: %v", err)
	}
	if manifest.BuiltAt == "" {
		t.Error("expected manifest.built_at to be set")
	}
	sort.Strings(manifest.Repos)
	if len(manifest.Repos) != 2 || manifest.Repos[0] != "backend" || manifest.Repos[1] != "frontend" {
		t.Errorf("manifest.repos = %v, want [backend frontend]", manifest.Repos)
	}
}

// --- Scenario: include_groups scopes which repos participate ---

func TestIncludeGroupsExcludesNonMatchingRepos(t *testing.T) {
	core := newTestRepo(t, "core-svc", "main.go", "package main\nfunc main() {}\n")
	other := newTestRepo(t, "other-svc", "other.go", "package other\nfunc Other() {}\n")

	output := filepath.Join(t.TempDir(), "published")
	proj := &config.Project{
		Name: "grouped",
		Repos: map[string]config.Repo{
			"core-svc":  {Path: core, Group: "core"},
			"other-svc": {Path: other, Group: "extra"},
		},
		Graphify: &config.Graphify{Output: output, IncludeGroups: []string{"core"}},
	}

	if err := BuildProjectGraph(proj); err != nil {
		t.Fatalf("BuildProjectGraph: %v", err)
	}

	files := mergedGraphSourceFiles(t, filepath.Join(output, "graph.json"))
	if len(files) != 1 || files[0] != "main.go" {
		t.Errorf("merged graph source files = %v, want [main.go] (other.go from the excluded repo must not appear)", files)
	}

	// The excluded repo's scratch directory must never have been created.
	if _, err := os.Stat(filepath.Join(output, "other-svc")); !os.IsNotExist(err) {
		t.Errorf("expected other-svc to be excluded from the build, found: err=%v", err)
	}
}

// --- Scenario: An empty project or a group matching nothing is an error ---

func TestZeroParticipatingReposIsBuildError(t *testing.T) {
	output := filepath.Join(t.TempDir(), "published")

	t.Run("no repos at all", func(t *testing.T) {
		proj := &config.Project{
			Name:     "empty",
			Repos:    map[string]config.Repo{},
			Graphify: &config.Graphify{Output: output},
		}

		// Record invocations so this test verifies the zero-repos guard
		// specifically, not merely that *some* error occurs. Without the
		// guard, BuildProjectGraph still errors (graphify merge-graphs
		// rejects zero inputs with its own usage error), which would let a
		// bare `err == nil` check pass even if this guard were deleted. The
		// guard's defining property is that it returns before making ANY
		// subprocess call.
		var invocations [][]string
		orig := runCommand
		runCommand = func(name string, args ...string) ([]byte, error) {
			invocations = append(invocations, append([]string{name}, args...))
			return orig(name, args...)
		}
		defer func() { runCommand = orig }()

		err := BuildProjectGraph(proj)
		if err == nil {
			t.Fatal("expected an error for zero participating repos, got nil")
		}
		if len(invocations) != 0 {
			t.Errorf("expected no graphify invocations for zero participating repos, got: %v", invocations)
		}
		if _, err := os.Stat(output); !os.IsNotExist(err) {
			t.Errorf("expected no output to be published, err=%v", err)
		}
	})

	t.Run("include_groups matches nothing", func(t *testing.T) {
		svc := newTestRepo(t, "svc", "main.go", "package main\nfunc main() {}\n")
		proj := &config.Project{
			Name: "no-match",
			Repos: map[string]config.Repo{
				"svc": {Path: svc, Group: "core"},
			},
			Graphify: &config.Graphify{Output: output, IncludeGroups: []string{"nonexistent"}},
		}

		var invocations [][]string
		orig := runCommand
		runCommand = func(name string, args ...string) ([]byte, error) {
			invocations = append(invocations, append([]string{name}, args...))
			return orig(name, args...)
		}
		defer func() { runCommand = orig }()

		if err := BuildProjectGraph(proj); err == nil {
			t.Fatal("expected an error when include_groups matches nothing, got nil")
		}
		if len(invocations) != 0 {
			t.Errorf("expected no graphify invocations when include_groups matches nothing, got: %v", invocations)
		}
	})
}

// --- Scenario: A reader never observes a partial graph ---

func TestBuildNeverLeavesOutputInAPartialState(t *testing.T) {
	repoA := newTestRepo(t, "svc", "main.go", "package main\nfunc main() {}\n")
	output := filepath.Join(t.TempDir(), "published")

	proj := &config.Project{
		Name:     "atomic",
		Repos:    map[string]config.Repo{"svc": {Path: repoA}},
		Graphify: &config.Graphify{Output: output},
	}

	// Seed a prior published graph so there is recognizable content a
	// concurrent reader could observe mid-rebuild.
	if err := BuildProjectGraph(proj); err != nil {
		t.Fatalf("seeding initial build: %v", err)
	}
	priorGraph, err := os.ReadFile(filepath.Join(output, "graph.json"))
	if err != nil {
		t.Fatalf("reading seeded graph: %v", err)
	}

	// Pause the second build right before it publishes so the test can
	// observe Output mid-flight.
	reachedPublish := make(chan struct{})
	releasePublish := make(chan struct{})
	publishHook = func() {
		close(reachedPublish)
		<-releasePublish
	}
	defer func() { publishHook = nil }()

	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		if err := BuildProjectGraph(proj); err != nil {
			t.Errorf("second BuildProjectGraph: %v", err)
		}
	}()

	<-reachedPublish
	midFlight, err := os.ReadFile(filepath.Join(output, "graph.json"))
	if err != nil {
		t.Fatalf("reading graph mid-flight: %v", err)
	}
	if string(midFlight) != string(priorGraph) {
		t.Error("Output changed before the rebuild published — a reader could observe a partial graph")
	}

	close(releasePublish)
	wg.Wait()

	if _, err := os.Stat(filepath.Join(output, "graph.json")); err != nil {
		t.Errorf("expected graph.json to exist after publish: %v", err)
	}
}

// --- Scenario: The build does not shell out to v1's sgt-graphify ---

func TestBuildNeverSpawnsSgtGraphify(t *testing.T) {
	repo := newTestRepo(t, "svc", "main.go", "package main\nfunc main() {}\n")
	output := filepath.Join(t.TempDir(), "published")
	proj := &config.Project{
		Name:     "no-v1",
		Repos:    map[string]config.Repo{"svc": {Path: repo}},
		Graphify: &config.Graphify{Output: output},
	}

	var invocations [][]string
	orig := runCommand
	runCommand = func(name string, args ...string) ([]byte, error) {
		call := append([]string{name}, args...)
		invocations = append(invocations, call)
		return orig(name, args...)
	}
	defer func() { runCommand = orig }()

	if err := BuildProjectGraph(proj); err != nil {
		t.Fatalf("BuildProjectGraph: %v", err)
	}

	if len(invocations) == 0 {
		t.Fatal("expected at least one recorded invocation")
	}
	for _, call := range invocations {
		if call[0] == "sgt-graphify" {
			t.Fatalf("BuildProjectGraph spawned sgt-graphify: %v", call)
		}
		if call[0] != "graphify" {
			t.Fatalf("unexpected command binary %q in invocation %v", call[0], call)
		}
	}
}
