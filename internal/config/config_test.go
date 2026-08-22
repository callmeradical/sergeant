package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadProject(t *testing.T) {
	tempDir := t.TempDir()
	sampleYAML := `
project: test-project
defaults:
  agent: pi
  model: openrouter/google/gemini-2.5-flash
repos:
  backend:
    path: /tmp/test-backend
    factory:
      pipeline: [plan, build, test]
      gates:
        test: "go test ./..."
        lint: "golangci-lint run"
  frontend:
    path: /tmp/test-frontend
    factory:
      pipeline: [plan, build, test]
      gates:
        test: "bun test"
dag:
  name: full-feature-sdlc
  stages:
    - name: backend-build
      repos: [backend]
      brief: "Implement backend API"
    - name: frontend-build
      repos: [frontend]
      after: [backend-build]
      brief: "Implement frontend UI"
`
	configPath := filepath.Join(tempDir, "test-project.yaml")
	if err := os.WriteFile(configPath, []byte(sampleYAML), 0644); err != nil {
		t.Fatalf("failed to write test yaml: %v", err)
	}

	proj, err := LoadProject(configPath)
	if err != nil {
		t.Fatalf("LoadProject failed: %v", err)
	}

	if proj.Name != "test-project" {
		t.Errorf("expected project name test-project, got %s", proj.Name)
	}
	if len(proj.Repos) != 2 {
		t.Errorf("expected 2 repos, got %d", len(proj.Repos))
	}
	if proj.Repos["backend"].Factory.Gates["test"] != "go test ./..." {
		t.Errorf("expected backend test gate, got %s", proj.Repos["backend"].Factory.Gates["test"])
	}
	if len(proj.DAG.Stages) != 2 {
		t.Errorf("expected 2 stages, got %d", len(proj.DAG.Stages))
	}
	if proj.DAG.Stages[1].After[0] != "backend-build" {
		t.Errorf("expected frontend to depend on backend-build, got %s", proj.DAG.Stages[1].After[0])
	}
}
