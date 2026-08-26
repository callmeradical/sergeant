package ui

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/callmeradical/sergeant/internal/dag"
	"github.com/callmeradical/sergeant/internal/naming"
	"github.com/callmeradical/sergeant/internal/store"
)

// Requirement: a dispatch is idempotent under a caller-supplied key.
//
// Decision D10 adopts this from AHP's runAutomation, which is idempotent by
// requestId and returns the existing run on repeat. The guarantee is enforced by
// a unique index on runs.request_id, so these tests assert what a caller
// observes: one run, one worktree, one branch, and a response it cannot tell
// apart from the original.

// dispatchBody builds a dispatch request body. Marshalled rather than
// concatenated so a key containing JSON punctuation reaches the handler as data.
func dispatchBody(t *testing.T, fields map[string]interface{}) string {
	t.Helper()
	b, err := json.Marshal(fields)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

type dispatchResp struct {
	Status        string `json:"status"`
	TaskID        string `json:"task_id"`
	Project       string `json:"project"`
	ChangeID      string `json:"change_id"`
	ChangeDir     string `json:"change_dir"`
	ChangeRepo    string `json:"change_repo"`
	ChangeCreated bool   `json:"change_created"`
}

// Scenario: A repeated key returns the original run.
//
// The store must hold exactly one run for the key, and the second response must
// carry the run id the first created.
func TestDispatchWithARepeatedRequestIDReturnsTheOriginalRun(t *testing.T) {
	mux, st, repoPath := dispatchFixture(t)
	const changeID = "add-stripe-webhooks"
	if err := os.MkdirAll(filepath.Join(repoPath, "openspec", "changes", changeID), 0o755); err != nil {
		t.Fatal(err)
	}

	body := dispatchBody(t, map[string]interface{}{
		"project": "o3", "brief": "add stripe webhooks",
		"change_id": changeID, "request_id": "retry-me", "repos": []string{"svc"}, "type": "feat",
	})

	first := postDispatch(t, mux, body)
	if first.Code != http.StatusOK {
		t.Fatalf("first dispatch = %d, want 200; body=%s", first.Code, first.Body.String())
	}
	second := postDispatch(t, mux, body)
	if second.Code != http.StatusOK {
		t.Fatalf("repeat dispatch = %d, want 200; body=%s", second.Code, second.Body.String())
	}

	var firstResp, secondResp dispatchResp
	if err := json.Unmarshal(first.Body.Bytes(), &firstResp); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(second.Body.Bytes(), &secondResp); err != nil {
		t.Fatal(err)
	}

	if secondResp.TaskID != firstResp.TaskID {
		t.Errorf("repeat returned task_id %q, want the original %q", secondResp.TaskID, firstResp.TaskID)
	}

	runs, err := st.ListRecentRuns(50)
	if err != nil {
		t.Fatal(err)
	}
	if len(runs) != 1 {
		t.Fatalf("store holds %d runs for one request id, want 1: %+v", len(runs), runs)
	}
	if runs[0].ID != firstResp.TaskID {
		t.Errorf("stored run id = %q, want %q", runs[0].ID, firstResp.TaskID)
	}
	if runs[0].RequestID != "retry-me" {
		t.Errorf("stored run request id = %q, want retry-me", runs[0].RequestID)
	}
}

// Scenario: A repeated key creates no side effects — the caller cannot tell the
// difference, so it needs no branch.
//
// Every key of the response, and its value where the value is not the run's own
// identity, must match the original. A distinguishing status such as "duplicate"
// would force every caller to handle two shapes.
func TestARepeatedDispatchIsIndistinguishableFromTheOriginal(t *testing.T) {
	mux, _, repoPath := dispatchFixture(t)
	const changeID = "add-stripe-webhooks"
	if err := os.MkdirAll(filepath.Join(repoPath, "openspec", "changes", changeID), 0o755); err != nil {
		t.Fatal(err)
	}

	body := dispatchBody(t, map[string]interface{}{
		"project": "o3", "brief": "add stripe webhooks",
		"change_id": changeID, "request_id": "retry-me", "repos": []string{"svc"}, "type": "feat",
	})

	first := postDispatch(t, mux, body)
	second := postDispatch(t, mux, body)
	if first.Code != second.Code {
		t.Fatalf("repeat status %d differs from original %d", second.Code, first.Code)
	}

	var a, b map[string]interface{}
	if err := json.Unmarshal(first.Body.Bytes(), &a); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(second.Body.Bytes(), &b); err != nil {
		t.Fatal(err)
	}

	if got, want := keysOf(b), keysOf(a); !equalStrings(got, want) {
		t.Errorf("repeat response keys = %v, want %v", got, want)
	}
	for _, k := range keysOf(a) {
		if a[k] != b[k] {
			t.Errorf("repeat response %s = %v, want %v", k, b[k], a[k])
		}
	}
	if b["status"] != "dispatched" {
		t.Errorf("repeat status field = %v, want dispatched", b["status"])
	}
	// A repeat scaffolded nothing, so it must not claim it created a change.
	if b["change_created"] != false {
		t.Errorf("repeat claims change_created = %v, want false", b["change_created"])
	}
}

// Scenario: A repeated key within the same second still deduplicates.
//
// Run ids used to come from time.Now().Unix(), so two dispatches inside one
// second collided on the primary key and produced one run by accident. Accidental
// collision is a different failure from deliberate deduplication: this test
// therefore also proves the ids are distinct, so the single run is the product of
// the key rather than of a clock with one-second resolution.
func TestDispatchWithARepeatedRequestIDInsideOneSecondDeduplicates(t *testing.T) {
	mux, st, repoPath := dispatchFixture(t)
	const changeID = "add-stripe-webhooks"
	if err := os.MkdirAll(filepath.Join(repoPath, "openspec", "changes", changeID), 0o755); err != nil {
		t.Fatal(err)
	}

	body := dispatchBody(t, map[string]interface{}{
		"project": "o3", "brief": "add stripe webhooks",
		"change_id": changeID, "request_id": "retry-me", "repos": []string{"svc"}, "type": "feat",
	})

	start := time.Now()
	first := postDispatch(t, mux, body)
	second := postDispatch(t, mux, body)
	elapsed := time.Since(start)

	if first.Code != http.StatusOK || second.Code != http.StatusOK {
		t.Fatalf("dispatches = %d and %d, want 200 and 200; bodies=%s | %s",
			first.Code, second.Code, first.Body.String(), second.Body.String())
	}
	if elapsed >= time.Second {
		t.Fatalf("the two dispatches took %v, so this test did not exercise the same-second case", elapsed)
	}

	runs, err := st.ListRecentRuns(50)
	if err != nil {
		t.Fatal(err)
	}
	if len(runs) != 1 {
		t.Fatalf("store holds %d runs after a same-second repeat, want 1: %+v", len(runs), runs)
	}

	// handleDispatch runs the actual pipeline in a background goroutine.
	// dispatchFixture's t.Setenv(SERGEANT_CONFIG/SERGEANT_FLEET_DIR) is
	// process-global, so a goroutine this test leaves running past its own
	// return observes whatever a LATER test's dispatchFixture has since set
	// those variables to, and writes to this test's already-closed store —
	// "sql: database is closed" noise here, but real interference with
	// whichever later test happens to be running concurrently. Waiting for
	// this run to finish before returning closes the leak at its source.
	waitForTerminalRun(t, st, runs[0].ID)
}

// Scenario: An omitted key remains valid.
//
// Two absent keys must never deduplicate against each other, and the two runs
// must be distinct rather than one run written twice. The two dispatches land in
// the same second, which is exactly the case a second-granularity run id used to
// collapse.
func TestDispatchWithoutARequestIDCreatesANewRunEachTime(t *testing.T) {
	mux, st, repoPath := dispatchFixture(t)
	const changeID = "add-stripe-webhooks"
	if err := os.MkdirAll(filepath.Join(repoPath, "openspec", "changes", changeID), 0o755); err != nil {
		t.Fatal(err)
	}

	body := dispatchBody(t, map[string]interface{}{
		"project": "o3", "brief": "add stripe webhooks", "change_id": changeID, "repos": []string{"svc"}, "type": "feat",
	})

	start := time.Now()
	first := postDispatch(t, mux, body)
	second := postDispatch(t, mux, body)
	elapsed := time.Since(start)

	if first.Code != http.StatusOK {
		t.Fatalf("first dispatch = %d, want 200; body=%s", first.Code, first.Body.String())
	}
	if second.Code != http.StatusOK {
		t.Fatalf("second keyless dispatch = %d, want 200; body=%s", second.Code, second.Body.String())
	}
	if elapsed >= time.Second {
		t.Fatalf("the two dispatches took %v, so this test did not exercise the same-second case", elapsed)
	}

	var a, b dispatchResp
	if err := json.Unmarshal(first.Body.Bytes(), &a); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(second.Body.Bytes(), &b); err != nil {
		t.Fatal(err)
	}
	if a.TaskID == b.TaskID {
		t.Errorf("two keyless dispatches share the run id %q; a run id must not come from a one-second clock", a.TaskID)
	}

	runs, err := st.ListRecentRuns(50)
	if err != nil {
		t.Fatal(err)
	}
	if len(runs) != 2 {
		t.Fatalf("store holds %d runs after two keyless dispatches, want 2: %+v", len(runs), runs)
	}

	// Each keyless run claims no key, rather than an empty key it shares with the
	// other. Sharing one would mean the absent case was stored as ''.
	for _, r := range runs {
		if r.RequestID != "" {
			t.Errorf("keyless run %s reports request id %q, want empty", r.ID, r.RequestID)
		}
	}

	// Two runs means two intents: a dispatch that creates a run creates the intent
	// it serves, and neither may be shared.
	intents, err := st.ListIntentsForProject("o3")
	if err != nil {
		t.Fatal(err)
	}
	if len(intents) != 2 {
		t.Fatalf("store holds %d intents after two keyless dispatches, want 2: %+v", len(intents), intents)
	}

	// See the matching comment in TestDispatchWithARepeatedRequestIDInsideOneSecondDeduplicates:
	// wait for both background dispatch goroutines to finish before this
	// test's own store closes, so they cannot leak into a later test's
	// dispatchFixture (which reassigns the same process-global
	// SERGEANT_CONFIG/SERGEANT_FLEET_DIR env vars this test used).
	waitForTerminalRun(t, st, a.TaskID)
	waitForTerminalRun(t, st, b.TaskID)
}

// Scenario: A repeated key creates no side effects — the domain records half.
//
// A repeat must not leave an orphaned intent or bullet behind. Writing the intent
// before claiming the key would do exactly that: the key would suppress the run
// and the worktree while the planning rows accumulated one set per retry, and
// decision D8 makes the intent the dashboard's primary noun, so the operator
// would see a duplicate for every retry.
func TestARepeatedRequestIDWritesNoSecondIntentOrBullet(t *testing.T) {
	mux, st, repoPaths, dbPath := dispatchFixtureRepos(t, "api", "web")
	const changeID = "add-stripe-webhooks"
	if err := os.MkdirAll(filepath.Join(repoPaths["api"], "openspec", "changes", changeID), 0o755); err != nil {
		t.Fatal(err)
	}

	body := dispatchBody(t, map[string]interface{}{
		"project": "o3", "brief": "add stripe webhooks", "change_id": changeID,
		"repos": []string{"api", "web"}, "request_id": "retry-me", "type": "feat",
	})

	if w := postDispatch(t, mux, body); w.Code != http.StatusOK {
		t.Fatalf("first dispatch = %d; body=%s", w.Code, w.Body.String())
	}
	for i := 0; i < 3; i++ {
		if w := postDispatch(t, mux, body); w.Code != http.StatusOK {
			t.Fatalf("repeat %d = %d; body=%s", i+1, w.Code, w.Body.String())
		}
	}

	intents, err := st.ListIntentsForProject("o3")
	if err != nil {
		t.Fatal(err)
	}
	if len(intents) != 1 {
		t.Fatalf("store holds %d intents after three repeats, want 1: %+v", len(intents), intents)
	}

	// Counted against the table rather than through the intent: a bullet written
	// under an intent id that no longer matches any run would be invisible to
	// ListBulletsForIntent, and an orphan is precisely what this asserts against.
	if got := countRows(t, dbPath, "bullets"); got != 2 {
		t.Errorf("bullets table holds %d rows after three repeats, want 2 (one per target repo)", got)
	}
	if got := countRows(t, dbPath, "intents"); got != 1 {
		t.Errorf("intents table holds %d rows after three repeats, want 1", got)
	}
	if got := countRows(t, dbPath, "runs"); got != 1 {
		t.Errorf("runs table holds %d rows after three repeats, want 1", got)
	}

	bullets, err := st.ListBulletsForIntent(intents[0].ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(bullets) != 2 {
		t.Fatalf("intent holds %d bullets, want 2: %+v", len(bullets), bullets)
	}
}

// Scenario: A repeated key creates no side effects — the execution half.
//
// This is the point of the key. The repeat must return before a worktree, a
// branch or an agent exists, so the fleet directory holds exactly one worktree
// and the operator's checkout holds exactly one run branch.
func TestARepeatedRequestIDCreatesNoSecondWorktreeBranchOrAgent(t *testing.T) {
	mux, st, repoPath := gitDispatchFixtureStandalone(t)
	const changeID = "add-stripe-webhooks"
	if err := os.MkdirAll(filepath.Join(repoPath, "openspec", "changes", changeID), 0o755); err != nil {
		t.Fatal(err)
	}

	body := dispatchBody(t, map[string]interface{}{
		"project": "o3", "brief": "add stripe webhooks",
		"change_id": changeID, "request_id": "retry-me", "repos": []string{"svc"}, "type": "feat",
	})

	first := postDispatch(t, mux, body)
	if first.Code != http.StatusOK {
		t.Fatalf("first dispatch = %d, want 200; body=%s", first.Code, first.Body.String())
	}
	// The retry arrives while the first run is still in flight, which is the case
	// a caller actually retries in.
	second := postDispatch(t, mux, body)
	if second.Code != http.StatusOK {
		t.Fatalf("repeat dispatch = %d, want 200; body=%s", second.Code, second.Body.String())
	}

	var resp dispatchResp
	if err := json.Unmarshal(first.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	waitForTerminalRun(t, st, resp.TaskID)

	root := configuredFleetRoot(t)
	worktrees := worktreesUnder(t, root)
	if len(worktrees) != 1 {
		t.Fatalf("fleet directory holds %d worktrees, want 1: %v", len(worktrees), worktrees)
	}
	if want := dag.FleetDir(resp.TaskID, "svc"); worktrees[0] != want {
		t.Errorf("worktree = %q, want %q", worktrees[0], want)
	}

	branches := runBranches(t, repoPath)
	if len(branches) != 1 {
		t.Fatalf("repo holds %d run branches, want 1: %v", len(branches), branches)
	}
	if want := naming.BranchName("feat", changeID); branches[0] != want {
		t.Errorf("run branch = %q, want %q", branches[0], want)
	}

	// One run executed, so exactly one run id appears in the phase record. A
	// second execution of the same brief would show up here even if it had reused
	// the first run's worktree.
	phased := runIDsWithPhases(t, st)
	if len(phased) != 1 {
		t.Errorf("%d runs recorded phases, want 1: %v", len(phased), phased)
	}
}

// The guarantee has to survive concurrent POSTs, which is the whole reason it
// lives in a unique index instead of in the handler. A check-then-insert would
// let every one of these callers observe an unused key and proceed, so this test
// passes only because the database refuses the losing inserts.
//
// Run this with -race to also cover the handler's own shared state.
func TestConcurrentDispatchesWithOneRequestIDProduceOneRun(t *testing.T) {
	mux, st, repoPath := dispatchFixture(t)
	const changeID = "add-stripe-webhooks"
	if err := os.MkdirAll(filepath.Join(repoPath, "openspec", "changes", changeID), 0o755); err != nil {
		t.Fatal(err)
	}

	body := dispatchBody(t, map[string]interface{}{
		"project": "o3", "brief": "add stripe webhooks",
		"change_id": changeID, "request_id": "retry-me", "repos": []string{"svc"}, "type": "feat",
	})

	const callers = 8
	var wg sync.WaitGroup
	codes := make([]int, callers)
	taskIDs := make([]string, callers)
	start := make(chan struct{})

	for i := 0; i < callers; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			<-start
			w := httptest.NewRecorder()
			mux.ServeHTTP(w, httptest.NewRequest("POST", "/api/dispatch", strings.NewReader(body)))
			codes[i] = w.Code
			var resp dispatchResp
			if err := json.Unmarshal(w.Body.Bytes(), &resp); err == nil {
				taskIDs[i] = resp.TaskID
			}
		}(i)
	}
	close(start)
	wg.Wait()

	for i, c := range codes {
		if c != http.StatusOK {
			t.Errorf("caller %d = %d, want 200", i, c)
		}
	}
	// Every caller is told about the same run, so none of them can believe it owns
	// work that another one is doing.
	for i, id := range taskIDs {
		if id == "" {
			t.Errorf("caller %d received no task_id", i)
			continue
		}
		if id != taskIDs[0] {
			t.Errorf("caller %d received task_id %q, caller 0 received %q", i, id, taskIDs[0])
		}
	}

	runs, err := st.ListRecentRuns(50)
	if err != nil {
		t.Fatal(err)
	}
	if len(runs) != 1 {
		t.Fatalf("%d concurrent dispatches with one key produced %d runs, want 1: %+v",
			callers, len(runs), runs)
	}
	intents, err := st.ListIntentsForProject("o3")
	if err != nil {
		t.Fatal(err)
	}
	if len(intents) != 1 {
		t.Fatalf("%d concurrent dispatches produced %d intents, want 1", callers, len(intents))
	}
}

// gitDispatchFixtureStandalone is dispatchFixture with a real git repository, so
// a dispatch actually reaches prepareWorktree. dispatchFixture's repos are plain
// directories, which the engine refuses to isolate, so no worktree is ever
// created there and a worktree count would pass vacuously.
//
// The repo's factory declares a deterministic gate and no agent phase, so the run
// completes without spawning an agent CLI that may not be installed.
//
// This variant differs from gitDispatchFixture (in progress_test.go) in that it
// creates its own temp directory and repo; progress_test.go's version accepts
// pre-created paths so the test can write spec files before the server starts.
func gitDispatchFixtureStandalone(t *testing.T) (mux http.Handler, st *store.Store, repoPath string) {
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

	return NewServer(st, 0).Handler(), st, repoPath
}

func initGitRepo(t *testing.T, dir string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	gitIn(t, dir, "init", "-q", "-b", "main")
	gitIn(t, dir, "config", "user.name", "sergeant-test")
	gitIn(t, dir, "config", "user.email", "sergeant-test@example.com")
	if err := os.WriteFile(filepath.Join(dir, "README.md"), []byte("seed\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitIn(t, dir, "add", ".")
	gitIn(t, dir, "commit", "-q", "-m", "seed")
}

func gitIn(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	cmd.Env = append(os.Environ(),
		"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@example.com",
		"GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@example.com",
	)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %s: %v: %s", strings.Join(args, " "), err, out)
	}
}

// worktreesUnder lists every git worktree below root. A worktree is identified by
// its .git entry, which git writes as a file pointing back at the parent repo, so
// this counts real worktrees rather than any directory a run happened to create —
// the handoff directory beside it is not one.
func worktreesUnder(t *testing.T, root string) []string {
	t.Helper()
	var found []string
	runDirs, err := os.ReadDir(root)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		t.Fatal(err)
	}
	for _, runDir := range runDirs {
		if !runDir.IsDir() {
			continue
		}
		inner, err := os.ReadDir(filepath.Join(root, runDir.Name()))
		if err != nil {
			t.Fatal(err)
		}
		for _, d := range inner {
			if !d.IsDir() {
				continue
			}
			p := filepath.Join(root, runDir.Name(), d.Name())
			if _, err := os.Stat(filepath.Join(p, ".git")); err == nil {
				found = append(found, p)
			}
		}
	}
	sort.Strings(found)
	return found
}

// runBranches lists the feat/* branches in a repository (every test dispatch
// in this file names "feat" as its type). One per executed run; a second one
// would mean the repeat started work.
func runBranches(t *testing.T, repoPath string) []string {
	t.Helper()
	out, err := exec.Command("git", "-C", repoPath, "for-each-ref",
		"--format=%(refname:short)", "refs/heads/feat").Output()
	if err != nil {
		t.Fatalf("listing run branches: %v", err)
	}
	var branches []string
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if line != "" {
			branches = append(branches, line)
		}
	}
	sort.Strings(branches)
	return branches
}

// runIDsWithPhases is the set of runs that recorded any phase, which is the
// store's evidence of work actually having executed.
func runIDsWithPhases(t *testing.T, st *store.Store) []string {
	t.Helper()
	runs, err := st.ListRecentRuns(50)
	if err != nil {
		t.Fatal(err)
	}
	var withPhases []string
	for _, r := range runs {
		phases, err := st.ListPhasesForRun(r.ID)
		if err != nil {
			t.Fatal(err)
		}
		if len(phases) > 0 {
			withPhases = append(withPhases, r.ID)
		}
	}
	sort.Strings(withPhases)
	return withPhases
}

// waitForTerminalRun blocks until a run leaves the running state, so an assertion
// about the filesystem is not racing the dispatch goroutine that writes to it.
func waitForTerminalRun(t *testing.T, st *store.Store, runID string) {
	t.Helper()
	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		run, err := st.GetRun(runID)
		if err != nil {
			t.Fatalf("reading run %s: %v", runID, err)
		}
		switch run.Status {
		case "passed", "failed", "cancelled":
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("run %s did not reach a terminal status within the deadline", runID)
}

// waitForBulletStatus polls until every bullet of intentID reports status, so
// a test does not race recordTerminalRun's second, separate write (the bullet
// advance that follows the run's terminal-status write).
func waitForBulletStatus(t *testing.T, st *store.Store, intentID, status string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		bullets, err := st.ListBulletsForIntent(intentID)
		if err != nil {
			t.Fatalf("listing bullets for intent %s: %v", intentID, err)
		}
		if len(bullets) > 0 {
			allMatch := true
			for _, b := range bullets {
				if b.Status != status {
					allMatch = false
					break
				}
			}
			if allMatch {
				return
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("intent %s's bullets did not reach status %q within the deadline", intentID, status)
}

func keysOf(m map[string]interface{}) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
