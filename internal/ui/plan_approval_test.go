package ui

// Tests for decisions D2 and D5(a): a dispatch whose repository decomposition
// was not stated explicitly by the caller must be recorded as a plan awaiting
// approval, not executed, until a human explicitly approves or rejects it.
//
// The no-repos-creates-a-proposed-plan scenario and the explicit-repos
// regression scenario are covered in server_test.go
// (TestDispatchWithNoReposCreatesAProposedPlanAndStartsNothing and
// TestDispatchPersistsItsIntentAndOneBulletPerTargetRepo, both of which this
// file's tests build on). This file covers listing, approval, rejection, their
// idempotency, and their refusal outside the "proposed" state.

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/callmeradical/sergeant/internal/store"
)

func doPlanAction(t *testing.T, mux http.Handler, method, path string) *httptest.ResponseRecorder {
	t.Helper()
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest(method, path, nil))
	return w
}

// proposeplan dispatches with no repos and returns the intent id the proposed
// plan was recorded under.
func proposePlan(t *testing.T, mux http.Handler, brief, changeID string) string {
	t.Helper()
	w := postDispatch(t, mux, `{"project":"o3","brief":"`+brief+`","change_id":"`+changeID+`"}`)
	if w.Code != http.StatusAccepted {
		t.Fatalf("propose dispatch = %d, want 202; body=%s", w.Code, w.Body.String())
	}
	var resp struct {
		IntentID string `json:"intent_id"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.IntentID == "" {
		t.Fatal("propose dispatch returned no intent_id")
	}
	return resp.IntentID
}

// Regression coverage for decision D2's carve-out: a caller that names its
// repositories explicitly is never gated by the proposal mechanism. This is
// the same claim TestDispatchPersistsItsIntentAndOneBulletPerTargetRepo makes;
// this copy names it directly against the plan-approval change.
func TestExplicitReposDispatchIsUnaffectedByPlanApproval(t *testing.T) {
	mux, st, repoPaths, _ := dispatchFixtureRepos(t, "alpha", "beta")
	const changeID = "add-stripe-webhooks"
	if err := os.MkdirAll(filepath.Join(repoPaths["alpha"], "openspec", "changes", changeID), 0o755); err != nil {
		t.Fatal(err)
	}

	w := postDispatch(t, mux, `{"project":"o3","brief":"add stripe webhooks","change_id":"`+changeID+`","repos":["alpha","beta"]}`)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (explicit repos bypass proposal); body=%s", w.Code, w.Body.String())
	}

	intents, err := st.ListIntentsForProject("o3")
	if err != nil {
		t.Fatal(err)
	}
	if len(intents) != 1 || intents[0].Status != "in_progress" {
		t.Fatalf("intents = %+v, want exactly one in_progress intent", intents)
	}
	bullets, err := st.ListBulletsForIntent(intents[0].ID)
	if err != nil {
		t.Fatal(err)
	}
	for _, b := range bullets {
		if b.Status != "pending" {
			t.Errorf("bullet %s status = %q, want pending", b.ID, b.Status)
		}
	}
}

// Decision D5(a): a plan awaiting approval must be listable, with its bullets,
// so a human can act on it. An intent that never went through the proposal
// path (explicit repos) must not appear in the listing.
func TestProposedPlansAreListableWithTheirBullets(t *testing.T) {
	mux, _, repoPaths, _ := dispatchFixtureRepos(t, "alpha", "beta")
	const changeID = "add-stripe-webhooks"
	if err := os.MkdirAll(filepath.Join(repoPaths["alpha"], "openspec", "changes", changeID), 0o755); err != nil {
		t.Fatal(err)
	}

	// No plans yet.
	w := doPlanAction(t, mux, http.MethodGet, "/api/plans")
	if w.Code != http.StatusOK {
		t.Fatalf("GET /api/plans = %d, want 200; body=%s", w.Code, w.Body.String())
	}
	var empty []planEntry
	if err := json.Unmarshal(w.Body.Bytes(), &empty); err != nil {
		t.Fatal(err)
	}
	if len(empty) != 0 {
		t.Fatalf("GET /api/plans with no proposals = %+v, want empty", empty)
	}

	intentID := proposePlan(t, mux, "add stripe webhooks", changeID)

	// An explicit-repos dispatch must not show up as a plan awaiting approval.
	explicit := postDispatch(t, mux, `{"project":"o3","brief":"unrelated work","change_id":"`+changeID+`","repos":["alpha"]}`)
	if explicit.Code != http.StatusOK {
		t.Fatalf("explicit-repos dispatch = %d, want 200; body=%s", explicit.Code, explicit.Body.String())
	}

	w = doPlanAction(t, mux, http.MethodGet, "/api/plans")
	if w.Code != http.StatusOK {
		t.Fatalf("GET /api/plans = %d, want 200; body=%s", w.Code, w.Body.String())
	}
	var plans []planEntry
	if err := json.Unmarshal(w.Body.Bytes(), &plans); err != nil {
		t.Fatal(err)
	}
	if len(plans) != 1 {
		t.Fatalf("GET /api/plans = %+v, want exactly 1 proposed plan", plans)
	}
	if plans[0].Intent.ID != intentID {
		t.Errorf("listed plan intent id = %q, want %q", plans[0].Intent.ID, intentID)
	}
	if plans[0].Intent.Status != "proposed" {
		t.Errorf("listed plan status = %q, want proposed", plans[0].Intent.Status)
	}
	if len(plans[0].Bullets) != 2 {
		t.Fatalf("listed plan bullets = %+v, want 2", plans[0].Bullets)
	}
	for _, b := range plans[0].Bullets {
		if b.Status != "proposed" {
			t.Errorf("listed bullet %s status = %q, want proposed", b.ID, b.Status)
		}
	}
}

// GET /api/bullets?intent_id= is a direct lookup with no run to resolve
// through — the substrate a proposed plan (which has no run yet) needs.
func TestBulletsEndpointAcceptsIntentIDDirectly(t *testing.T) {
	mux, _, repoPaths, _ := dispatchFixtureRepos(t, "alpha")
	const changeID = "add-stripe-webhooks"
	if err := os.MkdirAll(filepath.Join(repoPaths["alpha"], "openspec", "changes", changeID), 0o755); err != nil {
		t.Fatal(err)
	}

	intentID := proposePlan(t, mux, "add stripe webhooks", changeID)

	w := doPlanAction(t, mux, http.MethodGet, "/api/bullets?intent_id="+intentID)
	if w.Code != http.StatusOK {
		t.Fatalf("GET /api/bullets?intent_id= = %d, want 200; body=%s", w.Code, w.Body.String())
	}
	var bullets []store.BulletRecord
	if err := json.Unmarshal(w.Body.Bytes(), &bullets); err != nil {
		t.Fatal(err)
	}
	if len(bullets) != 1 || bullets[0].Repo != "alpha" || bullets[0].Status != "proposed" {
		t.Fatalf("bullets = %+v, want one proposed bullet for alpha", bullets)
	}

	// An intent with no bullets (or that does not exist) is an empty list, not
	// an error — it is a direct lookup with nothing to resolve through.
	w = doPlanAction(t, mux, http.MethodGet, "/api/bullets?intent_id=no-such-intent")
	if w.Code != http.StatusOK {
		t.Fatalf("GET /api/bullets?intent_id=no-such-intent = %d, want 200; body=%s", w.Code, w.Body.String())
	}
	var none []store.BulletRecord
	if err := json.Unmarshal(w.Body.Bytes(), &none); err != nil {
		t.Fatal(err)
	}
	if len(none) != 0 {
		t.Fatalf("bullets for an unknown intent = %+v, want empty", none)
	}
}

// Decision D2: approving a proposed plan is the only way its work begins, and
// it must run the same dispatch sequence an explicit-repos request runs —
// real run, real worktree, real branch.
func TestApprovingAProposedPlanStartsTheRealDispatchSequence(t *testing.T) {
	mux, st, repoPath := gitDispatchFixtureStandalone(t)
	const changeID = "add-stripe-webhooks"
	if err := os.MkdirAll(filepath.Join(repoPath, "openspec", "changes", changeID), 0o755); err != nil {
		t.Fatal(err)
	}

	intentID := proposePlan(t, mux, "add stripe webhooks", changeID)
	if got := intentStatus(t, st, intentID); got != "proposed" {
		t.Fatalf("intent status before approval = %q, want proposed", got)
	}

	w := doPlanAction(t, mux, http.MethodPost, "/api/plans/"+intentID+"/approve")
	if w.Code != http.StatusOK {
		t.Fatalf("approve = %d, want 200; body=%s", w.Code, w.Body.String())
	}
	var resp dispatchResp
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.TaskID == "" {
		t.Fatal("approve response carries no task_id; the dispatch sequence did not run")
	}

	// The approved plan's own intent and bullets transition out of "proposed",
	// per design.md, even though the dispatch sequence mints a fresh run and a
	// fresh intent of its own (the same thing an explicit-repos dispatch does).
	if got := intentStatus(t, st, intentID); got != "in_progress" {
		t.Errorf("approved plan intent status = %q, want in_progress", got)
	}
	for _, s := range bulletStatuses(t, st, intentID) {
		if s != "pending" {
			t.Errorf("approved plan bullet status = %q, want pending", s)
		}
	}

	waitForTerminalRun(t, st, resp.TaskID)

	root := configuredFleetRoot(t)
	worktrees := worktreesUnder(t, root)
	if len(worktrees) != 1 {
		t.Fatalf("fleet directory holds %d worktrees after approval, want 1: %v", len(worktrees), worktrees)
	}
	branches := runBranches(t, repoPath)
	if len(branches) != 1 {
		t.Fatalf("repo holds %d run branches after approval, want 1: %v", len(branches), branches)
	}
}

// Approving a plan must reuse its own intent for the dispatched run, not mint
// a second, disconnected one. Reusing createRunAndDispatch's normal
// intent-minting behavior unconditionally would leave the approved plan's
// original intent frozen forever at in_progress/pending — nothing ever
// advances it — while a second intent silently became the one actually
// tracked, doubling the dashboard's primary object (D8) for what a human
// considers one piece of work.
func TestApprovingAPlanDoesNotCreateASecondIntent(t *testing.T) {
	mux, st, repoPath := gitDispatchFixtureStandalone(t)
	const changeID = "add-stripe-webhooks"
	if err := os.MkdirAll(filepath.Join(repoPath, "openspec", "changes", changeID), 0o755); err != nil {
		t.Fatal(err)
	}

	intentID := proposePlan(t, mux, "add stripe webhooks", changeID)

	w := doPlanAction(t, mux, http.MethodPost, "/api/plans/"+intentID+"/approve")
	if w.Code != http.StatusOK {
		t.Fatalf("approve = %d, want 200; body=%s", w.Code, w.Body.String())
	}
	var resp dispatchResp
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	waitForTerminalRun(t, st, resp.TaskID)

	run, err := st.GetRun(resp.TaskID)
	if err != nil {
		t.Fatal(err)
	}
	if run.IntentID != intentID {
		t.Fatalf("dispatched run's intent id = %q, want the approved plan's own intent id %q — a second intent was created instead of reusing the approved one", run.IntentID, intentID)
	}

	intents, err := st.ListIntentsForProject("o3")
	if err != nil {
		t.Fatal(err)
	}
	if len(intents) != 1 {
		t.Fatalf("project holds %d intents after approval, want 1 (the approved plan's own): %+v", len(intents), intents)
	}
}

// Approval must reuse the exact change (and its repo) resolved at proposal
// time, not re-resolve a second time with different inputs. Review 020 found
// that handleApprovePlan called resolveChange(changeRepoPath, "", ...) —
// a literal empty change id — discarding whatever change_id the caller
// named at proposal time and silently scaffolding a second, different
// change from the brief instead of reusing the one already on disk.
func TestApprovingAPlanReusesTheOriginallyResolvedChangeNotASecondOne(t *testing.T) {
	mux, st, repoPath := gitDispatchFixtureStandalone(t)
	// The brief deliberately does NOT slugify to changeID (deriveChangeID
	// would turn it into "a-totally-different-brief-text"): if approval ever
	// re-resolves from intent.Statement with an empty change id instead of
	// reusing intent.ChangeID, it must derive and scaffold that different
	// id, which this test can then tell apart from reusing changeID.
	const changeID = "add-stripe-webhooks"
	changeDir := filepath.Join(repoPath, "openspec", "changes", changeID)
	if err := os.MkdirAll(changeDir, 0o755); err != nil {
		t.Fatal(err)
	}

	intentID := proposePlan(t, mux, "a totally different brief text", changeID)

	w := doPlanAction(t, mux, http.MethodPost, "/api/plans/"+intentID+"/approve")
	if w.Code != http.StatusOK {
		t.Fatalf("approve = %d, want 200; body=%s", w.Code, w.Body.String())
	}
	var resp dispatchResp
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	waitForTerminalRun(t, st, resp.TaskID)

	run, err := st.GetRun(resp.TaskID)
	if err != nil {
		t.Fatal(err)
	}
	if run.ChangeID != changeID {
		t.Errorf("dispatched run's change id = %q, want the originally proposed %q — approval re-resolved a different change instead of reusing it", run.ChangeID, changeID)
	}

	entries, err := os.ReadDir(filepath.Join(repoPath, "openspec", "changes"))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name() != changeID {
		names := make([]string, len(entries))
		for i, e := range entries {
			names[i] = e.Name()
		}
		t.Errorf("openspec/changes/ holds %v after approval, want exactly [%q] — a second change was scaffolded instead of reusing the original", names, changeID)
	}
}

// Rejecting a proposed plan ends it and starts nothing: no run is ever
// created, and the intent's bullets are left "proposed" — the intent's own
// terminal status is what makes them inert.
func TestRejectingAProposedPlanStartsNothing(t *testing.T) {
	mux, st, repoPaths, dbPath := dispatchFixtureRepos(t, "alpha", "beta")
	const changeID = "add-stripe-webhooks"
	if err := os.MkdirAll(filepath.Join(repoPaths["alpha"], "openspec", "changes", changeID), 0o755); err != nil {
		t.Fatal(err)
	}

	intentID := proposePlan(t, mux, "add stripe webhooks", changeID)

	w := doPlanAction(t, mux, http.MethodPost, "/api/plans/"+intentID+"/reject")
	if w.Code != http.StatusOK {
		t.Fatalf("reject = %d, want 200; body=%s", w.Code, w.Body.String())
	}

	if got := intentStatus(t, st, intentID); got != "abandoned" {
		t.Errorf("rejected plan intent status = %q, want abandoned", got)
	}
	for _, s := range bulletStatuses(t, st, intentID) {
		if s != "proposed" {
			t.Errorf("rejected plan bullet status = %q, want proposed (unchanged)", s)
		}
	}
	if n := countRows(t, dbPath, "runs"); n != 0 {
		t.Errorf("rejecting a proposed plan created %d run(s), want 0", n)
	}
}

// Approving an already-approved plan must be indistinguishable from a no-op:
// the caller cannot tell its request apart from a retry, so no second run may
// be created and no error is returned.
func TestApprovingAnAlreadyApprovedPlanIsIdempotent(t *testing.T) {
	mux, st, repoPaths, dbPath := dispatchFixtureRepos(t, "alpha")
	const changeID = "add-stripe-webhooks"
	if err := os.MkdirAll(filepath.Join(repoPaths["alpha"], "openspec", "changes", changeID), 0o755); err != nil {
		t.Fatal(err)
	}

	intentID := proposePlan(t, mux, "add stripe webhooks", changeID)

	first := doPlanAction(t, mux, http.MethodPost, "/api/plans/"+intentID+"/approve")
	if first.Code != http.StatusOK {
		t.Fatalf("first approve = %d, want 200; body=%s", first.Code, first.Body.String())
	}

	second := doPlanAction(t, mux, http.MethodPost, "/api/plans/"+intentID+"/approve")
	if second.Code != http.StatusOK {
		t.Fatalf("repeat approve = %d, want 200; body=%s", second.Code, second.Body.String())
	}

	if n := countRows(t, dbPath, "runs"); n != 1 {
		t.Errorf("repeat approval produced %d run(s), want 1", n)
	}
	if got := intentStatus(t, st, intentID); got != "in_progress" {
		t.Errorf("intent status after repeat approval = %q, want in_progress", got)
	}
}

// Rejecting an already-rejected plan must likewise be a no-op: the intent
// stays abandoned and the repeat is not an error.
func TestRejectingAnAlreadyRejectedPlanIsIdempotent(t *testing.T) {
	mux, st, repoPaths, _ := dispatchFixtureRepos(t, "alpha")
	const changeID = "add-stripe-webhooks"
	if err := os.MkdirAll(filepath.Join(repoPaths["alpha"], "openspec", "changes", changeID), 0o755); err != nil {
		t.Fatal(err)
	}

	intentID := proposePlan(t, mux, "add stripe webhooks", changeID)

	first := doPlanAction(t, mux, http.MethodPost, "/api/plans/"+intentID+"/reject")
	if first.Code != http.StatusOK {
		t.Fatalf("first reject = %d, want 200; body=%s", first.Code, first.Body.String())
	}
	second := doPlanAction(t, mux, http.MethodPost, "/api/plans/"+intentID+"/reject")
	if second.Code != http.StatusOK {
		t.Fatalf("repeat reject = %d, want 200; body=%s", second.Code, second.Body.String())
	}

	if got := intentStatus(t, st, intentID); got != "abandoned" {
		t.Errorf("intent status after repeat rejection = %q, want abandoned", got)
	}
}

// Approving a plan that was rejected is refused: "abandoned" is neither
// "proposed" nor the terminal state approval produces.
func TestApprovingAnAbandonedPlanIsRefused(t *testing.T) {
	mux, st, repoPaths, dbPath := dispatchFixtureRepos(t, "alpha")
	const changeID = "add-stripe-webhooks"
	if err := os.MkdirAll(filepath.Join(repoPaths["alpha"], "openspec", "changes", changeID), 0o755); err != nil {
		t.Fatal(err)
	}

	intentID := proposePlan(t, mux, "add stripe webhooks", changeID)
	if w := doPlanAction(t, mux, http.MethodPost, "/api/plans/"+intentID+"/reject"); w.Code != http.StatusOK {
		t.Fatalf("reject = %d, want 200; body=%s", w.Code, w.Body.String())
	}

	w := doPlanAction(t, mux, http.MethodPost, "/api/plans/"+intentID+"/approve")
	if w.Code != http.StatusConflict {
		t.Fatalf("approving an abandoned plan = %d, want 409; body=%s", w.Code, w.Body.String())
	}
	if got := intentStatus(t, st, intentID); got != "abandoned" {
		t.Errorf("intent status after refused approval = %q, want unchanged abandoned", got)
	}
	if n := countRows(t, dbPath, "runs"); n != 0 {
		t.Errorf("a refused approval created %d run(s), want 0", n)
	}
}

// Rejecting a plan that never went through the proposal path (an
// explicit-repos dispatch's intent starts "in_progress" directly) is refused:
// "in_progress" is neither "proposed" nor the terminal state rejection
// produces ("abandoned").
func TestRejectingAnInProgressPlanIsRefused(t *testing.T) {
	mux, st, repoPaths, _ := dispatchFixtureRepos(t, "alpha")
	const changeID = "add-stripe-webhooks"
	if err := os.MkdirAll(filepath.Join(repoPaths["alpha"], "openspec", "changes", changeID), 0o755); err != nil {
		t.Fatal(err)
	}

	w := postDispatch(t, mux, `{"project":"o3","brief":"add stripe webhooks","change_id":"`+changeID+`","repos":["alpha"]}`)
	if w.Code != http.StatusOK {
		t.Fatalf("explicit-repos dispatch = %d, want 200; body=%s", w.Code, w.Body.String())
	}
	var resp dispatchResp
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	intentID := resp.TaskID + "-intent"
	if got := intentStatus(t, st, intentID); got != "in_progress" {
		t.Fatalf("intent status = %q, want in_progress", got)
	}

	reject := doPlanAction(t, mux, http.MethodPost, "/api/plans/"+intentID+"/reject")
	if reject.Code != http.StatusConflict {
		t.Fatalf("rejecting an in_progress plan = %d, want 409; body=%s", reject.Code, reject.Body.String())
	}
	if got := intentStatus(t, st, intentID); got != "in_progress" {
		t.Errorf("intent status after refused rejection = %q, want unchanged in_progress", got)
	}
}

// Approving or rejecting an intent that does not exist is refused with 404,
// not treated as a no-op — there is no plan to be idempotent about.
func TestApproveAndRejectRefuseAnUnknownIntent(t *testing.T) {
	mux, _, _, _ := dispatchFixtureRepos(t, "alpha")

	if w := doPlanAction(t, mux, http.MethodPost, "/api/plans/no-such-intent/approve"); w.Code != http.StatusNotFound {
		t.Errorf("approving an unknown intent = %d, want 404; body=%s", w.Code, w.Body.String())
	}
	if w := doPlanAction(t, mux, http.MethodPost, "/api/plans/no-such-intent/reject"); w.Code != http.StatusNotFound {
		t.Errorf("rejecting an unknown intent = %d, want 404; body=%s", w.Code, w.Body.String())
	}
}
