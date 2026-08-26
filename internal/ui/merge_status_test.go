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

	"github.com/callmeradical/sergeant/internal/changerequest"
	"github.com/callmeradical/sergeant/internal/store"
)

// mergeStatusFixture builds a server backed by a fresh store holding one
// intent (no bullets yet — tests add their own) and a run naming it, plus a
// real git repo with a GitHub remote wired into the run's project config so
// handleCheckMergeStatus's provider-detection path resolves for real. A
// second repo name ("svc2") is wired to the same git repo so a test can
// exercise two bullets independently without a second git fixture.
func mergeStatusFixture(t *testing.T, baseBranch string) (srv *Server, mux http.Handler, runID, intentID string) {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "merge.db")
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("failed to open store: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })

	intentID = "intent-merge-1"
	if err := st.CreateIntent(&store.IntentRecord{ID: intentID, Project: "mrg", Statement: "s", Status: "approved"}); err != nil {
		t.Fatal(err)
	}

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
	projYAML := fmt.Sprintf("name: mrg\nrepos:\n  svc:\n    path: %q\n  svc2:\n    path: %q\n", repoDir, repoDir)
	if err := os.WriteFile(projPath, []byte(projYAML), 0644); err != nil {
		t.Fatal(err)
	}

	runID = "run-merge-1"
	if err := st.CreateRun(&store.RunRecord{
		ID: runID, Project: projPath, TaskID: runID, Status: "passed", IntentID: intentID, BaseBranch: baseBranch,
	}); err != nil {
		t.Fatal(err)
	}

	srv = NewServer(st, 0)
	return srv, srv.Handler(), runID, intentID
}

func postCheckMergeStatus(t *testing.T, mux http.Handler, runID string) *httptest.ResponseRecorder {
	t.Helper()
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest("POST", "/api/check-merge-status?run_id="+runID, nil))
	return w
}

// Scenario: "A merge into the expected base advances the bullet to merged"
// (specs/change-request-merge/spec.md).
func TestCheckMergeStatusAdvancesToMergedWhenMergedIntoExpectedBase(t *testing.T) {
	srv, mux, runID, intentID := mergeStatusFixture(t, "main")

	const prURL = "https://github.com/example/repo/pull/1"
	if err := srv.Store.CreateBullet(&store.BulletRecord{ID: "b-merge-1", IntentID: intentID, Repo: "svc", Position: 1, Status: "sealed", PRURL: prURL}); err != nil {
		t.Fatal(err)
	}

	installFakeGitHubProvider(t, &fakeChangeRequestProvider{
		statusFn: func(ctx context.Context, repoPath, url string) (*changerequest.StatusResult, error) {
			return &changerequest.StatusResult{Merged: true, MergedIntoBranch: "main"}, nil
		},
	})

	w := postCheckMergeStatus(t, mux, runID)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", w.Code, w.Body.String())
	}

	got, err := srv.Store.GetBullet("b-merge-1")
	if err != nil {
		t.Fatal(err)
	}
	if got.Status != "merged" {
		t.Errorf("bullet.Status = %q, want %q", got.Status, "merged")
	}
}

// Scenario: "A merge into an unexpected base blocks the bullet"
// (specs/change-request-merge/spec.md) — never merged, never left at sealed
// as if nothing happened, and the reason names both branches.
func TestCheckMergeStatusBlocksWhenMergedIntoUnexpectedBase(t *testing.T) {
	srv, mux, runID, intentID := mergeStatusFixture(t, "main")

	const prURL = "https://github.com/example/repo/pull/2"
	if err := srv.Store.CreateBullet(&store.BulletRecord{ID: "b-merge-2", IntentID: intentID, Repo: "svc", Position: 1, Status: "sealed", PRURL: prURL}); err != nil {
		t.Fatal(err)
	}

	installFakeGitHubProvider(t, &fakeChangeRequestProvider{
		statusFn: func(ctx context.Context, repoPath, url string) (*changerequest.StatusResult, error) {
			return &changerequest.StatusResult{Merged: true, MergedIntoBranch: "v2"}, nil
		},
	})

	w := postCheckMergeStatus(t, mux, runID)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", w.Code, w.Body.String())
	}

	got, err := srv.Store.GetBullet("b-merge-2")
	if err != nil {
		t.Fatal(err)
	}
	if got.Status != "blocked" {
		t.Errorf("bullet.Status = %q, want %q (never merged, never left at sealed)", got.Status, "blocked")
	}
	if !strings.Contains(got.BlockedReason, "main") || !strings.Contains(got.BlockedReason, "v2") {
		t.Errorf("bullet.BlockedReason = %q, want it to name both the expected (%q) and actual (%q) branch", got.BlockedReason, "main", "v2")
	}
}

// Scenario: "A change request still open leaves the bullet untouched".
func TestCheckMergeStatusLeavesAnOpenChangeRequestUntouchedAtSealed(t *testing.T) {
	srv, mux, runID, intentID := mergeStatusFixture(t, "main")

	const prURL = "https://github.com/example/repo/pull/3"
	if err := srv.Store.CreateBullet(&store.BulletRecord{ID: "b-merge-3", IntentID: intentID, Repo: "svc", Position: 1, Status: "sealed", PRURL: prURL}); err != nil {
		t.Fatal(err)
	}

	statusCalls := 0
	installFakeGitHubProvider(t, &fakeChangeRequestProvider{
		statusFn: func(ctx context.Context, repoPath, url string) (*changerequest.StatusResult, error) {
			statusCalls++
			return &changerequest.StatusResult{Merged: false}, nil
		},
	})

	w := postCheckMergeStatus(t, mux, runID)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", w.Code, w.Body.String())
	}
	if statusCalls != 1 {
		t.Fatalf("Status invoked %d time(s), want 1", statusCalls)
	}

	got, err := srv.Store.GetBullet("b-merge-3")
	if err != nil {
		t.Fatal(err)
	}
	if got.Status != "sealed" {
		t.Errorf("bullet.Status = %q, want unchanged %q", got.Status, "sealed")
	}
}

// Scenario: "A run with no sealed bullets triggers no provider call" —
// a green bullet (not sealed) and a sealed bullet with no PRURL yet must
// both be skipped without ever reaching the provider seam.
func TestCheckMergeStatusWithNoSealedBulletsIsACheapNoOp(t *testing.T) {
	srv, mux, runID, intentID := mergeStatusFixture(t, "main")

	if err := srv.Store.CreateBullet(&store.BulletRecord{ID: "b-nomerge-1", IntentID: intentID, Repo: "svc", Position: 1, Status: "green"}); err != nil {
		t.Fatal(err)
	}
	if err := srv.Store.CreateBullet(&store.BulletRecord{ID: "b-nomerge-2", IntentID: intentID, Repo: "svc2", Position: 2, Status: "sealed"}); err != nil {
		t.Fatal(err)
	}

	statusCalls := 0
	installFakeGitHubProvider(t, &fakeChangeRequestProvider{
		statusFn: func(ctx context.Context, repoPath, url string) (*changerequest.StatusResult, error) {
			statusCalls++
			return &changerequest.StatusResult{}, nil
		},
	})

	w := postCheckMergeStatus(t, mux, runID)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", w.Code, w.Body.String())
	}
	if statusCalls != 0 {
		t.Errorf("Status invoked %d time(s), want 0 — no sealed bullet carries a recorded PRURL", statusCalls)
	}
}

// Scenario: one bullet's check failing (a provider error) does not prevent
// another bullet of the same run from being checked and correctly advanced.
func TestCheckMergeStatusOneBulletsFailureDoesNotStopAnother(t *testing.T) {
	srv, mux, runID, intentID := mergeStatusFixture(t, "main")

	const failingURL = "https://github.com/example/repo/pull/4"
	const okURL = "https://github.com/example/repo/pull/5"
	if err := srv.Store.CreateBullet(&store.BulletRecord{ID: "b-fail", IntentID: intentID, Repo: "svc", Position: 1, Status: "sealed", PRURL: failingURL}); err != nil {
		t.Fatal(err)
	}
	if err := srv.Store.CreateBullet(&store.BulletRecord{ID: "b-ok", IntentID: intentID, Repo: "svc2", Position: 2, Status: "sealed", PRURL: okURL}); err != nil {
		t.Fatal(err)
	}

	installFakeGitHubProvider(t, &fakeChangeRequestProvider{
		statusFn: func(ctx context.Context, repoPath, url string) (*changerequest.StatusResult, error) {
			if url == failingURL {
				return nil, fmt.Errorf("gh pr view: simulated provider failure")
			}
			return &changerequest.StatusResult{Merged: true, MergedIntoBranch: "main"}, nil
		},
	})

	w := postCheckMergeStatus(t, mux, runID)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", w.Code, w.Body.String())
	}

	failed, err := srv.Store.GetBullet("b-fail")
	if err != nil {
		t.Fatal(err)
	}
	if failed.Status != "sealed" {
		t.Errorf("failed bullet.Status = %q, want unchanged %q after its own provider error", failed.Status, "sealed")
	}

	ok, err := srv.Store.GetBullet("b-ok")
	if err != nil {
		t.Fatal(err)
	}
	if ok.Status != "merged" {
		t.Errorf("other bullet.Status = %q, want %q — one bullet's failure must not stop another from being checked", ok.Status, "merged")
	}

	var resp struct {
		Results []struct {
			BulletID string `json:"bullet_id"`
			Status   string `json:"status"`
			Error    string `json:"error"`
		} `json:"results"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decoding response: %v; body=%s", err, w.Body.String())
	}
	foundFailureReported := false
	for _, r := range resp.Results {
		if r.BulletID == "b-fail" && r.Error != "" {
			foundFailureReported = true
		}
	}
	if !foundFailureReported {
		t.Errorf("response did not report the failing bullet's error, it must never be silently swallowed: %+v", resp.Results)
	}
}
