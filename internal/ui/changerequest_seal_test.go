package ui

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/callmeradical/sergeant/internal/store"
)

// changeRequestFixture builds a server backed by a fresh store holding one
// intent with one green bullet and a run naming it, plus a real git repo
// configured with the given remote (empty means no remote at all) — the
// minimal setup needed to exercise handleCreatePR's real provider-detection
// path against an actual git remote, not just a fake Provider standing in
// for gh.
func changeRequestFixture(t *testing.T, remote, baseBranch string) (srv *Server, mux http.Handler, runID, bulletID, projPath string) {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "cr.db")
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("failed to open store: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })

	const intentID = "intent-cr-1"
	if err := st.CreateIntent(&store.IntentRecord{ID: intentID, Project: "cr", Statement: "s", Status: "approved"}); err != nil {
		t.Fatalf("failed to create intent: %v", err)
	}
	bulletID = "bullet-cr-1"
	if err := st.CreateBullet(&store.BulletRecord{ID: bulletID, IntentID: intentID, Repo: "svc", Position: 1, Status: "green"}); err != nil {
		t.Fatalf("failed to create bullet: %v", err)
	}
	runID = "run-cr-1"
	if err := st.CreateRun(&store.RunRecord{
		ID: runID, Project: "cr", TaskID: runID, Status: "passed", IntentID: intentID, BaseBranch: baseBranch,
	}); err != nil {
		t.Fatalf("failed to create run: %v", err)
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
	if remote != "" {
		runGit("remote", "add", "origin", remote)
	}

	projPath = filepath.Join(t.TempDir(), "proj.yaml")
	projYAML := fmt.Sprintf("name: cr\nrepos:\n  svc:\n    path: %q\n", repoDir)
	if err := os.WriteFile(projPath, []byte(projYAML), 0644); err != nil {
		t.Fatal(err)
	}

	srv = NewServer(st, 0)
	return srv, srv.Handler(), runID, bulletID, projPath
}

// Scenario: "A successfully opened change request is readable from the
// bullet afterward" (specs/change-request-merge/spec.md). A successful
// seal+create against a GitHub remote must persist the change request's
// URL onto the bullet itself — GetBullet, not only a pr.staged envelope.
func TestCreatePRPersistsTheChangeRequestURLOntoTheBullet(t *testing.T) {
	srv, mux, runID, bulletID, projPath := changeRequestFixture(t, "https://github.com/example/repo.git", "main")

	const wantURL = "https://github.com/example/repo/pull/42"
	installFakeGitHubProvider(t, &fakeChangeRequestProvider{
		createFn: func(ctx context.Context, repoPath, base, head, title, body string) (string, error) {
			return wantURL, nil
		},
	})

	w := postCreatePR(t, mux, runID, projPath)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", w.Code, w.Body.String())
	}

	bullet, err := srv.Store.GetBullet(bulletID)
	if err != nil {
		t.Fatalf("GetBullet: %v", err)
	}
	if bullet.PRURL != wantURL {
		t.Errorf("bullet.PRURL = %q, want %q — reading the bullet back must report the change request's URL", bullet.PRURL, wantURL)
	}
}

// Scenario: "The change request names the run's recorded base branch"
// (specs/change-request-merge/spec.md). Proven against the real provider
// seam's Create call, not just the response body.
func TestCreatePRCallsCreateWithTheRunsRecordedBaseBranch(t *testing.T) {
	_, mux, runID, _, projPath := changeRequestFixture(t, "https://github.com/example/repo.git", "release/9.9")

	fake := &fakeChangeRequestProvider{}
	installFakeGitHubProvider(t, fake)

	w := postCreatePR(t, mux, runID, projPath)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", w.Code, w.Body.String())
	}
	if fake.createCalls != 1 {
		t.Fatalf("Create invoked %d time(s), want 1", fake.createCalls)
	}
	if fake.lastBase != "release/9.9" {
		t.Errorf("Create's base argument = %q, want the run's recorded BaseBranch %q", fake.lastBase, "release/9.9")
	}
}

// Scenario: "An unrecognized remote is refused clearly"
// (specs/change-request-merge/spec.md), exercised through the real
// handleCreatePR path: a repo whose remote is not GitHub is refused with an
// error naming the detected host, and the seal that already succeeded is
// not reverted, but no change request is fabricated — the bullet's PRURL
// stays empty.
func TestCreatePRRefusesAnUnrecognizedRemoteWithoutFabricatingAChangeRequest(t *testing.T) {
	srv, mux, runID, bulletID, projPath := changeRequestFixture(t, "git@gitlab.com:owner/repo.git", "main")

	w := postCreatePR(t, mux, runID, projPath)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400; body=%s", w.Code, w.Body.String())
	}
	if !strings.Contains(w.Body.String(), "gitlab.com") {
		t.Errorf("refusal does not name the detected host %q: %s", "gitlab.com", w.Body.String())
	}

	bullet, err := srv.Store.GetBullet(bulletID)
	if err != nil {
		t.Fatalf("GetBullet: %v", err)
	}
	if bullet.PRURL != "" {
		t.Errorf("bullet.PRURL = %q, want empty — no change request should be fabricated for an unrecognized host", bullet.PRURL)
	}
	if bullet.Status != "sealed" {
		t.Errorf("bullet.Status = %q, want %q — the seal that already succeeded must not be reverted", bullet.Status, "sealed")
	}
}
