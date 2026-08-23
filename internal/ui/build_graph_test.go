package ui

import (
	"encoding/json"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/callmeradical/sergeant/internal/store"
)

func gitRepoWithOneFileForGraphTest(t *testing.T) string {
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
	if err := os.WriteFile(filepath.Join(dir, "main.go"), []byte("package main\nfunc main() {}\n"), 0644); err != nil {
		t.Fatal(err)
	}
	run("add", "-A")
	run("commit", "-q", "-m", "init")
	return dir
}

// POST /api/build-graph builds and publishes a project's graph.
func TestBuildGraphEndpointBuildsAndPublishes(t *testing.T) {
	tempDir := t.TempDir()
	st, err := store.Open(filepath.Join(tempDir, "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	configDir := filepath.Join(tempDir, "config")
	if err := os.MkdirAll(configDir, 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SERGEANT_CONFIG", configDir)

	repo := gitRepoWithOneFileForGraphTest(t)
	output := filepath.Join(tempDir, "published")
	projYAML := "project: has-graph\n" +
		"repos:\n" +
		"  svc:\n" +
		"    path: " + repo + "\n" +
		"graphify:\n" +
		"  output: " + output + "\n"
	if err := os.WriteFile(filepath.Join(configDir, "has-graph.yaml"), []byte(projYAML), 0644); err != nil {
		t.Fatal(err)
	}

	mux := NewServer(st, 0).Handler()
	w := postJSON(t, mux, "/api/build-graph", `{"project":"has-graph"}`)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", w.Code, w.Body.String())
	}

	var resp struct {
		Status string `json:"status"`
		Output string `json:"output"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.Status != "built" || resp.Output != output {
		t.Errorf("response = %+v, want status=built output=%q", resp, output)
	}
	if _, err := os.Stat(filepath.Join(output, "graph.json")); err != nil {
		t.Errorf("expected graph.json to be published: %v", err)
	}
}

// POST /api/build-graph for a project with no graphify: block is a 400, not
// a crash or a silent no-op.
func TestBuildGraphEndpointRejectsProjectWithoutGraphifyBlock(t *testing.T) {
	tempDir := t.TempDir()
	st, err := store.Open(filepath.Join(tempDir, "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	configDir := filepath.Join(tempDir, "config")
	if err := os.MkdirAll(configDir, 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SERGEANT_CONFIG", configDir)

	projYAML := "project: no-graph\n" +
		"repos:\n" +
		"  svc:\n" +
		"    path: /tmp/svc\n"
	if err := os.WriteFile(filepath.Join(configDir, "no-graph.yaml"), []byte(projYAML), 0644); err != nil {
		t.Fatal(err)
	}

	mux := NewServer(st, 0).Handler()
	w := postJSON(t, mux, "/api/build-graph", `{"project":"no-graph"}`)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400; body=%s", w.Code, w.Body.String())
	}
}
