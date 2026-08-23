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

// --- R2.4: retries field in config -------------------------------------------

// Retries declared in defaults is parsed correctly.
func TestProjectDefaultsRetriesParsed(t *testing.T) {
	tempDir := t.TempDir()
	yaml := `
project: retry-test
defaults:
  agent: goose
  retries: 3
repos:
  svc:
    path: /tmp/svc
`
	path := filepath.Join(tempDir, "retry-test.yaml")
	if err := os.WriteFile(path, []byte(yaml), 0644); err != nil {
		t.Fatal(err)
	}
	proj, err := LoadProject(path)
	if err != nil {
		t.Fatalf("LoadProject: %v", err)
	}
	if got := proj.Defaults.Retries; got != 3 {
		t.Errorf("Defaults.Retries = %d, want 3", got)
	}
}

// Retries declared per-repo overrides the project default.
func TestRepoRetriesOverridesDefault(t *testing.T) {
	tempDir := t.TempDir()
	yaml := `
project: retry-test
defaults:
  retries: 2
repos:
  svc:
    path: /tmp/svc
    retries: 5
  other:
    path: /tmp/other
`
	path := filepath.Join(tempDir, "retry-test.yaml")
	if err := os.WriteFile(path, []byte(yaml), 0644); err != nil {
		t.Fatal(err)
	}
	proj, err := LoadProject(path)
	if err != nil {
		t.Fatalf("LoadProject: %v", err)
	}
	if got := proj.Repos["svc"].Retries; got != 5 {
		t.Errorf("svc.Retries = %d, want 5", got)
	}
	if got := proj.Repos["other"].Retries; got != 0 {
		t.Errorf("other.Retries = %d, want 0 (unset)", got)
	}
}

// ResolvedRetries follows repo-first → project-default → zero.
func TestResolvedRetriesResolutionOrder(t *testing.T) {
	proj := &Project{
		Defaults: ProjectDefaults{Retries: 2},
		Repos: map[string]Repo{
			"with-override": {Retries: 4},
			"no-override":   {},
		},
	}
	if got := proj.ResolvedRetries("with-override"); got != 4 {
		t.Errorf("repo with override: got %d, want 4", got)
	}
	if got := proj.ResolvedRetries("no-override"); got != 2 {
		t.Errorf("repo using project default: got %d, want 2", got)
	}
	projNoDefault := &Project{
		Repos: map[string]Repo{"svc": {}},
	}
	if got := projNoDefault.ResolvedRetries("svc"); got != 0 {
		t.Errorf("no retries configured anywhere: got %d, want 0", got)
	}
}

// Omitting the field entirely preserves today's behaviour: one attempt, no retry.
func TestRetriesOmittedMeansZero(t *testing.T) {
	tempDir := t.TempDir()
	yaml := `
project: no-retries
defaults:
  agent: goose
repos:
  svc:
    path: /tmp/svc
`
	path := filepath.Join(tempDir, "no-retries.yaml")
	if err := os.WriteFile(path, []byte(yaml), 0644); err != nil {
		t.Fatal(err)
	}
	proj, err := LoadProject(path)
	if err != nil {
		t.Fatalf("LoadProject: %v", err)
	}
	if got := proj.Defaults.Retries; got != 0 {
		t.Errorf("Defaults.Retries = %d, want 0", got)
	}
	if got := proj.ResolvedRetries("svc"); got != 0 {
		t.Errorf("ResolvedRetries(svc) = %d, want 0", got)
	}
}
