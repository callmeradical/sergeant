package ui

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/callmeradical/sergeant/internal/runner"
	"github.com/callmeradical/sergeant/internal/store"
)

// shippingGateFixture builds a server backed by a fresh store holding one
// intent with two bullets: bullet 1 already sealed, bullet 2 green — and a
// run naming bullet 2's repo. Sealing bullet 2 via POST /api/create-pr is
// what completes AllBulletsSealedOrMerged for the intent and should trigger
// its shipping gate. A project config file is written declaring the given
// shipping gates (nil/empty means "declares none"), following
// bulletApprovalFixture's precedent for the minimal setup handleCreatePR needs.
func shippingGateFixture(t *testing.T, shippingGates map[string]string) (srv *Server, mux http.Handler, runID, intentID, projPath string) {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "shipgate.db")
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("failed to open store: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })

	intentID = "intent-sg-1"
	if err := st.CreateIntent(&store.IntentRecord{ID: intentID, Project: "sg", Statement: "s", Status: "approved"}); err != nil {
		t.Fatalf("failed to create intent: %v", err)
	}
	if err := st.CreateBullet(&store.BulletRecord{ID: "bullet-sg-1", IntentID: intentID, Repo: "api", Position: 1, Status: "sealed"}); err != nil {
		t.Fatalf("failed to create bullet 1: %v", err)
	}
	if err := st.CreateBullet(&store.BulletRecord{ID: "bullet-sg-2", IntentID: intentID, Repo: "svc", Position: 2, Status: "green"}); err != nil {
		t.Fatalf("failed to create bullet 2: %v", err)
	}
	runID = "run-sg-2"
	if err := st.CreateRun(&store.RunRecord{ID: runID, Project: "sg", TaskID: runID, Status: "passed", IntentID: intentID}); err != nil {
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
	runGit("remote", "add", "origin", "https://github.com/example/repo.git")

	var b strings.Builder
	fmt.Fprintf(&b, "name: sg\nrepos:\n  svc:\n    path: %q\n", repoDir)
	if len(shippingGates) > 0 {
		b.WriteString("shipping_gates:\n")
		names := make([]string, 0, len(shippingGates))
		for name := range shippingGates {
			names = append(names, name)
		}
		sort.Strings(names)
		for _, name := range names {
			fmt.Fprintf(&b, "  %s: %q\n", name, shippingGates[name])
		}
	}
	projPath = filepath.Join(t.TempDir(), "proj.yaml")
	if err := os.WriteFile(projPath, []byte(b.String()), 0644); err != nil {
		t.Fatal(err)
	}

	srv = NewServer(st, 0)
	return srv, srv.Handler(), runID, intentID, projPath
}

func postCreatePR(t *testing.T, mux http.Handler, runID, projPath string) *httptest.ResponseRecorder {
	t.Helper()
	body := fmt.Sprintf(`{"run_id":%q,"project":%q,"repo":"svc","title":"t","body":"b"}`, runID, projPath)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest("POST", "/api/create-pr", strings.NewReader(body)))
	return w
}

// Scenario: "No shipping gates configured records a pass with no command run"
// (specs/shipping-gate/spec.md). Proven via the recording seam around
// Server.RunShippingGate — the same "did not invoke X" shape
// TestCreatePRForNonGreenBulletIsRefusedAndNeverInvokesGH already uses for
// GHPRCreate — not just by checking the final stored status.
func TestCreatePRWithNoShippingGatesConfiguredRecordsAPassWithNoCommandRun(t *testing.T) {
	srv, mux, runID, intentID, projPath := shippingGateFixture(t, nil)

	gateCalls := 0
	srv.RunShippingGate = func(ctx context.Context, name, command string, worktrees []string) (*runner.GateResult, error) {
		gateCalls++
		return &runner.GateResult{Passed: true}, nil
	}
	srv.GHPRCreate = func(repoPath, title, body, branch string) ([]byte, error) {
		return []byte("https://github.com/example/repo/pull/1"), nil
	}

	w := postCreatePR(t, mux, runID, projPath)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", w.Code, w.Body.String())
	}
	if gateCalls != 0 {
		t.Errorf("RunShippingGate invoked %d time(s), want 0 when the project declares no shipping gates", gateCalls)
	}

	intent, err := srv.Store.GetIntent(intentID)
	if err != nil {
		t.Fatalf("loading intent: %v", err)
	}
	if intent.ShippingGateStatus != "passed" {
		t.Errorf("ShippingGateStatus = %q, want %q", intent.ShippingGateStatus, "passed")
	}
	if intent.ShippingGateReason != "" {
		t.Errorf("ShippingGateReason = %q, want empty", intent.ShippingGateReason)
	}
}

// Scenario: "A shipping-gate failure leaves every bullet sealed"
// (specs/shipping-gate/spec.md). A real POST /api/create-pr request
// completing the last seal of a multi-bullet intent, with a shipping gate
// configured to fail — every bullet must still read as sealed afterward.
func TestShippingGateFailureLeavesEveryBulletSealed(t *testing.T) {
	srv, mux, runID, intentID, projPath := shippingGateFixture(t, map[string]string{"security": "exit 1"})
	srv.GHPRCreate = func(repoPath, title, body, branch string) ([]byte, error) {
		return []byte("https://github.com/example/repo/pull/1"), nil
	}

	w := postCreatePR(t, mux, runID, projPath)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", w.Code, w.Body.String())
	}

	bullets, err := srv.Store.ListBulletsForIntent(intentID)
	if err != nil {
		t.Fatalf("listing bullets: %v", err)
	}
	if len(bullets) != 2 {
		t.Fatalf("expected 2 bullets, got %d", len(bullets))
	}
	for _, b := range bullets {
		if b.Status != "sealed" {
			t.Errorf("bullet %s status = %q, want sealed even though the shipping gate failed", b.ID, b.Status)
		}
	}

	intent, err := srv.Store.GetIntent(intentID)
	if err != nil {
		t.Fatalf("loading intent: %v", err)
	}
	if intent.ShippingGateStatus != "failed" {
		t.Errorf("ShippingGateStatus = %q, want %q", intent.ShippingGateStatus, "failed")
	}
	if !strings.Contains(intent.ShippingGateReason, "security") {
		t.Errorf("ShippingGateReason = %q, want it to name the failed check", intent.ShippingGateReason)
	}
}

// Scenario: "A passing shipping gate triggers no merge action"
// (specs/shipping-gate/spec.md). Verified the same way this project already
// verifies "did not call gh" (bulletApprovalFixture's precedent): gh must be
// invoked exactly once — the request's own PR-creation action — with no
// extra call attributable to the (passing) shipping gate.
func TestPassingShippingGateTriggersNoMergeAction(t *testing.T) {
	srv, mux, runID, intentID, projPath := shippingGateFixture(t, map[string]string{"security": "true"})

	ghCalls := 0
	srv.GHPRCreate = func(repoPath, title, body, branch string) ([]byte, error) {
		ghCalls++
		return []byte("https://github.com/example/repo/pull/1"), nil
	}

	w := postCreatePR(t, mux, runID, projPath)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", w.Code, w.Body.String())
	}
	if ghCalls != 1 {
		t.Errorf("gh pr create invoked %d time(s), want exactly 1 (the request's own PR action, none from the shipping gate)", ghCalls)
	}

	intent, err := srv.Store.GetIntent(intentID)
	if err != nil {
		t.Fatalf("loading intent: %v", err)
	}
	if intent.ShippingGateStatus != "passed" {
		t.Errorf("ShippingGateStatus = %q, want %q", intent.ShippingGateStatus, "passed")
	}
}
