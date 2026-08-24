package store

import (
	"path/filepath"
	"testing"
	"time"
)

// Decision O2: a run's and a proposed plan's work type is a durable, queryable
// fact, not derived only from a branch name after the fact. Every query naming
// other columns on runs/intents must read and write type too, or it is
// silently dropped for one caller while another sees it.
func TestCreateRunPersistsType(t *testing.T) {
	st, _ := openTestStore(t)

	if err := st.CreateRun(&RunRecord{
		ID: "run-type-1", Project: "p", TaskID: "run-type-1", Status: "running",
		Type: "fix", ChangeID: "add-stripe-webhooks",
	}); err != nil {
		t.Fatal(err)
	}

	got, err := st.GetRun("run-type-1")
	if err != nil {
		t.Fatal(err)
	}
	if got.Type != "fix" {
		t.Errorf("GetRun.Type = %q, want fix", got.Type)
	}

	listed, err := st.ListRunsForProject("p", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(listed) != 1 || listed[0].Type != "fix" {
		t.Errorf("ListRunsForProject = %+v, want one run with Type=fix", listed)
	}

	recent, err := st.ListRecentRuns(10)
	if err != nil {
		t.Fatal(err)
	}
	if len(recent) != 1 || recent[0].Type != "fix" {
		t.Errorf("ListRecentRuns = %+v, want one run with Type=fix", recent)
	}
}

func TestCreateIntentPersistsType(t *testing.T) {
	st, _ := openTestStore(t)

	if err := st.CreateIntent(&IntentRecord{
		ID: "intent-type-1", Project: "p", Statement: "s", Status: "proposed",
		Type: "docs",
	}); err != nil {
		t.Fatal(err)
	}

	got, err := st.GetIntent("intent-type-1")
	if err != nil {
		t.Fatal(err)
	}
	if got.Type != "docs" {
		t.Errorf("GetIntent.Type = %q, want docs", got.Type)
	}

	byProject, err := st.ListIntentsForProject("p")
	if err != nil {
		t.Fatal(err)
	}
	if len(byProject) != 1 || byProject[0].Type != "docs" {
		t.Errorf("ListIntentsForProject = %+v, want one intent with Type=docs", byProject)
	}

	byStatus, err := st.ListIntentsByStatus("proposed")
	if err != nil {
		t.Fatal(err)
	}
	if len(byStatus) != 1 || byStatus[0].Type != "docs" {
		t.Errorf("ListIntentsByStatus = %+v, want one intent with Type=docs", byStatus)
	}
}

// A database created before this change has no runs.type/intents.type column.
// Reopening it must add both, the same additive pattern as change_id/slug.
func TestOpenAddsTypeColumnsToAnOlderDatabase(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "legacy-type.db")

	st, err := Open(dbPath)
	if err != nil {
		t.Fatalf("first open failed: %v", err)
	}
	if _, err := st.db.Exec("DROP TABLE runs"); err != nil {
		t.Fatalf("dropping runs: %v", err)
	}
	if _, err := st.db.Exec(`CREATE TABLE runs (
		id TEXT PRIMARY KEY,
		project TEXT NOT NULL,
		task_id TEXT NOT NULL,
		status TEXT NOT NULL,
		brief TEXT NOT NULL DEFAULT '',
		slug TEXT NOT NULL DEFAULT '',
		change_id TEXT NOT NULL DEFAULT '',
		intent_id TEXT NOT NULL DEFAULT '',
		created_at DATETIME NOT NULL,
		updated_at DATETIME NOT NULL
	)`); err != nil {
		t.Fatalf("recreating legacy runs: %v", err)
	}
	if _, err := st.db.Exec(
		`INSERT INTO runs (id, project, task_id, status, brief, slug, change_id, intent_id, created_at, updated_at)
		 VALUES ('old', 'p', 'old', 'passed', 'legacy brief', 'oldly-old-ox', 'legacy-change', '', ?, ?)`,
		time.Now().UTC(), time.Now().UTC(),
	); err != nil {
		t.Fatalf("seeding legacy run: %v", err)
	}
	if _, err := st.db.Exec("DROP TABLE intents"); err != nil {
		t.Fatalf("dropping intents: %v", err)
	}
	if _, err := st.db.Exec(`CREATE TABLE intents (
		id TEXT PRIMARY KEY,
		project TEXT NOT NULL,
		statement TEXT NOT NULL,
		status TEXT NOT NULL,
		change_id TEXT NOT NULL DEFAULT '',
		change_repo TEXT NOT NULL DEFAULT '',
		created_at DATETIME NOT NULL,
		updated_at DATETIME NOT NULL
	)`); err != nil {
		t.Fatalf("recreating legacy intents: %v", err)
	}
	if _, err := st.db.Exec(
		`INSERT INTO intents (id, project, statement, status, change_id, change_repo, created_at, updated_at)
		 VALUES ('old-intent', 'p', 'legacy statement', 'proposed', 'legacy-change', 'svc', ?, ?)`,
		time.Now().UTC(), time.Now().UTC(),
	); err != nil {
		t.Fatalf("seeding legacy intent: %v", err)
	}
	if err := st.Close(); err != nil {
		t.Fatalf("close failed: %v", err)
	}

	upgraded, err := Open(dbPath)
	if err != nil {
		t.Fatalf("reopen of older database failed: %v", err)
	}
	defer upgraded.Close()

	if has, err := upgraded.hasColumn("runs", "type"); err != nil || !has {
		t.Fatalf("runs.type was not added on open (has=%v, err=%v)", has, err)
	}
	if has, err := upgraded.hasColumn("intents", "type"); err != nil || !has {
		t.Fatalf("intents.type was not added on open (has=%v, err=%v)", has, err)
	}

	oldRun, err := upgraded.GetRun("old")
	if err != nil {
		t.Fatalf("reading legacy run after upgrade: %v", err)
	}
	if oldRun.Type != "" {
		t.Errorf("legacy run Type = %q, want empty — nothing to backfill", oldRun.Type)
	}

	oldIntent, err := upgraded.GetIntent("old-intent")
	if err != nil {
		t.Fatalf("reading legacy intent after upgrade: %v", err)
	}
	if oldIntent.Type != "" {
		t.Errorf("legacy intent Type = %q, want empty — nothing to backfill", oldIntent.Type)
	}

	if err := upgraded.CreateRun(&RunRecord{
		ID: "new-run", Project: "p", TaskID: "new-run", Status: "running", Type: "chore", ChangeID: "c",
	}); err != nil {
		t.Fatalf("runs table unusable after upgrade: %v", err)
	}
	newRun, err := upgraded.GetRun("new-run")
	if err != nil {
		t.Fatal(err)
	}
	if newRun.Type != "chore" {
		t.Errorf("new run Type = %q, want chore", newRun.Type)
	}
}
