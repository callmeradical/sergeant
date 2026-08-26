package ui

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
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
// gh pr create must never run for a refused request. Recorded via the
// changerequest provider seam, not inferred from the HTTP status alone.
func TestCreatePRForNonGreenBulletIsRefusedAndNeverInvokesGH(t *testing.T) {
	for _, status := range []string{"pending", "red", "sealed", "failed"} {
		t.Run(status, func(t *testing.T) {
			srv, mux, runID := bulletApprovalFixture(t, status)
			_ = srv

			fake := &fakeChangeRequestProvider{}
			installFakeGitHubProvider(t, fake)

			body := fmt.Sprintf(`{"run_id":%q,"project":"ba","repo":"svc","title":"t","body":"b"}`, runID)
			w := httptest.NewRecorder()
			mux.ServeHTTP(w, httptest.NewRequest("POST", "/api/create-pr", strings.NewReader(body)))

			if w.Code != http.StatusConflict {
				t.Fatalf("status = %d, want 409; body=%s", w.Code, w.Body.String())
			}
			if !strings.Contains(w.Body.String(), status) {
				t.Errorf("refusal does not name the bullet's actual status %q: %s", status, w.Body.String())
			}
			if fake.createCalls != 0 {
				t.Errorf("gh pr create was invoked %d time(s) for a refused request, want 0", fake.createCalls)
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

// gh's own error output is stored into an EnvelopeRecord and returned in the
// HTTP response, not just logged — it must go through redaction like any
// other captured subprocess output (Review 015 flagged this call site was
// still wired to none).
func TestCreatePRRedactsSecretsFromFailedGHOutput(t *testing.T) {
	srv, mux, runID := bulletApprovalFixture(t, "green")

	repoDir := t.TempDir()
	runGit := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-C", repoDir}, args...)...)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
	}
	runGit("init")
	runGit("remote", "add", "origin", "https://github.com/example/repo.git")

	projPath := filepath.Join(t.TempDir(), "proj.yaml")
	projYAML := fmt.Sprintf("name: ba\nrepos:\n  svc:\n    path: %q\n", repoDir)
	if err := os.WriteFile(projPath, []byte(projYAML), 0644); err != nil {
		t.Fatal(err)
	}

	secret := "AKIAIOSFODNN7EXAMPLE"
	installFakeGitHubProvider(t, &fakeChangeRequestProvider{
		createFn: func(ctx context.Context, repoPath, base, head, title, body string) (string, error) {
			return "", fmt.Errorf("error: authentication failed for token %s", secret)
		},
	})

	body := fmt.Sprintf(`{"run_id":%q,"project":%q,"repo":"svc","title":"t","body":"b"}`, runID, projPath)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest("POST", "/api/create-pr", strings.NewReader(body)))
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", w.Code, w.Body.String())
	}
	if strings.Contains(w.Body.String(), secret) {
		t.Errorf("HTTP response leaked the secret: %s", w.Body.String())
	}
	if !strings.Contains(w.Body.String(), "[REDACTED]") {
		t.Errorf("HTTP response was not redacted: %s", w.Body.String())
	}

	envelopes, err := srv.Store.ListEnvelopesForRun(runID)
	if err != nil {
		t.Fatalf("failed to list envelopes: %v", err)
	}
	if len(envelopes) != 1 {
		t.Fatalf("expected 1 envelope, got %d", len(envelopes))
	}
	if strings.Contains(string(envelopes[0].Data), secret) {
		t.Errorf("persisted EnvelopeRecord.Data leaked the secret: %s", envelopes[0].Data)
	}
	if !strings.Contains(string(envelopes[0].Data), "[REDACTED]") {
		t.Errorf("persisted EnvelopeRecord.Data was not redacted: %s", envelopes[0].Data)
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
