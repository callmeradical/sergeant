package ui

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/callmeradical/sergeant/internal/store"
)

// terminalRunFixture is a server holding one running run, its intent and two
// pending bullets — the state every dispatch leaves behind before its run
// finishes.
func terminalRunFixture(t *testing.T, bulletStatuses ...string) (*Server, *store.Store) {
	t.Helper()

	st, err := store.Open(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	if err := st.CreateRun(&store.RunRecord{
		ID: "sgt-run", Project: "o3", TaskID: "sgt-run", IntentID: "sgt-run-intent", Status: "running",
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateIntent(&store.IntentRecord{
		ID: "sgt-run-intent", Project: "o3", Statement: "add stripe webhooks", Status: "in_progress",
	}); err != nil {
		t.Fatal(err)
	}
	for i, status := range bulletStatuses {
		if err := st.CreateBullet(&store.BulletRecord{
			ID:       fmt.Sprintf("sgt-run-b%d", i+1),
			IntentID: "sgt-run-intent",
			Repo:     "api",
			Position: i + 1,
			Status:   status,
		}); err != nil {
			t.Fatal(err)
		}
	}

	return NewServer(st, 0), st
}

func bulletStatuses(t *testing.T, st *store.Store, intentID string) []string {
	t.Helper()
	bullets, err := st.ListBulletsForIntent(intentID)
	if err != nil {
		t.Fatalf("listing bullets: %v", err)
	}
	out := make([]string, 0, len(bullets))
	for _, b := range bullets {
		out = append(out, b.Status)
	}
	return out
}

func intentStatus(t *testing.T, st *store.Store, intentID string) string {
	t.Helper()
	intent, err := st.GetIntent(intentID)
	if err != nil {
		t.Fatalf("loading intent: %v", err)
	}
	return intent.Status
}

func runStatus(t *testing.T, st *store.Store, runID string) string {
	t.Helper()
	run, err := st.GetRun(runID)
	if err != nil {
		t.Fatalf("loading run: %v", err)
	}
	return run.Status
}

// Passing gates means the work exists. The documented bullet lifecycle is
// pending → red → green → sealed → merged, and green is exactly "the work exists
// and is not delivered".
func TestAPassedRunMovesItsBulletsToGreen(t *testing.T) {
	srv, st := terminalRunFixture(t, "pending", "pending")

	srv.recordTerminalRun("sgt-run", "passed")

	if got := runStatus(t, st, "sgt-run"); got != "passed" {
		t.Fatalf("run status = %q, want passed", got)
	}
	for i, got := range bulletStatuses(t, st, "sgt-run-intent") {
		if got != "green" {
			t.Errorf("bullet %d status = %q, want green", i+1, got)
		}
	}
}

// Decision D6: sergeant never merges and never opens the pull request on this
// path. Passing gates says the work exists, not that it was submitted or
// delivered, so neither sealed nor merged is reachable from a run outcome.
func TestAPassedRunDoesNotSealOrMergeItsBullets(t *testing.T) {
	srv, st := terminalRunFixture(t, "pending", "pending")

	srv.recordTerminalRun("sgt-run", "passed")

	for i, got := range bulletStatuses(t, st, "sgt-run-intent") {
		if got == "sealed" || got == "merged" {
			t.Errorf("bullet %d status = %q; a passing run must not claim delivery", i+1, got)
		}
	}
}

// The D6 guarantee expressed as a test. An intent is satisfied only when every
// bullet is merged, and merged is only reachable from observed pull-request
// state, so no run outcome can declare the work delivered.
func TestAPassingRunLeavesItsIntentInProgress(t *testing.T) {
	srv, st := terminalRunFixture(t, "pending", "pending")

	srv.recordTerminalRun("sgt-run", "passed")

	if got := intentStatus(t, st, "sgt-run-intent"); got != "in_progress" {
		t.Errorf("intent status = %q after a passing run, want in_progress; sergeant never merges", got)
	}
}

func TestAFailedRunBlocksItsBulletsWithASynthesizedReason(t *testing.T) {
	srv, st := terminalRunFixture(t, "pending", "pending")

	srv.recordTerminalRun("sgt-run", "failed")

	bullets, err := st.ListBulletsForIntent("sgt-run-intent")
	if err != nil {
		t.Fatal(err)
	}
	for i, b := range bullets {
		if b.Status != "blocked" {
			t.Errorf("bullet %d status = %q, want blocked", i+1, b.Status)
		}
		if b.BlockedReason == "" {
			t.Errorf("bullet %d has no blocked reason; a human must never be left with blocked and no explanation", i+1)
		}
	}
	if got := intentStatus(t, st, "sgt-run-intent"); got != "in_progress" {
		t.Errorf("intent status = %q after a blocked run, want in_progress", got)
	}
}

// D5(b): when the agent's own envelope named why it could not proceed, that
// reason is recorded on the bullet verbatim, not the synthesized fallback.
func TestAFailedRunBlocksItsBulletsWithTheAgentReportedReason(t *testing.T) {
	srv, st := terminalRunFixture(t, "pending", "pending")

	if err := st.RecordEnvelope(&store.EnvelopeRecord{
		ID:            "env-1",
		RunID:         "sgt-run",
		Repo:          "api",
		Stage:         "build",
		Type:          "phase.completed",
		SchemaVersion: "1",
		Producer:      "sergeant/runner",
		CorrelationID: "sgt-run",
		Data:          []byte(`{"blocked_reason":"requirement is ambiguous; needs a human decision"}`),
	}); err != nil {
		t.Fatal(err)
	}

	srv.recordTerminalRun("sgt-run", "failed")

	bullets, err := st.ListBulletsForIntent("sgt-run-intent")
	if err != nil {
		t.Fatal(err)
	}
	for i, b := range bullets {
		if b.Status != "blocked" {
			t.Errorf("bullet %d status = %q, want blocked", i+1, b.Status)
		}
		if b.BlockedReason != "requirement is ambiguous; needs a human decision" {
			t.Errorf("bullet %d blocked reason = %q, want the agent-reported reason verbatim", i+1, b.BlockedReason)
		}
	}
}

// R4.4: a blocked reason is retained text like any other and must not carry a
// secret forward. The store's RecordEnvelope choke point redacts Data before
// it is ever persisted, so the reason recordTerminalRun reads back is already
// redacted — this asserts that redaction survives all the way to the bullet.
func TestABlockedReasonWithASecretIsRedactedOnTheBullet(t *testing.T) {
	srv, st := terminalRunFixture(t, "pending")

	secret := "sk-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOP"
	if err := st.RecordEnvelope(&store.EnvelopeRecord{
		ID:            "env-1",
		RunID:         "sgt-run",
		Repo:          "api",
		Stage:         "build",
		Type:          "phase.completed",
		SchemaVersion: "1",
		Producer:      "sergeant/runner",
		CorrelationID: "sgt-run",
		Data:          []byte(`{"blocked_reason":"needs a key: ` + secret + `"}`),
	}); err != nil {
		t.Fatal(err)
	}

	srv.recordTerminalRun("sgt-run", "failed")

	bullets, err := st.ListBulletsForIntent("sgt-run-intent")
	if err != nil {
		t.Fatal(err)
	}
	for i, b := range bullets {
		if strings.Contains(b.BlockedReason, secret) {
			t.Errorf("bullet %d blocked reason leaked the secret: %q", i+1, b.BlockedReason)
		}
		if !strings.Contains(b.BlockedReason, "[REDACTED]") {
			t.Errorf("bullet %d blocked reason was not redacted: %q", i+1, b.BlockedReason)
		}
	}
}

// An operator stopping a run has concluded nothing about the work. Recording
// failed would assert a judgment the operator did not make. This is the case a
// "not passed means failed" mapping gets wrong.
func TestACancelledRunLeavesItsBulletsUntouched(t *testing.T) {
	srv, st := terminalRunFixture(t, "pending", "pending")

	before, err := st.ListBulletsForIntent("sgt-run-intent")
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(10 * time.Millisecond)

	srv.recordTerminalRun("sgt-run", "cancelled")

	if got := runStatus(t, st, "sgt-run"); got != "cancelled" {
		t.Fatalf("run status = %q, want cancelled", got)
	}
	after, err := st.ListBulletsForIntent("sgt-run-intent")
	if err != nil {
		t.Fatal(err)
	}
	for i := range after {
		if after[i].Status != "pending" {
			t.Errorf("bullet %d status = %q after a cancellation, want pending", i+1, after[i].Status)
		}
		if !after[i].UpdatedAt.Equal(before[i].UpdatedAt) {
			t.Errorf("bullet %d was rewritten by a cancellation: updated_at %v became %v",
				i+1, before[i].UpdatedAt, after[i].UpdatedAt)
		}
	}
}

// A resumed run reaches the terminal path again, so the transition has to be
// safe to apply twice: the bullets hold the same status and nothing errors.
func TestReachingTheSameTerminalStatusTwiceIsANoOp(t *testing.T) {
	srv, st := terminalRunFixture(t, "pending", "pending")

	srv.recordTerminalRun("sgt-run", "passed")
	first, err := st.ListBulletsForIntent("sgt-run-intent")
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(10 * time.Millisecond)

	srv.recordTerminalRun("sgt-run", "passed")

	second, err := st.ListBulletsForIntent("sgt-run-intent")
	if err != nil {
		t.Fatal(err)
	}
	for i := range second {
		if second[i].Status != "green" {
			t.Errorf("bullet %d status = %q after a second terminal pass, want green", i+1, second[i].Status)
		}
		if !second[i].UpdatedAt.Equal(first[i].UpdatedAt) {
			t.Errorf("bullet %d was rewritten by a repeat: updated_at %v became %v",
				i+1, first[i].UpdatedAt, second[i].UpdatedAt)
		}
	}
	if got := intentStatus(t, st, "sgt-run-intent"); got != "in_progress" {
		t.Errorf("intent status = %q, want in_progress", got)
	}
}

// The transition lives in executeRun's own terminal path, which a dispatch and a
// resume both finish through. This test drives a real dispatch: the fixture's
// repo is not a git repository, so the engine refuses it and the run reaches
// failed by the same code path a passing run reaches passed by.
func TestADispatchedRunAdvancesItsBulletsThroughTheTerminalPath(t *testing.T) {
	mux, st, repoPath := dispatchFixture(t)

	const changeID = "add-stripe-webhooks"
	if err := os.MkdirAll(filepath.Join(repoPath, "openspec", "changes", changeID), 0o755); err != nil {
		t.Fatal(err)
	}

	w := postDispatch(t, mux, `{"project":"o3","brief":"add stripe webhooks","change_id":"`+changeID+`","repos":["svc"],"type":"feat"}`)
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
	if got := runStatus(t, st, resp.TaskID); got != "failed" {
		t.Fatalf("run reached %q; this test needs the engine to refuse the non-git fixture repo", got)
	}

	intentID := resp.TaskID + "-intent"
	bullets, err := st.ListBulletsForIntent(intentID)
	if err != nil {
		t.Fatal(err)
	}
	if len(bullets) == 0 {
		t.Fatal("dispatch wrote no bullets")
	}
	for i, b := range bullets {
		if b.Status != "blocked" {
			t.Errorf("bullet %d status = %q after the run failed, want blocked; the terminal path did not advance it", i+1, b.Status)
		}
		if b.BlockedReason == "" {
			t.Errorf("bullet %d has no blocked reason", i+1)
		}
	}
	if s := intentStatus(t, st, intentID); s != "in_progress" {
		t.Errorf("intent status = %q, want in_progress", s)
	}
}
