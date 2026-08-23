package ui

// Tests for the server-layer behaviour introduced by
// change startup-reconciles-orphaned-runs:
//
//   - an interrupted run is accepted by /api/run-resume
//   - /api/runs serves interrupted with resumable=true
//   - a phase reconciled to interrupted is NOT listed as skipped on resume

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/callmeradical/sergeant/internal/store"
)

// TestInterruptedRunIsAcceptedByResume: the resume endpoint must accept an
// interrupted run. Before this change it stayed "running" forever and resume
// refused it with "is running and cannot be resumed".
func TestInterruptedRunIsAcceptedByResume(t *testing.T) {
	mux, st, _ := dispatchFixture(t)

	if err := st.CreateRun(&store.RunRecord{
		ID: "sgt-interrupted", Project: "o3", TaskID: "sgt-interrupted",
		Brief: "finish the interrupted work", Status: "interrupted",
	}); err != nil {
		t.Fatal(err)
	}

	w := postJSON(t, mux, "/api/run-resume", `{"id":"sgt-interrupted"}`)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; an interrupted run must be resumable; body=%s",
			w.Code, w.Body.String())
	}
}

// TestInterruptedRunIsServedResumableTrue: GET /api/runs must serve an
// interrupted run with resumable=true, consistent with what the resume endpoint
// accepts. The dashboard derives its Resume button from this field.
func TestInterruptedRunIsServedResumableTrue(t *testing.T) {
	mux, st, _ := dispatchFixture(t)

	if err := st.CreateRun(&store.RunRecord{
		ID: "sgt-int2", Project: "o3", TaskID: "sgt-int2",
		Brief: "b", Status: "interrupted",
	}); err != nil {
		t.Fatal(err)
	}

	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest("GET", "/api/runs", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("GET /api/runs status = %d; body=%s", w.Code, w.Body.String())
	}

	var runs []struct {
		ID        string `json:"id"`
		Status    string `json:"status"`
		Resumable bool   `json:"resumable"`
	}
	if err := json.NewDecoder(w.Body).Decode(&runs); err != nil {
		t.Fatalf("decoding runs: %v", err)
	}

	var found bool
	for _, r := range runs {
		if r.ID != "sgt-int2" {
			continue
		}
		found = true
		if !r.Resumable {
			t.Errorf("interrupted run served resumable=false; must be true so the dashboard shows the Resume button")
		}
		if r.Status != "interrupted" {
			t.Errorf("status = %q, want interrupted", r.Status)
		}
	}
	if !found {
		t.Error("run sgt-int2 not found in GET /api/runs response")
	}
}

// TestReconciledPhaseIsNotListedAsSkippedOnResume: a phase that
// ReconcileOrphanedRuns moved from running to interrupted must not appear in
// the resume response's "skipped" list. Resume skips only phases holding
// "passed"; an interrupted phase must be re-executed.
func TestReconciledPhaseIsNotListedAsSkippedOnResume(t *testing.T) {
	mux, st, _ := dispatchFixture(t)

	if err := st.CreateRun(&store.RunRecord{
		ID: "sgt-reconciled", Project: "o3", TaskID: "sgt-reconciled",
		Brief: "interrupted work", Status: "interrupted",
	}); err != nil {
		t.Fatal(err)
	}

	// Phases as ReconcileOrphanedRuns would leave them.
	if err := st.RecordPhase(&store.PhaseRecord{
		ID: "ph-interrupted", RunID: "sgt-reconciled", Repo: "svc",
		Name: "build", Kind: "agent", Status: "interrupted",
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.RecordPhase(&store.PhaseRecord{
		ID: "ph-passed", RunID: "sgt-reconciled", Repo: "svc",
		Name: "test", Kind: "code", Status: "passed",
	}); err != nil {
		t.Fatal(err)
	}

	w := postJSON(t, mux, "/api/run-resume", `{"id":"sgt-reconciled"}`)
	if w.Code != http.StatusOK {
		t.Fatalf("resume status = %d; body=%s", w.Code, w.Body.String())
	}

	// The response body must not name "build" as skipped.
	// It should name "test" as skipped (it passed) but not "build" (interrupted).
	body := w.Body.String()

	// Check via JSON if the field is present.
	var resp struct {
		Skipped []string `json:"skipped"`
	}
	if err := json.Unmarshal([]byte(body), &resp); err == nil {
		for _, name := range resp.Skipped {
			if name == "build" {
				t.Errorf("the interrupted phase 'build' appears in skipped=%v; reconciled phases must be re-run", resp.Skipped)
			}
		}
		// "test" (passed) must be skipped.
		var foundTest bool
		for _, name := range resp.Skipped {
			if name == "test" {
				foundTest = true
			}
		}
		if !foundTest {
			t.Errorf("the passed phase 'test' is absent from skipped=%v; passed phases must still be skipped on resume", resp.Skipped)
		}
		return
	}

	// Fallback: raw body check for the interrupted phase name.
	if strings.Contains(body, `"build"`) && strings.Contains(body, "skipped") {
		t.Errorf("body mentions 'build' in a skipped context: %s", body)
	}
}

// TestReconcileOrphanedRunsIsAvailableOnStore: smoke test that the method
// exists on the store and is callable. Detailed behaviour is in
// internal/store/reconcile_test.go.
func TestReconcileOrphanedRunsIsAvailableOnStore(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "t.db")
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	if err := st.CreateRun(&store.RunRecord{
		ID: "orphan", Project: "p", TaskID: "orphan", Status: "running",
	}); err != nil {
		t.Fatal(err)
	}

	result, err := st.ReconcileOrphanedRuns()
	if err != nil {
		t.Fatalf("ReconcileOrphanedRuns: %v", err)
	}
	if result.RunsReconciled != 1 {
		t.Errorf("RunsReconciled = %d, want 1", result.RunsReconciled)
	}
}
