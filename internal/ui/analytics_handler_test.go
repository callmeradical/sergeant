package ui

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/callmeradical/sergeant/internal/store"
)

func openAnalyticsTestServer(t *testing.T) (*store.Store, http.Handler) {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "test.db")
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("failed to open store: %v", err)
	}
	t.Cleanup(func() { st.Close() })
	srv := NewServer(st, 0)
	return st, srv.Handler()
}

// GET /api/analytics must scope by project exactly the way GET /api/runs
// does: a named project returns only that project's data, and omitting the
// param (or passing "all") combines every project.
func TestHandleAnalyticsScopesByProjectLikeHandleRuns(t *testing.T) {
	st, mux := openAnalyticsTestServer(t)

	if err := st.CreateRun(&store.RunRecord{ID: "run-a", Project: "proj-a", TaskID: "run-a", Status: "passed", Type: "feat"}); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateRun(&store.RunRecord{ID: "run-b", Project: "proj-b", TaskID: "run-b", Status: "failed", Type: "fix"}); err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest("GET", "/api/analytics?project=proj-a", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200 OK, got %d: %s", w.Code, w.Body.String())
	}

	var scoped store.WorkAnalytics
	if err := json.Unmarshal(w.Body.Bytes(), &scoped); err != nil {
		t.Fatalf("decoding response: %v", err)
	}
	if scoped.TotalRuns != 1 {
		t.Errorf("project=proj-a TotalRuns = %d, want 1", scoped.TotalRuns)
	}

	reqAll := httptest.NewRequest("GET", "/api/analytics?project=all", nil)
	wAll := httptest.NewRecorder()
	mux.ServeHTTP(wAll, reqAll)
	if wAll.Code != http.StatusOK {
		t.Fatalf("expected 200 OK, got %d: %s", wAll.Code, wAll.Body.String())
	}
	var all store.WorkAnalytics
	if err := json.Unmarshal(wAll.Body.Bytes(), &all); err != nil {
		t.Fatalf("decoding response: %v", err)
	}
	if all.TotalRuns != 2 {
		t.Errorf("project=all TotalRuns = %d, want 2", all.TotalRuns)
	}

	reqNoParam := httptest.NewRequest("GET", "/api/analytics", nil)
	wNoParam := httptest.NewRecorder()
	mux.ServeHTTP(wNoParam, reqNoParam)
	if wNoParam.Code != http.StatusOK {
		t.Fatalf("expected 200 OK, got %d: %s", wNoParam.Code, wNoParam.Body.String())
	}
	var noParam store.WorkAnalytics
	if err := json.Unmarshal(wNoParam.Body.Bytes(), &noParam); err != nil {
		t.Fatalf("decoding response: %v", err)
	}
	if noParam.TotalRuns != 2 {
		t.Errorf("omitted project param TotalRuns = %d, want 2 (matches handleRuns' project/all convention)", noParam.TotalRuns)
	}
}

// A project with no recorded runs or bullets must still answer 200 with
// zeroed counts, not an error — the endpoint is a plain read like handleRuns.
func TestHandleAnalyticsEmptyProjectReturnsZeroedCounts(t *testing.T) {
	_, mux := openAnalyticsTestServer(t)

	req := httptest.NewRequest("GET", "/api/analytics?project=nothing-here", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200 OK, got %d: %s", w.Code, w.Body.String())
	}

	var got store.WorkAnalytics
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("decoding response: %v", err)
	}
	if got.TotalRuns != 0 || got.BulletsTotal != 0 {
		t.Errorf("got %+v, want zeroed counts", got)
	}
}
