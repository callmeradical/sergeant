package ui

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
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

// dispatchFixture builds a project whose single repo lives in a temp dir, so a
// dispatch test can create and inspect openspec/changes/<id>/ without touching
// any real checkout. SERGEANT_FLEET_DIR is redirected for the same reason.
func dispatchFixture(t *testing.T) (mux http.Handler, st *store.Store, repoPath string) {
	t.Helper()

	base := t.TempDir()
	repoPath = filepath.Join(base, "svc")
	if err := os.MkdirAll(repoPath, 0o755); err != nil {
		t.Fatal(err)
	}

	cfgDir := filepath.Join(base, "config")
	if err := os.MkdirAll(cfgDir, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SERGEANT_CONFIG", cfgDir)
	t.Setenv("SERGEANT_FLEET_DIR", filepath.Join(base, "fleet"))

	projYAML := "name: o3\nrepos:\n  - name: svc\n    path: " + repoPath + "\n"
	if err := os.WriteFile(filepath.Join(cfgDir, "o3.yaml"), []byte(projYAML), 0o644); err != nil {
		t.Fatal(err)
	}

	var err error
	st, err = store.Open(filepath.Join(base, "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	return NewServer(st, 0).Handler(), st, repoPath
}

func postDispatch(t *testing.T, mux http.Handler, body string) *httptest.ResponseRecorder {
	t.Helper()
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest("POST", "/api/dispatch", strings.NewReader(body)))
	return w
}

// Decision O3: a dispatch must resolve to a change. Naming one that is absent is
// an operator error, and sergeant must not fabricate the planning record — nor
// leave a run row behind for work it refused to start.
func TestDispatchWithUnknownChangeIDIsRejectedAndCreatesNoRun(t *testing.T) {
	mux, st, repoPath := dispatchFixture(t)

	w := postDispatch(t, mux, `{"project":"o3","brief":"add stripe webhooks","change_id":"no-such-change"}`)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400; body=%s", w.Code, w.Body.String())
	}
	if !strings.Contains(w.Body.String(), "no-such-change") {
		t.Errorf("error does not name the change: %s", w.Body.String())
	}
	wantPath := filepath.Join(repoPath, "openspec", "changes", "no-such-change")
	if !strings.Contains(w.Body.String(), wantPath) {
		t.Errorf("error does not name the missing path %s: %s", wantPath, w.Body.String())
	}

	runs, err := st.ListRecentRuns(50)
	if err != nil {
		t.Fatal(err)
	}
	if len(runs) != 0 {
		t.Errorf("dispatch created %d run(s) after refusing the change: %+v", len(runs), runs)
	}
	if _, err := os.Stat(filepath.Join(repoPath, "openspec")); !os.IsNotExist(err) {
		t.Errorf("dispatch invented an openspec tree for a change it rejected (stat err=%v)", err)
	}
}

// A change id is interpolated into a filesystem path, so a traversal attempt
// must be refused before it reaches os.Stat or the openspec CLI.
func TestDispatchRejectsChangeIDThatIsAPath(t *testing.T) {
	mux, st, _ := dispatchFixture(t)

	for _, id := range []string{"../escape", "..", "nested/change", `win\change`, "a/../../b"} {
		// Marshalled, not concatenated: a backslash in an id must reach the handler
		// as data rather than as a broken JSON escape.
		body, err := json.Marshal(map[string]string{
			"project": "o3", "brief": "add stripe webhooks", "change_id": id,
		})
		if err != nil {
			t.Fatal(err)
		}
		w := postDispatch(t, mux, string(body))
		if w.Code != http.StatusBadRequest {
			t.Errorf("change_id %q: status = %d, want 400; body=%s", id, w.Code, w.Body.String())
			continue
		}
		if !strings.Contains(w.Body.String(), "not a path") {
			t.Errorf("change_id %q: error should explain a change id is not a path, got %s", id, w.Body.String())
		}
	}

	runs, err := st.ListRecentRuns(50)
	if err != nil {
		t.Fatal(err)
	}
	if len(runs) != 0 {
		t.Errorf("a rejected change id still created %d run(s)", len(runs))
	}

	// The same rule, asserted on the unit that enforces it.
	for _, id := range []string{"", ".", "..", "a/b", `a\b`, "x/../y"} {
		if err := validateChangeID(id); err == nil {
			t.Errorf("validateChangeID(%q) = nil, want an error", id)
		}
	}
	if err := validateChangeID("add-stripe-webhooks"); err != nil {
		t.Errorf("validateChangeID rejected a legitimate id: %v", err)
	}
}

// An existing change is accepted and recorded on the run, which is what makes
// the run auditable against openspec/changes/<id>/ later.
func TestDispatchRecordsAnExistingChangeIDOnTheRun(t *testing.T) {
	mux, st, repoPath := dispatchFixture(t)

	const changeID = "add-stripe-webhooks"
	if err := os.MkdirAll(filepath.Join(repoPath, "openspec", "changes", changeID), 0o755); err != nil {
		t.Fatal(err)
	}

	w := postDispatch(t, mux, `{"project":"o3","brief":"add stripe webhooks","change_id":"`+changeID+`"}`)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", w.Code, w.Body.String())
	}

	var resp struct {
		TaskID   string `json:"task_id"`
		ChangeID string `json:"change_id"`
		Created  bool   `json:"change_created"`
		Repo     string `json:"change_repo"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.ChangeID != changeID {
		t.Errorf("response change_id = %q, want %q", resp.ChangeID, changeID)
	}
	if resp.Created {
		t.Error("response claims sergeant created a change that already existed")
	}
	if resp.Repo != "svc" {
		t.Errorf("response change_repo = %q, want svc", resp.Repo)
	}

	runs, err := st.ListRunsForProject("o3", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(runs) != 1 {
		t.Fatalf("got %d runs, want 1", len(runs))
	}
	if runs[0].ChangeID != changeID {
		t.Errorf("run.ChangeID = %q, want %q", runs[0].ChangeID, changeID)
	}
	if runs[0].ID != resp.TaskID {
		t.Errorf("run id %q does not match dispatched task_id %q", runs[0].ID, resp.TaskID)
	}
}

// The derivation is tested directly: it is pure, and the suite must pass on a
// machine with no openspec binary installed.
func TestDeriveChangeIDIsKebabCaseAndCapped(t *testing.T) {
	cases := []struct {
		name  string
		brief string
		want  string
	}{
		{"lowercases and hyphenates", "Add Stripe Webhooks", "add-stripe-webhooks"},
		{"collapses punctuation runs", "fix:  the __broken__ gate!!", "fix-the-broken-gate"},
		{"trims edges", "  ...cleanup...  ", "cleanup"},
		{"keeps digits", "bump to v2 API", "bump-to-v2-api"},
		{"newlines are separators", "first line\nsecond line", "first-line-second-line"},
		{"no alphanumerics yields nothing", "!!! ???", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := deriveChangeID(tc.brief); got != tc.want {
				t.Errorf("deriveChangeID(%q) = %q, want %q", tc.brief, got, tc.want)
			}
		})
	}

	long := deriveChangeID(strings.Repeat("refactor the dispatch handler ", 20))
	if len(long) > maxChangeIDLen {
		t.Errorf("derived id is %d chars (%q), want <= %d", len(long), long, maxChangeIDLen)
	}
	if strings.HasPrefix(long, "-") || strings.HasSuffix(long, "-") {
		t.Errorf("derived id has a dangling hyphen: %q", long)
	}
	if err := validateChangeID(long); err != nil {
		t.Errorf("derived id is not a legal change id: %v", err)
	}

	// A single word longer than the cap is truncated, not emptied.
	oneWord := deriveChangeID(strings.Repeat("x", maxChangeIDLen+20))
	if len(oneWord) != maxChangeIDLen {
		t.Errorf("single long word derived to %d chars (%q), want %d", len(oneWord), oneWord, maxChangeIDLen)
	}
}

// resolveChange must not need the CLI on the two paths that do not scaffold.
func TestResolveChangeDoesNotRequireTheCLIForExistingChanges(t *testing.T) {
	repo := t.TempDir()
	dir := filepath.Join(repo, "openspec", "changes", "already-planned")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}

	// Named explicitly.
	ref, err := resolveChange(repo, "already-planned", "")
	if err != nil {
		t.Fatalf("resolveChange with an existing id: %v", err)
	}
	if ref.ID != "already-planned" || ref.Dir != dir || ref.Created {
		t.Errorf("ref = %+v, want {already-planned %s false}", ref, dir)
	}

	// Derived from a brief onto a change that already exists: reused, not recreated.
	ref, err = resolveChange(repo, "", "Already planned")
	if err != nil {
		t.Fatalf("resolveChange deriving onto an existing change: %v", err)
	}
	if ref.ID != "already-planned" || ref.Created {
		t.Errorf("ref = %+v, want the existing change reused with Created=false", ref)
	}

	// A brief with no derivable id fails instead of scaffolding something unnamed.
	if _, err := resolveChange(repo, "", "!!!"); err == nil {
		t.Error("resolveChange with an underivable brief returned no error")
	}
}

// Scaffolding is the one part of O3 that needs the binary, so this test skips
// when it is absent rather than making the CLI a dependency of the suite.
func TestResolveChangeScaffoldsFromTheBrief(t *testing.T) {
	if _, err := exec.LookPath("openspec"); err != nil {
		t.Skip("openspec CLI not on PATH; scaffolding path not exercised")
	}

	repo := t.TempDir()
	ref, err := resolveChange(repo, "", "Add Stripe Webhooks")
	if err != nil {
		t.Fatalf("resolveChange failed to scaffold: %v", err)
	}
	if ref.ID != "add-stripe-webhooks" {
		t.Errorf("ref.ID = %q, want add-stripe-webhooks", ref.ID)
	}
	if !ref.Created {
		t.Error("ref.Created = false for a change sergeant just scaffolded")
	}
	want := filepath.Join(repo, "openspec", "changes", "add-stripe-webhooks")
	if ref.Dir != want {
		t.Errorf("ref.Dir = %q, want %q", ref.Dir, want)
	}
	if info, err := os.Stat(ref.Dir); err != nil || !info.IsDir() {
		t.Errorf("scaffolded dir %s is not on disk (err=%v)", ref.Dir, err)
	}

	// Scaffolding the same brief twice reuses the change instead of failing.
	again, err := resolveChange(repo, "", "add stripe webhooks")
	if err != nil {
		t.Fatalf("second resolveChange failed: %v", err)
	}
	if again.ID != ref.ID || again.Created {
		t.Errorf("second resolve = %+v, want the same id with Created=false", again)
	}
}
