package ui

import (
	"database/sql"
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/callmeradical/sergeant/internal/store"

	_ "modernc.org/sqlite"
)

// retentionFixture opens a store and points SERGEANT_CONFIG at a fresh temp
// directory, so a test can write its own project YAML files without ever
// touching the operator's real config.
func retentionFixture(t *testing.T) (srv *Server, st *store.Store, configDir, dbPath string) {
	t.Helper()
	base := t.TempDir()
	configDir = filepath.Join(base, "config")
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SERGEANT_CONFIG", configDir)

	dbPath = filepath.Join(base, "t.db")
	var err error
	st, err = store.Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	return NewServer(st, 0), st, configDir, dbPath
}

func writeProjectYAML(t *testing.T, configDir, name, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(configDir, name+".yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

// backdateRunCreatedAt sets a run's created_at directly through a separate
// raw connection to the same database file — RotateProject's eligibility
// rule is keyed on created_at, and no public Store method can set it to
// anything but "now".
func backdateRunCreatedAt(t *testing.T, dbPath, runID string, when time.Time) {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(`UPDATE runs SET created_at = ? WHERE id = ?`, when, runID); err != nil {
		t.Fatalf("backdating run %q created_at: %v", runID, err)
	}
}

// spec.md: "A project with no retention block never rotates" — exercised
// against the real rotation loop (retentionRotator.rotateAll), not merely
// against RotateProject in isolation: a project with no Retention configured
// must never even be offered to RotateProject, regardless of how old its
// runs are.
func TestRetentionRotatorSkipsProjectWithNoRetentionConfigured(t *testing.T) {
	srv, st, configDir, dbPath := retentionFixture(t)

	writeProjectYAML(t, configDir, "no-retention", `
name: no-retention
repos:
  svc:
    path: /tmp/svc
`)
	writeProjectYAML(t, configDir, "with-retention", `
name: with-retention
repos:
  svc:
    path: /tmp/svc
retention:
  runs_after_days: 30
  artifacts_after_days: 7
`)

	const unconfiguredRun = "ancient-unconfigured"
	if err := st.CreateRun(&store.RunRecord{ID: unconfiguredRun, Project: "no-retention", TaskID: unconfiguredRun, Status: "passed"}); err != nil {
		t.Fatal(err)
	}
	backdateRunCreatedAt(t, dbPath, unconfiguredRun, time.Now().UTC().Add(-3650*24*time.Hour))

	const configuredRun = "ancient-configured"
	if err := st.CreateRun(&store.RunRecord{ID: configuredRun, Project: "with-retention", TaskID: configuredRun, Status: "passed"}); err != nil {
		t.Fatal(err)
	}
	backdateRunCreatedAt(t, dbPath, configuredRun, time.Now().UTC().Add(-3650*24*time.Hour))

	srv.retention.rotateAll()

	if _, err := st.GetRun(unconfiguredRun); err != nil {
		t.Errorf("expected run %q (project with no retention:) to survive, GetRun error: %v", unconfiguredRun, err)
	}
	if _, err := st.GetRun(configuredRun); err == nil {
		t.Errorf("expected run %q (project with retention: configured) to be rotated away", configuredRun)
	}
}

// spec.md: "A completed rotation pass is visible to an operator" — after a
// rotation pass, the project's analytics response reports the pass's
// timestamp and how many runs and artifacts were rotated, without an
// operator having to infer rotation happened by noticing data is missing.
func TestAnalyticsResponseReportsCompletedRotationPass(t *testing.T) {
	srv, st, configDir, dbPath := retentionFixture(t)

	writeProjectYAML(t, configDir, "observed", `
name: observed
repos:
  svc:
    path: /tmp/svc
retention:
  runs_after_days: 30
  artifacts_after_days: 7
`)

	const runID = "ancient-observed"
	if err := st.CreateRun(&store.RunRecord{ID: runID, Project: "observed", TaskID: runID, Status: "passed"}); err != nil {
		t.Fatal(err)
	}
	backdateRunCreatedAt(t, dbPath, runID, time.Now().UTC().Add(-3650*24*time.Hour))

	// Before any pass: retention is configured, but nothing has rotated yet.
	before := fetchAnalytics(t, srv, "observed")
	if before.Retention == nil {
		t.Fatal("expected a retention block for a project with retention: configured, even before the first pass")
	}
	if before.Retention.RunsRotated != 0 || before.Retention.LastRunAt != "" {
		t.Errorf("before rotation: Retention = %+v, want zero counts and empty timestamp", before.Retention)
	}

	srv.retention.rotateAll()

	after := fetchAnalytics(t, srv, "observed")
	if after.Retention == nil {
		t.Fatal("expected a retention block after a completed rotation pass")
	}
	if after.Retention.RunsRotated != 1 {
		t.Errorf("RunsRotated = %d, want 1", after.Retention.RunsRotated)
	}
	if after.Retention.LastRunAt == "" {
		t.Errorf("LastRunAt = %q, want a non-empty timestamp after a completed pass", after.Retention.LastRunAt)
	}
}

// A project with no retention: block never surfaces a retention key at all —
// "absent, not zero," the same convention Export/Graphify already use.
func TestAnalyticsResponseOmitsRetentionForUnconfiguredProject(t *testing.T) {
	srv, st, configDir, _ := retentionFixture(t)

	writeProjectYAML(t, configDir, "plain", `
name: plain
repos:
  svc:
    path: /tmp/svc
`)
	if err := st.CreateRun(&store.RunRecord{ID: "run-1", Project: "plain", TaskID: "run-1", Status: "passed"}); err != nil {
		t.Fatal(err)
	}

	got := fetchAnalytics(t, srv, "plain")
	if got.Retention != nil {
		t.Errorf("Retention = %+v, want nil for a project with no retention: block", got.Retention)
	}
}

func fetchAnalytics(t *testing.T, srv *Server, project string) analyticsResponse {
	t.Helper()
	req := httptest.NewRequest("GET", "/api/analytics?project="+project, nil)
	rec := httptest.NewRecorder()
	srv.handleAnalytics(rec, req)
	if rec.Code != 200 {
		t.Fatalf("handleAnalytics status = %d, body = %s", rec.Code, rec.Body.String())
	}
	var resp analyticsResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decoding analytics response: %v", err)
	}
	return resp
}
