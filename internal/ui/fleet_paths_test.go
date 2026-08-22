package ui

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The fleet endpoints must enumerate the same root the engine writes to.
// They used to build ~/.local/share/sergeant/fleet by hand — v1's root, which
// decision D7 forbids touching — so no v2 worktree ever appeared in the Workers
// pane and prune offered v1's directories for deletion instead.

type fleetLease struct {
	TaskID string `json:"task_id"`
	Path   string `json:"path"`
}

// Scenario: A dispatched run's worktree is visible to the fleet listing.
func TestFleetListingSeesWorktreesUnderTheConfiguredRoot(t *testing.T) {
	mux, _, _ := dispatchFixture(t)
	root := configuredFleetRoot(t)

	if err := os.MkdirAll(filepath.Join(root, "sgt-visible", "svc"), 0o755); err != nil {
		t.Fatal(err)
	}

	var body struct {
		Allocated int          `json:"allocated_worktrees"`
		Leases    []fleetLease `json:"leases"`
	}
	getJSON(t, mux, "GET", "/api/fleet", nil, &body)

	var found bool
	for _, l := range body.Leases {
		if l.TaskID == "sgt-visible" {
			found = true
		}
	}
	if !found {
		t.Errorf("GET /api/fleet did not list the worktree under the configured root %q; leases = %+v",
			root, body.Leases)
	}

	// Scenario: Prune never offers a worktree outside the configured root.
	assertAllUnder(t, root, body.Leases, "GET /api/fleet")
}

// Scenario: Prune never offers a worktree outside the configured root.
func TestPruneOnlyOffersWorktreesUnderTheConfiguredRoot(t *testing.T) {
	mux, _, _ := dispatchFixture(t)
	root := configuredFleetRoot(t)

	if err := os.MkdirAll(filepath.Join(root, "sgt-prunable", "svc"), 0o755); err != nil {
		t.Fatal(err)
	}

	var body struct {
		Status  string   `json:"status"`
		Removed []string `json:"removed"`
	}
	getJSON(t, mux, "POST", "/api/clean-worktrees",
		strings.NewReader(`{"dry_run":true}`), &body)

	if body.Status != "preview" {
		t.Fatalf("dry-run prune status = %q, want %q", body.Status, "preview")
	}

	var found bool
	for _, p := range body.Removed {
		if !strings.HasPrefix(filepath.Clean(p), filepath.Clean(root)) {
			t.Errorf("prune offered %q, which is outside the configured fleet root %q", p, root)
		}
		if filepath.Base(filepath.Clean(p)) == "sgt-prunable" {
			found = true
		}
	}
	if !found {
		t.Errorf("dry-run prune did not offer the worktree under the configured root %q; removed = %v",
			root, body.Removed)
	}
}

// configuredFleetRoot is the root the test fixture pointed SERGEANT_FLEET_DIR at.
// Reading it back from the environment is deliberate: the assertion is that the
// handlers honour that variable, so the test must not compute the path itself.
func configuredFleetRoot(t *testing.T) string {
	t.Helper()
	root := os.Getenv("SERGEANT_FLEET_DIR")
	if root == "" {
		t.Fatal("fixture did not set SERGEANT_FLEET_DIR, so this test cannot prove which root is read")
	}
	return root
}

func assertAllUnder(t *testing.T, root string, leases []fleetLease, what string) {
	t.Helper()
	for _, l := range leases {
		if !strings.HasPrefix(filepath.Clean(l.Path), filepath.Clean(root)) {
			t.Errorf("%s returned lease path %q, which is outside the configured fleet root %q",
				what, l.Path, root)
		}
	}
}

func getJSON(t *testing.T, mux http.Handler, method, path string, reqBody *strings.Reader, out interface{}) {
	t.Helper()
	var r *http.Request
	if reqBody == nil {
		r = httptest.NewRequest(method, path, nil)
	} else {
		r = httptest.NewRequest(method, path, reqBody)
	}
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("%s %s = %d, want 200; body: %s", method, path, w.Code, w.Body.String())
	}
	if err := json.Unmarshal(w.Body.Bytes(), out); err != nil {
		t.Fatalf("decoding %s %s response: %v; body: %s", method, path, err, w.Body.String())
	}
}
