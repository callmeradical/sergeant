package ui

// Tests for specs/work-type/spec.md (decision O2): a dispatch must state its
// work type from the fixed vocabulary feat/fix/refactor/docs/chore/test before
// any run, intent or worktree exists, the type is durably recorded on the run
// (or, for a proposed plan, the intent), and the dispatched branch is named
// <type>/<change-id> by naming.BranchName wherever the branch is created or
// referenced.

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/callmeradical/sergeant/internal/naming"
	"github.com/callmeradical/sergeant/internal/store"
)

// Scenario: A recognized type is accepted.
func TestDispatchWithARecognizedTypeIsAccepted(t *testing.T) {
	for _, typ := range []string{"feat", "fix", "refactor", "docs", "chore", "test"} {
		t.Run(typ, func(t *testing.T) {
			mux, _, repoPaths, _ := dispatchFixtureRepos(t, "svc")
			changeID := "change-for-" + typ
			if err := os.MkdirAll(filepath.Join(repoPaths["svc"], "openspec", "changes", changeID), 0o755); err != nil {
				t.Fatal(err)
			}

			body := dispatchBody(t, map[string]interface{}{
				"project": "o3", "brief": "add stripe webhooks",
				"change_id": changeID, "repos": []string{"svc"}, "type": typ,
			})
			w := postDispatch(t, mux, body)
			if w.Code != http.StatusOK {
				t.Fatalf("type %q: status = %d, want 200; body=%s", typ, w.Code, w.Body.String())
			}
		})
	}
}

// assertDispatchLeftNoTrace is the seam scenarios s-2 and s-3 both need: a
// refused dispatch must leave no run, no intent, no bullet, and no worktree —
// not merely answer a 4xx. Checking the bullets table directly (not through an
// intent) proves the stronger claim: a bullet with a dangling intent_id would
// be invisible to ListBulletsForIntent.
func assertDispatchLeftNoTrace(t *testing.T, st *store.Store, dbPath, fleetRoot string) {
	t.Helper()
	runs, err := st.ListRecentRuns(50)
	if err != nil {
		t.Fatal(err)
	}
	if len(runs) != 0 {
		t.Errorf("refused dispatch created %d run(s), want 0: %+v", len(runs), runs)
	}
	if n := countRows(t, dbPath, "intents"); n != 0 {
		t.Errorf("refused dispatch left %d intent(s) behind, want 0", n)
	}
	if n := countRows(t, dbPath, "bullets"); n != 0 {
		t.Errorf("refused dispatch left %d bullet(s) behind, want 0", n)
	}
	entries, err := os.ReadDir(fleetRoot)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Errorf("refused dispatch left %d entr(y/ies) under the fleet root, want 0: %v", len(entries), entries)
	}
}

// Scenario: A missing type is refused.
func TestDispatchWithNoTypeIsRefusedAndCreatesNothing(t *testing.T) {
	mux, st, repoPaths, dbPath := dispatchFixtureRepos(t, "svc")
	fleetRoot := t.TempDir()
	t.Setenv("SERGEANT_FLEET_DIR", fleetRoot)

	const changeID = "add-stripe-webhooks"
	if err := os.MkdirAll(filepath.Join(repoPaths["svc"], "openspec", "changes", changeID), 0o755); err != nil {
		t.Fatal(err)
	}

	body := dispatchBody(t, map[string]interface{}{
		"project": "o3", "brief": "add stripe webhooks",
		"change_id": changeID, "repos": []string{"svc"},
	})
	w := postDispatch(t, mux, body)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400; body=%s", w.Code, w.Body.String())
	}

	assertDispatchLeftNoTrace(t, st, dbPath, fleetRoot)
}

// Scenario: An unrecognized type is refused, naming the valid set.
func TestDispatchWithAnUnrecognizedTypeIsRefusedAndCreatesNothing(t *testing.T) {
	mux, st, repoPaths, dbPath := dispatchFixtureRepos(t, "svc")
	fleetRoot := t.TempDir()
	t.Setenv("SERGEANT_FLEET_DIR", fleetRoot)

	const changeID = "add-stripe-webhooks"
	if err := os.MkdirAll(filepath.Join(repoPaths["svc"], "openspec", "changes", changeID), 0o755); err != nil {
		t.Fatal(err)
	}

	body := dispatchBody(t, map[string]interface{}{
		"project": "o3", "brief": "add stripe webhooks",
		"change_id": changeID, "repos": []string{"svc"}, "type": "banana",
	})
	w := postDispatch(t, mux, body)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400; body=%s", w.Code, w.Body.String())
	}
	for _, want := range []string{"feat", "fix", "refactor", "docs", "chore", "test"} {
		if !strings.Contains(w.Body.String(), want) {
			t.Errorf("refusal does not name valid type %q: %s", want, w.Body.String())
		}
	}

	assertDispatchLeftNoTrace(t, st, dbPath, fleetRoot)
}

// Scenario: An executed dispatch's run records its type.
func TestExecutedDispatchRunRecordsItsType(t *testing.T) {
	mux, st, repoPaths, _ := dispatchFixtureRepos(t, "svc")
	const changeID = "add-stripe-webhooks"
	if err := os.MkdirAll(filepath.Join(repoPaths["svc"], "openspec", "changes", changeID), 0o755); err != nil {
		t.Fatal(err)
	}

	body := dispatchBody(t, map[string]interface{}{
		"project": "o3", "brief": "add stripe webhooks",
		"change_id": changeID, "repos": []string{"svc"}, "type": "fix",
	})
	w := postDispatch(t, mux, body)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", w.Code, w.Body.String())
	}
	var resp struct {
		TaskID string `json:"task_id"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}

	run, err := st.GetRun(resp.TaskID)
	if err != nil {
		t.Fatal(err)
	}
	if run.Type != "fix" {
		t.Errorf("run.Type = %q, want fix", run.Type)
	}
}

// Scenario: A proposed plan's intent records its type.
func TestProposedPlanIntentRecordsItsType(t *testing.T) {
	mux, st, repoPaths, _ := dispatchFixtureRepos(t, "svc")
	const changeID = "add-stripe-webhooks"
	if err := os.MkdirAll(filepath.Join(repoPaths["svc"], "openspec", "changes", changeID), 0o755); err != nil {
		t.Fatal(err)
	}

	body := dispatchBody(t, map[string]interface{}{
		"project": "o3", "brief": "add stripe webhooks",
		"change_id": changeID, "type": "docs",
	})
	w := postDispatch(t, mux, body)
	if w.Code != http.StatusAccepted {
		t.Fatalf("status = %d, want 202; body=%s", w.Code, w.Body.String())
	}
	var resp struct {
		IntentID string `json:"intent_id"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}

	intent, err := st.GetIntent(resp.IntentID)
	if err != nil {
		t.Fatal(err)
	}
	if intent.Type != "docs" {
		t.Errorf("intent.Type = %q, want docs", intent.Type)
	}
}

// Scenario: Approving a proposed plan reuses its recorded type — the run
// created for it records the plan's originally proposed type, not a
// re-stated or re-derived one.
func TestApprovingAPlanReusesItsRecordedType(t *testing.T) {
	mux, st, repoPaths, _ := dispatchFixtureRepos(t, "alpha")
	const changeID = "add-stripe-webhooks"
	if err := os.MkdirAll(filepath.Join(repoPaths["alpha"], "openspec", "changes", changeID), 0o755); err != nil {
		t.Fatal(err)
	}

	body := dispatchBody(t, map[string]interface{}{
		"project": "o3", "brief": "add stripe webhooks",
		"change_id": changeID, "type": "chore",
	})
	w := postDispatch(t, mux, body)
	if w.Code != http.StatusAccepted {
		t.Fatalf("propose dispatch = %d, want 202; body=%s", w.Code, w.Body.String())
	}
	var proposeResp struct {
		IntentID string `json:"intent_id"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &proposeResp); err != nil {
		t.Fatal(err)
	}

	aw := doPlanAction(t, mux, http.MethodPost, "/api/plans/"+proposeResp.IntentID+"/approve")
	if aw.Code != http.StatusOK {
		t.Fatalf("approve = %d, want 200; body=%s", aw.Code, aw.Body.String())
	}
	var resp dispatchResp
	if err := json.Unmarshal(aw.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}

	run, err := st.GetRun(resp.TaskID)
	if err != nil {
		t.Fatal(err)
	}
	if run.Type != "chore" {
		t.Errorf("approved run.Type = %q, want chore (the plan's originally proposed type, not re-derived)", run.Type)
	}
}

// gitDispatchFixtureStandaloneServer is gitDispatchFixtureStandalone but
// returns the *Server itself, not only its Handler, so a test can swap
// Server.GHPRCreate for a recording stub the way bulletApprovalFixture does.
func gitDispatchFixtureStandaloneServer(t *testing.T) (srv *Server, st *store.Store, repoPath string) {
	t.Helper()

	base := t.TempDir()
	cfgDir := filepath.Join(base, "config")
	if err := os.MkdirAll(cfgDir, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SERGEANT_CONFIG", cfgDir)
	t.Setenv("SERGEANT_FLEET_DIR", filepath.Join(base, "fleet"))

	repoPath = filepath.Join(base, "svc")
	initGitRepo(t, repoPath)

	projYAML := "name: o3\nrepos:\n" +
		"  - name: svc\n" +
		"    path: " + repoPath + "\n" +
		"    factory:\n" +
		"      pipeline: [test]\n" +
		"      gates:\n" +
		"        unit: \"true\"\n"
	if err := os.WriteFile(filepath.Join(cfgDir, "o3.yaml"), []byte(projYAML), 0o644); err != nil {
		t.Fatal(err)
	}

	var err error
	st, err = store.Open(filepath.Join(base, "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	return NewServer(st, 0), st, repoPath
}

// gitBranchExists reports whether repoPath has a local branch with this exact
// name — checked against real git, not a computed string.
func gitBranchExists(t *testing.T, repoPath, branch string) bool {
	t.Helper()
	err := exec.Command("git", "-C", repoPath, "show-ref", "--verify", "--quiet", "refs/heads/"+branch).Run()
	return err == nil
}

// Scenario: A dispatched branch is named by its type and change — asserted
// against the real git branch checked out in the worktree, not just a
// computed string.
func TestDispatchedBranchIsNamedByItsTypeAndChange(t *testing.T) {
	srv, st, repoPath := gitDispatchFixtureStandaloneServer(t)
	mux := srv.Handler()
	const changeID = "add-stripe-webhooks"
	if err := os.MkdirAll(filepath.Join(repoPath, "openspec", "changes", changeID), 0o755); err != nil {
		t.Fatal(err)
	}

	body := dispatchBody(t, map[string]interface{}{
		"project": "o3", "brief": "add stripe webhooks",
		"change_id": changeID, "repos": []string{"svc"}, "type": "fix",
	})
	w := postDispatch(t, mux, body)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", w.Code, w.Body.String())
	}
	var resp struct {
		TaskID string `json:"task_id"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	waitForTerminalRun(t, st, resp.TaskID)

	root := configuredFleetRoot(t)
	worktrees := worktreesUnder(t, root)
	if len(worktrees) != 1 {
		t.Fatalf("fleet directory holds %d worktrees, want 1: %v", len(worktrees), worktrees)
	}

	out, err := exec.Command("git", "-C", worktrees[0], "rev-parse", "--abbrev-ref", "HEAD").Output()
	if err != nil {
		t.Fatalf("reading worktree branch: %v", err)
	}
	want := naming.BranchName("fix", changeID)
	if got := strings.TrimSpace(string(out)); got != want {
		t.Errorf("worktree branch = %q, want %q", got, want)
	}
	if !gitBranchExists(t, repoPath, want) {
		t.Errorf("branch %q does not exist in the source repo %s", want, repoPath)
	}
}

// Scenario: Pull-request creation targets the same branch that was created —
// a seam recording what branch the provider's Create was invoked against,
// matching this project's established pattern (formerly Server.GHPRCreate,
// now the changerequest provider seam) for verifying gh call arguments.
func TestCreatePRTargetsTheExactBranchThatWasCreated(t *testing.T) {
	srv, st, repoPath := gitDispatchFixtureStandaloneServer(t)
	mux := srv.Handler()
	const changeID = "add-stripe-webhooks"
	if err := os.MkdirAll(filepath.Join(repoPath, "openspec", "changes", changeID), 0o755); err != nil {
		t.Fatal(err)
	}
	// A remote is required for handleCreatePR to actually invoke the
	// provider's Create rather than fall back to a "local://worktree/<branch>" URL.
	if out, err := exec.Command("git", "-C", repoPath, "remote", "add", "origin",
		"https://github.com/example/repo.git").CombinedOutput(); err != nil {
		t.Fatalf("adding remote: %v: %s", err, out)
	}

	body := dispatchBody(t, map[string]interface{}{
		"project": "o3", "brief": "add stripe webhooks",
		"change_id": changeID, "repos": []string{"svc"}, "type": "fix",
	})
	w := postDispatch(t, mux, body)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", w.Code, w.Body.String())
	}
	var resp struct {
		TaskID string `json:"task_id"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	waitForTerminalRun(t, st, resp.TaskID)

	run, err := st.GetRun(resp.TaskID)
	if err != nil || run.Status != "passed" {
		t.Fatalf("run = %+v, err=%v; want a passed run so its bullet is green and create-pr's seal guard clears", run, err)
	}
	// recordTerminalRun writes the run's terminal status and then advances its
	// bullet to green as two separate store writes (server.go's
	// recordTerminalRun), so a reader can observe "passed" for a brief window
	// before the bullet catches up. Wait for the bullet itself, not just the
	// run, before relying on create-pr's green guard clearing.
	waitForBulletStatus(t, st, run.IntentID, "green")

	fake := &fakeChangeRequestProvider{}
	installFakeGitHubProvider(t, fake)

	prBody := fmt.Sprintf(`{"run_id":%q,"project":"o3","repo":"svc","title":"t","body":"b"}`, resp.TaskID)
	pw := postJSON(t, mux, "/api/create-pr", prBody)
	if pw.Code != http.StatusOK {
		t.Fatalf("create-pr status = %d, want 200; body=%s", pw.Code, pw.Body.String())
	}

	want := naming.BranchName("fix", changeID)
	if fake.lastHead != want {
		t.Errorf("gh pr create was invoked with head %q, want %q (the branch actually created for this run)", fake.lastHead, want)
	}
	if !gitBranchExists(t, repoPath, want) {
		t.Errorf("branch %q does not exist in the source repo %s", want, repoPath)
	}

	var prResp struct {
		Branch string `json:"branch"`
	}
	if err := json.Unmarshal(pw.Body.Bytes(), &prResp); err != nil {
		t.Fatal(err)
	}
	if prResp.Branch != want {
		t.Errorf("create-pr response branch = %q, want %q", prResp.Branch, want)
	}
}
