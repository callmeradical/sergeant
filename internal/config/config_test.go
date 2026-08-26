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

// --- D9: project graphify configuration --------------------------------------

// A project's graphify: block parses into typed fields, not just raw YAML.
func TestGraphifyBlockParsesIntoTypedFields(t *testing.T) {
	tempDir := t.TempDir()
	yaml := `
project: graph-test
repos:
  backend:
    path: /tmp/backend
    group: core
  frontend:
    path: /tmp/frontend
    group: ui
graphify:
  output: /tmp/graph-test/graphify-out
  include_groups: [core]
  exclude_patterns: ["**/*.test.ts"]
`
	path := filepath.Join(tempDir, "graph-test.yaml")
	if err := os.WriteFile(path, []byte(yaml), 0644); err != nil {
		t.Fatal(err)
	}
	proj, err := LoadProject(path)
	if err != nil {
		t.Fatalf("LoadProject: %v", err)
	}
	if proj.Graphify == nil {
		t.Fatal("expected Graphify to be non-nil")
	}
	if proj.Graphify.Output != "/tmp/graph-test/graphify-out" {
		t.Errorf("Output = %q, want /tmp/graph-test/graphify-out", proj.Graphify.Output)
	}
	if len(proj.Graphify.IncludeGroups) != 1 || proj.Graphify.IncludeGroups[0] != "core" {
		t.Errorf("IncludeGroups = %v, want [core]", proj.Graphify.IncludeGroups)
	}
	if len(proj.Graphify.ExcludePatterns) != 1 || proj.Graphify.ExcludePatterns[0] != "**/*.test.ts" {
		t.Errorf("ExcludePatterns = %v, want [**/*.test.ts]", proj.Graphify.ExcludePatterns)
	}
}

// A project that declares no graphify: block has a nil Graphify, distinct
// from a project that declared an empty block.
func TestProjectWithoutGraphifyBlockHasNilGraphify(t *testing.T) {
	tempDir := t.TempDir()
	yaml := `
project: no-graph
repos:
  svc:
    path: /tmp/svc
`
	path := filepath.Join(tempDir, "no-graph.yaml")
	if err := os.WriteFile(path, []byte(yaml), 0644); err != nil {
		t.Fatal(err)
	}
	proj, err := LoadProject(path)
	if err != nil {
		t.Fatalf("LoadProject: %v", err)
	}
	if proj.Graphify != nil {
		t.Errorf("expected Graphify to be nil for a project with no graphify: block, got %+v", proj.Graphify)
	}
}

// --- task-tracking-is-a-readonly-export: project export configuration ------

// A project's export: block parses into typed fields, not just raw YAML.
func TestExportBlockParsesIntoTypedFields(t *testing.T) {
	tempDir := t.TempDir()
	yaml := `
project: export-test
repos:
  svc:
    path: /tmp/svc
export:
  backend: jira
`
	path := filepath.Join(tempDir, "export-test.yaml")
	if err := os.WriteFile(path, []byte(yaml), 0644); err != nil {
		t.Fatal(err)
	}
	proj, err := LoadProject(path)
	if err != nil {
		t.Fatalf("LoadProject: %v", err)
	}
	if proj.Export == nil {
		t.Fatal("expected Export to be non-nil")
	}
	if proj.Export.Backend != "jira" {
		t.Errorf("Backend = %q, want jira", proj.Export.Backend)
	}
}

// A project that declares no export: block has a nil Export, distinct from a
// project that declared an empty block — the same distinction Graphify makes.
func TestProjectWithoutExportBlockHasNilExport(t *testing.T) {
	tempDir := t.TempDir()
	yaml := `
project: no-export
repos:
  svc:
    path: /tmp/svc
`
	path := filepath.Join(tempDir, "no-export.yaml")
	if err := os.WriteFile(path, []byte(yaml), 0644); err != nil {
		t.Fatal(err)
	}
	proj, err := LoadProject(path)
	if err != nil {
		t.Fatalf("LoadProject: %v", err)
	}
	if proj.Export != nil {
		t.Errorf("expected Export to be nil for a project with no export: block, got %+v", proj.Export)
	}
}

// --- data-retention-and-rotation: project retention configuration ----------

// A project that declares no retention: block has a nil Retention, distinct
// from a project that declared an empty block — the same distinction
// Graphify/Export already make. No run, phase, envelope, delivery, or
// artifact belonging to such a project is ever rotated (spec.md's "A project
// with no retention block never rotates").
func TestProjectWithoutRetentionBlockHasNilRetention(t *testing.T) {
	tempDir := t.TempDir()
	yaml := `
project: no-retention
repos:
  svc:
    path: /tmp/svc
`
	path := filepath.Join(tempDir, "no-retention.yaml")
	if err := os.WriteFile(path, []byte(yaml), 0644); err != nil {
		t.Fatal(err)
	}
	proj, err := LoadProject(path)
	if err != nil {
		t.Fatalf("LoadProject: %v", err)
	}
	if proj.Retention != nil {
		t.Errorf("expected Retention to be nil for a project with no retention: block, got %+v", proj.Retention)
	}
}

// A project's retention: block parses into typed fields, not just raw YAML.
func TestRetentionBlockParsesIntoTypedFields(t *testing.T) {
	tempDir := t.TempDir()
	yaml := `
project: retention-test
repos:
  svc:
    path: /tmp/svc
retention:
  runs_after_days: 30
  artifacts_after_days: 7
`
	path := filepath.Join(tempDir, "retention-test.yaml")
	if err := os.WriteFile(path, []byte(yaml), 0644); err != nil {
		t.Fatal(err)
	}
	proj, err := LoadProject(path)
	if err != nil {
		t.Fatalf("LoadProject: %v", err)
	}
	if proj.Retention == nil {
		t.Fatal("expected Retention to be non-nil")
	}
	if proj.Retention.RunsAfterDays != 30 {
		t.Errorf("RunsAfterDays = %d, want 30", proj.Retention.RunsAfterDays)
	}
	if proj.Retention.ArtifactsAfterDays != 7 {
		t.Errorf("ArtifactsAfterDays = %d, want 7", proj.Retention.ArtifactsAfterDays)
	}
}

// A retention: block with a zero horizon fails to load with a clear error,
// not a silently-accepted zero horizon that would rotate everything on the
// first pass (spec.md's "A zero horizon is rejected, not silently accepted").
func TestRetentionBlockWithZeroHorizonFailsToLoad(t *testing.T) {
	tempDir := t.TempDir()
	yaml := `
project: zero-retention
repos:
  svc:
    path: /tmp/svc
retention:
  runs_after_days: 0
  artifacts_after_days: 7
`
	path := filepath.Join(tempDir, "zero-retention.yaml")
	if err := os.WriteFile(path, []byte(yaml), 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadProject(path); err == nil {
		t.Fatal("expected LoadProject to fail for a retention block with runs_after_days: 0, got nil error")
	}
}

// A negative horizon is rejected the same way a zero one is.
func TestRetentionBlockWithNegativeHorizonFailsToLoad(t *testing.T) {
	tempDir := t.TempDir()
	yaml := `
project: negative-retention
repos:
  svc:
    path: /tmp/svc
retention:
  runs_after_days: 30
  artifacts_after_days: -1
`
	path := filepath.Join(tempDir, "negative-retention.yaml")
	if err := os.WriteFile(path, []byte(yaml), 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadProject(path); err == nil {
		t.Fatal("expected LoadProject to fail for a retention block with artifacts_after_days: -1, got nil error")
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
