package ui

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/callmeradical/sergeant/internal/config"
	"github.com/callmeradical/sergeant/internal/store"
)

func TestUIFullSuiteAndTDD(t *testing.T) {
	tempDir := t.TempDir()
	dbPath := filepath.Join(tempDir, "test.db")
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("failed to open store: %v", err)
	}
	defer st.Close()

	// 1. Create dummy project yaml in custom config dir
	configDir := filepath.Join(tempDir, "config")
	_ = os.MkdirAll(configDir, 0755)
	t.Setenv("SERGEANT_CONFIG", configDir)

	projYAML := `
name: better-than-boxes
description: Totel inventory platform
repos:
  - name: btb-app
    path: /tmp/btb-app
    factory:
      gates:
        unit-tests: "echo 'pass'"
`
	_ = os.WriteFile(filepath.Join(configDir, "better-than-boxes.yaml"), []byte(projYAML), 0644)

	// 2. Create dummy run, phase, and envelope
	run := &store.RunRecord{
		ID:      "run-suite-1",
		Project: "better-than-boxes",
		TaskID:  "task-suite-1",
		Status:  "passed",
	}
	if err := st.CreateRun(run); err != nil {
		t.Fatalf("failed to create run: %v", err)
	}

	phase := &store.PhaseRecord{
		ID:         "phase-suite-1",
		RunID:      "run-suite-1",
		Repo:       "btb-app",
		Name:       "unit-tests",
		Kind:       "code",
		Status:     "passed",
		DurationMs: 84,
		Payload:    json.RawMessage(`{"output": "All 42 tests passed"}`),
	}
	_ = st.RecordPhase(phase)

	srv := NewServer(st, 0)
	mux := srv.Handler()

	// 3. Test GET /api/projects
	reqProj := httptest.NewRequest("GET", "/api/projects", nil)
	wProj := httptest.NewRecorder()
	mux.ServeHTTP(wProj, reqProj)
	if wProj.Code != http.StatusOK {
		t.Errorf("expected 200 OK from /api/projects, got %d", wProj.Code)
	}

	// 4. Test GET /api/project-details?name=better-than-boxes
	reqProjDet := httptest.NewRequest("GET", "/api/project-details?name=better-than-boxes", nil)
	wProjDet := httptest.NewRecorder()
	mux.ServeHTTP(wProjDet, reqProjDet)
	if wProjDet.Code != http.StatusOK {
		t.Errorf("expected 200 OK from /api/project-details, got %d", wProjDet.Code)
	}

	// 5. Test POST /api/refine-project
	refinePayload, _ := json.Marshal(map[string]interface{}{
		"name":        "better-than-boxes",
		"description": "Updated Totel inventory platform",
		"defaults": map[string]string{
			"agent": "claude",
			"model": "anthropic/claude-3-7-sonnet",
		},
		"repos": map[string]map[string]interface{}{
			"btb-app": {
				"path": "/tmp/btb-app",
				"role": "Core API",
				"factory": map[string]interface{}{
					"gates": map[string]string{
						"test": "go test -v ./...",
						"lint": "golangci-lint run",
					},
				},
			},
		},
	})
	reqRefine := httptest.NewRequest("POST", "/api/refine-project", bytes.NewBuffer(refinePayload))
	wRefine := httptest.NewRecorder()
	mux.ServeHTTP(wRefine, reqRefine)
	if wRefine.Code != http.StatusOK {
		t.Errorf("expected 200 OK from /api/refine-project, got %d", wRefine.Code)
	}

	// 6. Test GET /api/runs?project=better-than-boxes
	reqRuns := httptest.NewRequest("GET", "/api/runs?project=better-than-boxes", nil)
	wRuns := httptest.NewRecorder()
	mux.ServeHTTP(wRuns, reqRuns)
	if wRuns.Code != http.StatusOK {
		t.Errorf("expected 200 OK from /api/runs, got %d", wRuns.Code)
	}

	// 7. Test GET /api/fleet
	reqFleet := httptest.NewRequest("GET", "/api/fleet", nil)
	wFleet := httptest.NewRecorder()
	mux.ServeHTTP(wFleet, reqFleet)
	if wFleet.Code != http.StatusOK {
		t.Errorf("expected 200 OK from /api/fleet, got %d", wFleet.Code)
	}

	// 8. Test POST /api/create-pr endpoint
	prPayload, _ := json.Marshal(map[string]interface{}{
		"run_id":  "run-suite-1",
		"project": "better-than-boxes",
		"title":   "feat(btb-app): stripe webhooks verified",
		"body":    "100% deterministic code gates passed",
	})
	reqPR := httptest.NewRequest("POST", "/api/create-pr", bytes.NewBuffer(prPayload))
	wPR := httptest.NewRecorder()
	mux.ServeHTTP(wPR, reqPR)
	if wPR.Code != http.StatusOK {
		t.Errorf("expected 200 OK from /api/create-pr, got %d", wPR.Code)
	}
}

// Saving project config must patch, never rewrite. Previously this endpoint
// marshalled a Project struct built from JSON, which emitted `repos: null` and
// destroyed every repo, gate, pipeline and the whole `dag:` block.
func TestRefineProjectPreservesUnmanagedConfig(t *testing.T) {
	cfgDir := t.TempDir()
	t.Setenv("SERGEANT_CONFIG", cfgDir)

	original := `# hand-maintained, comments must survive
name: canary
description: before
defaults:
  agent: opencode
  model: anthropic/claude-opus-5 # pinned deliberately
repos:
  - name: svc
    path: /tmp/svc
    role: Core API
    group: backend
    factory:
      pipeline: ["plan", "build", "test"]
      gates:
        unit-tests: "pytest -q"
        typecheck: "mypy ."
dag:
  name: canary-pipeline
  stages:
    - name: feature-execution
      repos: ["svc"]
`
	path := filepath.Join(cfgDir, "canary.yaml")
	if err := os.WriteFile(path, []byte(original), 0644); err != nil {
		t.Fatal(err)
	}

	st, err := store.Open(filepath.Join(cfgDir, "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	mux := NewServer(st, 0).Handler()

	body := `{"name":"canary","description":"after","defaults":{"agent":"claude"},
	          "repos":{"svc":{"role":"Core API v2","factory":{"gates":{"unit-tests":"pytest -q --strict","typecheck":"mypy ."}}},
	                   "ghost":{"role":"nope"}}}`
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest("POST", "/api/refine-project", strings.NewReader(body)))
	if w.Code != http.StatusOK {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}

	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	out := string(got)

	// Things the request did not mention must survive verbatim.
	for _, want := range []string{
		"# hand-maintained, comments must survive", // comments
		"model: anthropic/claude-opus-5",           // defaults.model
		"# pinned deliberately",                    // inline comment
		"path: /tmp/svc",                           // repo path
		"group: backend",                           // repo group
		"pipeline:",                                // factory.pipeline
		"dag:",                                     // the DAG block
		"canary-pipeline",
		"feature-execution",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("save destroyed %q\n--- file ---\n%s", want, out)
		}
	}

	// Things the request did change.
	if !strings.Contains(out, "description: after") {
		t.Error("description not updated")
	}
	if !strings.Contains(out, "agent: claude") {
		t.Error("defaults.agent not updated")
	}
	if !strings.Contains(out, "role: Core API v2") {
		t.Error("repo role not updated")
	}
	if !strings.Contains(out, "pytest -q --strict") {
		t.Error("gate command not updated")
	}
	if strings.Contains(out, "repos: null") {
		t.Fatal("repos destroyed")
	}

	// An unknown repo must be reported, not invented into the file.
	if strings.Contains(out, "ghost") {
		t.Error("invented a repo that was not already configured")
	}
	var resp struct {
		UnknownRepos []string `json:"unknown_repos"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	if len(resp.UnknownRepos) != 1 || resp.UnknownRepos[0] != "ghost" {
		t.Errorf("unknown_repos = %v, want [ghost]", resp.UnknownRepos)
	}

	// The result must still parse as a project with its repo intact.
	proj, err := config.LoadProject(path)
	if err != nil {
		t.Fatalf("saved file no longer loads: %v", err)
	}
	if _, ok := proj.Repos["svc"]; !ok {
		t.Errorf("repo svc missing after save; repos=%v", proj.Repos)
	}
	if proj.DAG == nil || len(proj.DAG.Stages) != 1 {
		t.Errorf("DAG lost after save: %+v", proj.DAG)
	}
}
