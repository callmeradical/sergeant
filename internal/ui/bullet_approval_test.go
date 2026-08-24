package ui

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/callmeradical/sergeant/internal/store"
)

// bulletApprovalFixture builds a server backed by a fresh store holding one
// intent with one bullet at the given status, and a run naming that intent —
// the minimal setup handleCreatePR's seal guard and handleBullets both need.
func bulletApprovalFixture(t *testing.T, bulletStatus string) (srv *Server, mux http.Handler, runID string) {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "bullets.db")
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("failed to open store: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })

	const intentID = "intent-ba-1"
	if err := st.CreateIntent(&store.IntentRecord{ID: intentID, Project: "ba", Statement: "s", Status: "approved"}); err != nil {
		t.Fatalf("failed to create intent: %v", err)
	}
	if err := st.CreateBullet(&store.BulletRecord{ID: "bullet-ba-1", IntentID: intentID, Repo: "svc", Position: 1, Status: bulletStatus}); err != nil {
		t.Fatalf("failed to create bullet: %v", err)
	}
	runID = "run-ba-1"
	if err := st.CreateRun(&store.RunRecord{ID: runID, Project: "ba", TaskID: runID, Status: "passed", IntentID: intentID}); err != nil {
		t.Fatalf("failed to create run: %v", err)
	}

	srv = NewServer(st, 0)
	return srv, srv.Handler(), runID
}

// R3.5: a pull-request-creation request is refused when the target bullet is
// not green, and — because approval must be required, not merely possible —
// gh pr create must never run for a refused request. Recorded via
// Server.GHPRCreate, not inferred from the HTTP status alone.
func TestCreatePRForNonGreenBulletIsRefusedAndNeverInvokesGH(t *testing.T) {
	for _, status := range []string{"pending", "red", "sealed", "failed"} {
		t.Run(status, func(t *testing.T) {
			srv, mux, runID := bulletApprovalFixture(t, status)

			ghCalls := 0
			srv.GHPRCreate = func(repoPath, title, body, branch string) ([]byte, error) {
				ghCalls++
				return []byte("https://github.com/example/repo/pull/1"), nil
			}

			body := fmt.Sprintf(`{"run_id":%q,"project":"ba","repo":"svc","title":"t","body":"b"}`, runID)
			w := httptest.NewRecorder()
			mux.ServeHTTP(w, httptest.NewRequest("POST", "/api/create-pr", strings.NewReader(body)))

			if w.Code != http.StatusConflict {
				t.Fatalf("status = %d, want 409; body=%s", w.Code, w.Body.String())
			}
			if !strings.Contains(w.Body.String(), status) {
				t.Errorf("refusal does not name the bullet's actual status %q: %s", status, w.Body.String())
			}
			if ghCalls != 0 {
				t.Errorf("gh pr create was invoked %d time(s) for a refused request, want 0", ghCalls)
			}
		})
	}
}

// A successful PR-creation request for a green bullet proceeds and durably
// records approval: the bullet becomes sealed. Verified through GET
// /api/bullets, not by inspecting internal state, so this also proves the
// listing endpoint reflects the write.
func TestCreatePRForGreenBulletSucceedsAndSealsTheBullet(t *testing.T) {
	srv, mux, runID := bulletApprovalFixture(t, "green")
	_ = srv

	body := fmt.Sprintf(`{"run_id":%q,"project":"ba","repo":"svc","title":"t","body":"b"}`, runID)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest("POST", "/api/create-pr", strings.NewReader(body)))
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", w.Code, w.Body.String())
	}

	gw := httptest.NewRecorder()
	mux.ServeHTTP(gw, httptest.NewRequest("GET", "/api/bullets?run_id="+runID, nil))
	if gw.Code != http.StatusOK {
		t.Fatalf("GET /api/bullets status = %d, want 200; body=%s", gw.Code, gw.Body.String())
	}
	var bullets []store.BulletRecord
	if err := json.Unmarshal(gw.Body.Bytes(), &bullets); err != nil {
		t.Fatalf("decoding /api/bullets response: %v; body=%s", err, gw.Body.String())
	}
	if len(bullets) != 1 || bullets[0].Status != "sealed" {
		t.Errorf("expected the bullet to read as sealed via GET /api/bullets, got %+v", bullets)
	}
}

// A run that predates intent tracking carries no intent id. GET /api/bullets
// must answer an empty list, not an error and not a JSON null a client would
// have to special-case.
func TestGetBulletsForRunWithNoIntentReturnsEmptyArray(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "bullets-no-intent.db")
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("failed to open store: %v", err)
	}
	defer st.Close()

	const runID = "run-no-intent-ba"
	if err := st.CreateRun(&store.RunRecord{ID: runID, Project: "ba", TaskID: runID, Status: "passed"}); err != nil {
		t.Fatalf("failed to create run: %v", err)
	}

	mux := NewServer(st, 0).Handler()
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest("GET", "/api/bullets?run_id="+runID, nil))
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", w.Code, w.Body.String())
	}
	if got := strings.TrimSpace(w.Body.String()); got != "[]" {
		t.Errorf("body = %q, want []", got)
	}
}

// run_id is required, the same convention handleDeliveryHistory uses: an
// empty result for a missing id would be indistinguishable from "this run
// truly has no bullets".
func TestGetBulletsWithoutRunIDIsRefused(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "bullets-missing.db")
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("failed to open store: %v", err)
	}
	defer st.Close()
	mux := NewServer(st, 0).Handler()

	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest("GET", "/api/bullets", nil))
	if w.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want 400; body=%s", w.Code, w.Body.String())
	}
}
