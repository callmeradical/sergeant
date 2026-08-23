package ui

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/callmeradical/sergeant/internal/config"
	"github.com/callmeradical/sergeant/internal/store"

	_ "modernc.org/sqlite"
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
	mux, st, repoPaths, _ := dispatchFixtureRepos(t, "svc")
	return mux, st, repoPaths["svc"]
}

// dispatchFixtureRepos is dispatchFixture for a project with more than one
// repository, which is what a dispatch producing several bullets needs. It also
// returns the database path so a test can assert on rows the public store API
// deliberately does not expose, such as "no bullet exists at all".
func dispatchFixtureRepos(t *testing.T, repos ...string) (mux http.Handler, st *store.Store, repoPaths map[string]string, dbPath string) {
	t.Helper()

	base := t.TempDir()
	cfgDir := filepath.Join(base, "config")
	if err := os.MkdirAll(cfgDir, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SERGEANT_CONFIG", cfgDir)
	t.Setenv("SERGEANT_FLEET_DIR", filepath.Join(base, "fleet"))

	repoPaths = map[string]string{}
	projYAML := "name: o3\nrepos:\n"
	for _, name := range repos {
		p := filepath.Join(base, name)
		if err := os.MkdirAll(p, 0o755); err != nil {
			t.Fatal(err)
		}
		repoPaths[name] = p
		projYAML += "  - name: " + name + "\n    path: " + p + "\n"
	}
	if err := os.WriteFile(filepath.Join(cfgDir, "o3.yaml"), []byte(projYAML), 0o644); err != nil {
		t.Fatal(err)
	}

	dbPath = filepath.Join(base, "t.db")
	var err error
	st, err = store.Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	return NewServer(st, 0).Handler(), st, repoPaths, dbPath
}

// countRows reads the bullets table directly. The store exposes bullets only
// through their intent, so "no intent was written" cannot by itself prove "no
// bullet was written" — a bullet with a dangling intent_id would be invisible.
// The rejected-dispatch scenario claims the stronger thing, so the test checks
// the stronger thing.
func countRows(t *testing.T, dbPath, table string) int {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var n int
	if err := db.QueryRow("SELECT COUNT(*) FROM " + table).Scan(&n); err != nil {
		t.Fatalf("counting %s: %v", table, err)
	}
	return n
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

// Decision D4 puts intents and bullets in sergeant's own store, and decision D8
// makes the intent the dashboard's primary noun. Neither is satisfiable while a
// dispatch records only a run, so a dispatch must write the intent it serves and
// one bullet per target repository.
func TestDispatchPersistsItsIntentAndOneBulletPerTargetRepo(t *testing.T) {
	mux, st, repoPaths, _ := dispatchFixtureRepos(t, "api", "web", "worker")

	// changeRepo picks the first requested repo that is configured, so the change
	// directory has to exist under api for this dispatch to resolve.
	const changeID = "add-stripe-webhooks"
	if err := os.MkdirAll(filepath.Join(repoPaths["api"], "openspec", "changes", changeID), 0o755); err != nil {
		t.Fatal(err)
	}

	const brief = "add stripe webhooks"
	w := postDispatch(t, mux,
		`{"project":"o3","brief":"`+brief+`","change_id":"`+changeID+`","repos":["api","web","worker"]}`)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", w.Code, w.Body.String())
	}
	var resp struct {
		TaskID string `json:"task_id"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}

	intents, err := st.ListIntentsForProject("o3")
	if err != nil {
		t.Fatal(err)
	}
	if len(intents) != 1 {
		t.Fatalf("got %d intents, want 1: %+v", len(intents), intents)
	}
	intent := intents[0]
	if want := resp.TaskID + "-intent"; intent.ID != want {
		t.Errorf("intent id = %q, want %q", intent.ID, want)
	}
	if intent.Statement != brief {
		t.Errorf("intent statement = %q, want %q", intent.Statement, brief)
	}
	if intent.Project != "o3" {
		t.Errorf("intent project = %q, want o3", intent.Project)
	}
	if intent.Status != "in_progress" {
		t.Errorf("intent status = %q, want in_progress", intent.Status)
	}

	bullets, err := st.ListBulletsForIntent(intent.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(bullets) != 3 {
		t.Fatalf("got %d bullets, want 3: %+v", len(bullets), bullets)
	}
	// ListBulletsForIntent orders by position, so index i is position i+1.
	wantRepos := []string{"api", "web", "worker"}
	seen := map[int]bool{}
	for i, b := range bullets {
		if b.Position != i+1 {
			t.Errorf("bullet %d position = %d, want %d", i, b.Position, i+1)
		}
		if seen[b.Position] {
			t.Errorf("position %d is used by more than one bullet", b.Position)
		}
		seen[b.Position] = true
		if b.Repo != wantRepos[i] {
			t.Errorf("bullet at position %d names repo %q, want %q", b.Position, b.Repo, wantRepos[i])
		}
		// A bullet spanning two repositories is a modelling error, not a large
		// bullet, so the field must hold exactly one repository name.
		if strings.ContainsAny(b.Repo, " ,") || strings.TrimSpace(b.Repo) == "" {
			t.Errorf("bullet repo %q is not exactly one repository name", b.Repo)
		}
		if want := fmt.Sprintf("%s-b%d", resp.TaskID, i+1); b.ID != want {
			t.Errorf("bullet id = %q, want %q", b.ID, want)
		}
		if b.IntentID != intent.ID {
			t.Errorf("bullet %s intent_id = %q, want %q", b.ID, b.IntentID, intent.ID)
		}
	}

	runs, err := st.ListRunsForProject("o3", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(runs) != 1 {
		t.Fatalf("got %d runs, want 1", len(runs))
	}
	if runs[0].IntentID != intent.ID {
		t.Errorf("run.IntentID = %q, want %q", runs[0].IntentID, intent.ID)
	}
}

// When a dispatch names no repositories every configured repository is a target,
// and the bullet order must be reproducible. Map iteration order would give the
// same dispatch a different merge order on every call.
func TestDispatchWithNoReposBulletsEveryRepoInASortedOrder(t *testing.T) {
	mux, st, repoPaths, _ := dispatchFixtureRepos(t, "worker", "api", "web")

	// With no requested repos, changeRepo falls back to the sorted repo list, so
	// api owns the change.
	const changeID = "add-stripe-webhooks"
	if err := os.MkdirAll(filepath.Join(repoPaths["api"], "openspec", "changes", changeID), 0o755); err != nil {
		t.Fatal(err)
	}

	w := postDispatch(t, mux, `{"project":"o3","brief":"add stripe webhooks","change_id":"`+changeID+`"}`)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", w.Code, w.Body.String())
	}

	intents, err := st.ListIntentsForProject("o3")
	if err != nil {
		t.Fatal(err)
	}
	if len(intents) != 1 {
		t.Fatalf("got %d intents, want 1", len(intents))
	}
	bullets, err := st.ListBulletsForIntent(intents[0].ID)
	if err != nil {
		t.Fatal(err)
	}
	var gotRepos []string
	for _, b := range bullets {
		gotRepos = append(gotRepos, b.Repo)
	}
	want := []string{"api", "web", "worker"}
	if len(gotRepos) != len(want) {
		t.Fatalf("bullet repos = %v, want %v", gotRepos, want)
	}
	for i := range want {
		if gotRepos[i] != want[i] {
			t.Fatalf("bullet repos = %v, want %v", gotRepos, want)
		}
	}
}

// Decision O3 orders the records: the planning record precedes the durable one.
// A dispatch refused because its change cannot be resolved must therefore leave
// no intent and no bullet behind.
func TestDispatchRejectedByChangeResolutionWritesNoIntentOrBullet(t *testing.T) {
	mux, st, _, dbPath := dispatchFixtureRepos(t, "api", "web")

	w := postDispatch(t, mux,
		`{"project":"o3","brief":"add stripe webhooks","change_id":"no-such-change","repos":["api","web"]}`)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400; body=%s", w.Code, w.Body.String())
	}

	intents, err := st.ListIntentsForProject("o3")
	if err != nil {
		t.Fatal(err)
	}
	if len(intents) != 0 {
		t.Errorf("rejected dispatch left %d intent(s) behind: %+v", len(intents), intents)
	}
	if n := countRows(t, dbPath, "bullets"); n != 0 {
		t.Errorf("rejected dispatch left %d bullet(s) behind", n)
	}
	if n := countRows(t, dbPath, "runs"); n != 0 {
		t.Errorf("rejected dispatch left %d run(s) behind", n)
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

func postJSON(t *testing.T, mux http.Handler, path, body string) *httptest.ResponseRecorder {
	t.Helper()
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest("POST", path, strings.NewReader(body)))
	return w
}

// A run that died with work on disk must be resumable. Run sgt-1787427981 was
// killed at its former default timeout having already committed a change whose
// build and tests passed; the commit survived on its branch with nothing able to
// pick it up. Orphaning completed work is the failure being fixed.
func TestResumeRestartsAFailedRun(t *testing.T) {
	mux, st, _ := dispatchFixture(t)

	if err := st.CreateRun(&store.RunRecord{
		ID: "sgt-orphan", Project: "o3", TaskID: "sgt-orphan",
		Brief: "finish the work", Status: "failed",
	}); err != nil {
		t.Fatal(err)
	}

	w := postJSON(t, mux, "/api/run-resume", `{"id":"sgt-orphan"}`)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", w.Code, w.Body.String())
	}
	if !strings.Contains(w.Body.String(), "sgt-orphan") {
		t.Errorf("response does not name the resumed run: %s", w.Body.String())
	}

	// Resume must reuse the run, not create a parallel one. A second row would
	// split one piece of work across two records and two branches.
	runs, err := st.ListRecentRuns(50)
	if err != nil {
		t.Fatal(err)
	}
	if len(runs) != 1 {
		t.Errorf("resume produced %d run(s), want 1; it must re-enter the run, not fork it", len(runs))
	}
}

// Resuming a run that already passed would re-run work for no reason and could
// turn an earned pass into a fresh failure.
func TestResumeRefusesARunThatAlreadyPassed(t *testing.T) {
	mux, st, _ := dispatchFixture(t)
	if err := st.CreateRun(&store.RunRecord{
		ID: "sgt-done", Project: "o3", TaskID: "sgt-done", Status: "passed",
	}); err != nil {
		t.Fatal(err)
	}

	w := postJSON(t, mux, "/api/run-resume", `{"id":"sgt-done"}`)
	if w.Code == http.StatusOK {
		t.Errorf("status = 200, want a refusal; a passed run must not be resumed")
	}
	if !strings.Contains(strings.ToLower(w.Body.String()), "passed") {
		t.Errorf("refusal does not say why: %s", w.Body.String())
	}
}

// Resuming a run that is still executing would put two agents in one worktree.
func TestResumeRefusesARunningRun(t *testing.T) {
	mux, st, _ := dispatchFixture(t)
	if err := st.CreateRun(&store.RunRecord{
		ID: "sgt-live", Project: "o3", TaskID: "sgt-live", Status: "running",
	}); err != nil {
		t.Fatal(err)
	}

	w := postJSON(t, mux, "/api/run-resume", `{"id":"sgt-live"}`)
	if w.Code == http.StatusOK {
		t.Errorf("status = 200, want a refusal; a running run must not be resumed")
	}
}

func TestResumeRejectsAnUnknownRun(t *testing.T) {
	mux, _, _ := dispatchFixture(t)
	w := postJSON(t, mux, "/api/run-resume", `{"id":"sgt-nope"}`)
	if w.Code != http.StatusNotFound {
		t.Errorf("status = %d, want 404; body=%s", w.Code, w.Body.String())
	}
}

// ---------------------------------------------------------------------------
// dashboard-shows-delivery-history-and-quarantine (R5.6, bullet 4/4)
//
// Store.ListDeliveryHistory, ReplayDelivery and QuarantineDelivery were
// already covered directly in internal/store/delivery_test.go. These tests
// cover the HTTP surface that exposes them, which nothing outside
// internal/store called before this change.
// ---------------------------------------------------------------------------

// deliveryTestServer builds a server backed by a fresh store holding one run
// and one envelope on it, so a test can deliver to it without repeating the
// run/envelope bootstrap every time.
func deliveryTestServer(t *testing.T) (mux http.Handler, st *store.Store, runID, envelopeID string) {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "delivery.db")
	var err error
	st, err = store.Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	runID = "run-dh-1"
	if err := st.CreateRun(&store.RunRecord{
		ID: runID, Project: "test", TaskID: runID, Status: "running",
	}); err != nil {
		t.Fatal(err)
	}

	envelopeID = "env-dh-1"
	if err := st.RecordEnvelope(&store.EnvelopeRecord{
		ID: envelopeID, RunID: runID, Repo: "svc", Stage: "build", Summary: "test envelope",
		Type: "phase.completed", SchemaVersion: "1", Producer: "sergeant/test", CorrelationID: runID,
	}); err != nil {
		t.Fatal(err)
	}

	return NewServer(st, 0).Handler(), st, runID, envelopeID
}

func getJSONResponse(t *testing.T, mux http.Handler, path string) *httptest.ResponseRecorder {
	t.Helper()
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
	return w
}

// TestDeliveryHistoryReturnsRunsDeliveries covers spec scenario s-3: a GET
// naming a run with recorded deliveries returns them as a JSON array carrying
// state, attempt, error, error class and recovery instructions.
func TestDeliveryHistoryReturnsRunsDeliveries(t *testing.T) {
	mux, st, runID, envelopeID := deliveryTestServer(t)
	const consumer = "/fleet/run-dh-1/svc"

	if err := st.DeliverEnvelope(envelopeID, consumer, true, func() error { return nil }); err != nil {
		t.Fatalf("DeliverEnvelope: %v", err)
	}

	w := getJSONResponse(t, mux, "/api/delivery-history?run_id="+runID)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", w.Code, w.Body.String())
	}

	var got []store.DeliveryRecord
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("decoding response: %v; body=%s", err, w.Body.String())
	}
	if len(got) == 0 {
		t.Fatal("expected at least one delivery row, got none")
	}
	for _, d := range got {
		if d.EnvelopeID != envelopeID {
			t.Errorf("delivery envelope_id = %q, want %q", d.EnvelopeID, envelopeID)
		}
		if d.Consumer != consumer {
			t.Errorf("delivery consumer = %q, want %q", d.Consumer, consumer)
		}
	}
	last := got[len(got)-1]
	if last.State != "delivered" {
		t.Errorf("last delivery state = %q, want delivered", last.State)
	}
}

// TestDeliveryHistoryWithoutRunIDIsRefused covers spec scenario s-4: omitting
// run_id must answer 400, not a server error or an empty result that could be
// mistaken for "no deliveries".
func TestDeliveryHistoryWithoutRunIDIsRefused(t *testing.T) {
	mux, _, _, _ := deliveryTestServer(t)

	w := getJSONResponse(t, mux, "/api/delivery-history")
	if w.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want 400; body=%s", w.Code, w.Body.String())
	}
}

// TestDeliveryQuarantineSucceedsForDeadLetteredDelivery covers spec scenario
// s-5: a POST naming a dead-lettered (envelope_id, consumer) pair with a
// reason quarantines it, and a follow-up history request shows the
// quarantined state and reason.
func TestDeliveryQuarantineSucceedsForDeadLetteredDelivery(t *testing.T) {
	mux, st, runID, envelopeID := deliveryTestServer(t)
	const consumer = "/fleet/run-dh-1/dead-letter-target"

	// Exhaust retries (non-critical, so DeliverEnvelope itself does not error)
	// so the delivery reaches dead_letter.
	_ = st.DeliverEnvelope(envelopeID, consumer, false, func() error {
		return fmt.Errorf("permanent failure")
	})

	const reason = "poison message, will never succeed"
	body := fmt.Sprintf(`{"envelope_id":%q,"consumer":%q,"reason":%q}`, envelopeID, consumer, reason)
	w := postJSON(t, mux, "/api/delivery-quarantine", body)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", w.Code, w.Body.String())
	}

	var resp struct {
		Status     string `json:"status"`
		EnvelopeID string `json:"envelope_id"`
		Consumer   string `json:"consumer"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.Status != "quarantined" || resp.EnvelopeID != envelopeID || resp.Consumer != consumer {
		t.Errorf("response = %+v, want status=quarantined envelope_id=%q consumer=%q", resp, envelopeID, consumer)
	}

	hw := getJSONResponse(t, mux, "/api/delivery-history?run_id="+runID)
	var got []store.DeliveryRecord
	if err := json.Unmarshal(hw.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if len(got) == 0 {
		t.Fatal("expected delivery rows after quarantine, got none")
	}
	last := got[len(got)-1]
	if last.State != "quarantined" {
		t.Errorf("latest delivery state = %q, want quarantined", last.State)
	}
	if last.Error != reason {
		t.Errorf("latest delivery reason = %q, want %q", last.Error, reason)
	}
}

// TestDeliveryQuarantineRefusesNonDeadLetteredDelivery covers spec scenario
// s-6: a POST naming a pair whose latest state is not dead_letter is refused
// with an error, and no new delivery row is written.
func TestDeliveryQuarantineRefusesNonDeadLetteredDelivery(t *testing.T) {
	mux, st, _, envelopeID := deliveryTestServer(t)
	const consumer = "/fleet/run-dh-1/healthy-target"

	if err := st.DeliverEnvelope(envelopeID, consumer, true, func() error { return nil }); err != nil {
		t.Fatalf("DeliverEnvelope: %v", err)
	}

	before, err := st.ListDeliveryHistory(envelopeID, consumer)
	if err != nil {
		t.Fatal(err)
	}

	body := fmt.Sprintf(`{"envelope_id":%q,"consumer":%q,"reason":"trying anyway"}`, envelopeID, consumer)
	w := postJSON(t, mux, "/api/delivery-quarantine", body)
	if w.Code == http.StatusOK {
		t.Errorf("status = 200, want a refusal for a non-dead-lettered delivery")
	}
	if !strings.Contains(strings.ToLower(w.Body.String()), "dead_letter") {
		t.Errorf("refusal does not explain the guard: %s", w.Body.String())
	}

	after, err := st.ListDeliveryHistory(envelopeID, consumer)
	if err != nil {
		t.Fatal(err)
	}
	if len(after) != len(before) {
		t.Errorf("row count changed after a refused quarantine: before=%d after=%d", len(before), len(after))
	}
}
