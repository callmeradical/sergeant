package store

import (
	"encoding/json"
	"path/filepath"
	"testing"
	"time"
)

func TestStoreOperations(t *testing.T) {
	tempDir := t.TempDir()
	dbPath := filepath.Join(tempDir, "test.db")

	st, err := Open(dbPath)
	if err != nil {
		t.Fatalf("failed to open store: %v", err)
	}
	defer st.Close()

	run := &RunRecord{
		ID:      "run-123",
		Project: "test-proj",
		TaskID:  "task-123",
		Status:  "running",
	}
	if err := st.CreateRun(run); err != nil {
		t.Fatalf("failed to create run: %v", err)
	}

	phase := &PhaseRecord{
		ID:         "phase-1",
		RunID:      "run-123",
		Repo:       "backend",
		Name:       "test",
		Kind:       "code",
		Status:     "passed",
		DurationMs: 120,
	}
	if err := st.RecordPhase(phase); err != nil {
		t.Fatalf("failed to record phase: %v", err)
	}

	env := &EnvelopeRecord{
		ID:        "env-1",
		RunID:     "run-123",
		Repo:      "backend",
		Stage:     "build",
		Summary:   "Built payment API",
		Artifacts: []string{"openapi.json"},
		Data:      json.RawMessage(`{"endpoints": ["/pay"]}`),
	}
	if err := st.RecordEnvelope(env); err != nil {
		t.Fatalf("failed to record envelope: %v", err)
	}

	retrieved, err := st.GetLatestEnvelope("run-123", "backend")
	if err != nil {
		t.Fatalf("failed to get envelope: %v", err)
	}
	if retrieved.Summary != "Built payment API" {
		t.Errorf("expected summary 'Built payment API', got %s", retrieved.Summary)
	}
	if len(retrieved.Artifacts) != 1 || retrieved.Artifacts[0] != "openapi.json" {
		t.Errorf("unexpected artifacts: %v", retrieved.Artifacts)
	}

	if err := st.UpdateRunStatus("run-123", "passed"); err != nil {
		t.Fatalf("failed to update run status: %v", err)
	}

	runs, err := st.ListRecentRuns(5)
	if err != nil {
		t.Fatalf("failed to list runs: %v", err)
	}
	if len(runs) != 1 || runs[0].Status != "passed" {
		t.Errorf("unexpected run status: %v", runs)
	}
}

func openTestStore(t *testing.T) (*Store, string) {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "test.db")
	st, err := Open(dbPath)
	if err != nil {
		t.Fatalf("failed to open store: %v", err)
	}
	t.Cleanup(func() { st.Close() })
	return st, dbPath
}

// An intent may span repositories. The bullets carry the merge order, so
// ListBulletsForIntent must return them by Position and not by insertion order.
func TestListBulletsForIntentReturnsMergeOrder(t *testing.T) {
	st, _ := openTestStore(t)

	intent := &IntentRecord{
		ID:        "intent-1",
		Project:   "payments",
		Statement: "Charge cards through the new processor",
		Status:    "approved",
	}
	if err := st.CreateIntent(intent); err != nil {
		t.Fatalf("failed to create intent: %v", err)
	}

	// Inserted second-first, so passing this test cannot be an accident of
	// insertion order.
	second := &BulletRecord{ID: "bullet-web", IntentID: "intent-1", Repo: "web", Position: 2, Status: "pending"}
	first := &BulletRecord{ID: "bullet-api", IntentID: "intent-1", Repo: "api", Position: 1, Status: "pending"}
	for _, b := range []*BulletRecord{second, first} {
		if err := st.CreateBullet(b); err != nil {
			t.Fatalf("failed to create bullet %s: %v", b.ID, err)
		}
	}

	bullets, err := st.ListBulletsForIntent("intent-1")
	if err != nil {
		t.Fatalf("failed to list bullets: %v", err)
	}
	if len(bullets) != 2 {
		t.Fatalf("expected 2 bullets, got %d", len(bullets))
	}
	if bullets[0].ID != "bullet-api" || bullets[1].ID != "bullet-web" {
		t.Errorf("bullets not in merge order: got %s then %s", bullets[0].ID, bullets[1].ID)
	}
	if bullets[0].Position != 1 || bullets[1].Position != 2 {
		t.Errorf("unexpected positions: %d then %d", bullets[0].Position, bullets[1].Position)
	}
	if bullets[0].Repo != "api" || bullets[1].Repo != "web" {
		t.Errorf("unexpected repos: %q then %q", bullets[0].Repo, bullets[1].Repo)
	}

	intents, err := st.ListIntentsForProject("payments")
	if err != nil {
		t.Fatalf("failed to list intents: %v", err)
	}
	if len(intents) != 1 || intents[0].Statement != "Charge cards through the new processor" {
		t.Errorf("unexpected intents: %v", intents)
	}
	if got, err := st.GetIntent("intent-1"); err != nil {
		t.Fatalf("failed to get intent: %v", err)
	} else if got.Status != "approved" {
		t.Errorf("expected status approved, got %s", got.Status)
	}
}

// A bullet is scoped to exactly one repository. Repo is a single string, not a
// list, so work in a second repository is necessarily a second bullet.
func TestBulletIsScopedToExactlyOneRepo(t *testing.T) {
	st, _ := openTestStore(t)

	if err := st.CreateIntent(&IntentRecord{
		ID:        "intent-2",
		Project:   "payments",
		Statement: "Show refund state in the dashboard",
		Status:    "approved",
	}); err != nil {
		t.Fatalf("failed to create intent: %v", err)
	}

	// The API change and the web change are the same intent but two bullets,
	// because a commit and a PR are per repository.
	apiWork := &BulletRecord{ID: "bullet-2-api", IntentID: "intent-2", Repo: "api", Position: 1, Status: "pending"}
	if err := st.CreateBullet(apiWork); err != nil {
		t.Fatalf("failed to create api bullet: %v", err)
	}
	webWork := &BulletRecord{ID: "bullet-2-web", IntentID: "intent-2", Repo: "web", Position: 2, Status: "pending"}
	if err := st.CreateBullet(webWork); err != nil {
		t.Fatalf("failed to create web bullet: %v", err)
	}

	bullets, err := st.ListBulletsForIntent("intent-2")
	if err != nil {
		t.Fatalf("failed to list bullets: %v", err)
	}
	if len(bullets) != 2 {
		t.Fatalf("two repos must mean two bullets, got %d", len(bullets))
	}
	seen := map[string]int{}
	for _, b := range bullets {
		if b.Repo == "" {
			t.Errorf("bullet %s has no repo", b.ID)
		}
		seen[b.Repo]++
	}
	for repo, n := range seen {
		if n != 1 {
			t.Errorf("repo %s appears in %d bullets of one intent; expected 1", repo, n)
		}
	}
	if len(seen) != 2 {
		t.Errorf("expected 2 distinct repos across the bullets, got %d", len(seen))
	}
}

// Reopening a database must not lose the intents and bullets tables. This is the
// case that broke before: CREATE TABLE IF NOT EXISTS is a no-op on an existing
// database, so a database written by an older build has to be repaired on open.
func TestIntentAndBulletTablesSurviveReopen(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "reopen.db")

	st, err := Open(dbPath)
	if err != nil {
		t.Fatalf("first open failed: %v", err)
	}
	if err := st.CreateIntent(&IntentRecord{ID: "intent-3", Project: "p", Statement: "keep me", Status: "proposed"}); err != nil {
		t.Fatalf("failed to create intent: %v", err)
	}
	if err := st.Close(); err != nil {
		t.Fatalf("first close failed: %v", err)
	}

	reopened, err := Open(dbPath)
	if err != nil {
		t.Fatalf("reopen failed: %v", err)
	}
	defer reopened.Close()

	got, err := reopened.GetIntent("intent-3")
	if err != nil {
		t.Fatalf("intent did not survive reopen: %v", err)
	}
	if got.Statement != "keep me" {
		t.Errorf("unexpected statement after reopen: %q", got.Statement)
	}
	if err := reopened.CreateBullet(&BulletRecord{ID: "bullet-3", IntentID: "intent-3", Repo: "api", Position: 1, Status: "pending"}); err != nil {
		t.Fatalf("bullets table unusable after reopen: %v", err)
	}
}

// A database created before intents and bullets existed has neither table. Open
// must add them rather than leaving every intent query broken.
func TestOpenAddsIntentAndBulletTablesToAnOlderDatabase(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "legacy.db")

	st, err := Open(dbPath)
	if err != nil {
		t.Fatalf("first open failed: %v", err)
	}
	// Simulate the older schema by removing the tables that build did not have.
	for _, table := range []string{"bullets", "intents"} {
		if _, err := st.db.Exec("DROP TABLE " + table); err != nil {
			t.Fatalf("failed to drop %s: %v", table, err)
		}
	}
	if err := st.Close(); err != nil {
		t.Fatalf("close failed: %v", err)
	}

	upgraded, err := Open(dbPath)
	if err != nil {
		t.Fatalf("reopen of older database failed: %v", err)
	}
	defer upgraded.Close()

	for _, table := range []string{"intents", "bullets"} {
		has, err := upgraded.hasTable(table)
		if err != nil {
			t.Fatalf("checking %s: %v", table, err)
		}
		if !has {
			t.Fatalf("table %s was not created on open", table)
		}
	}

	if err := upgraded.CreateIntent(&IntentRecord{ID: "intent-4", Project: "p", Statement: "s", Status: "proposed"}); err != nil {
		t.Fatalf("intents table unusable after upgrade: %v", err)
	}
	if err := upgraded.CreateBullet(&BulletRecord{ID: "bullet-4", IntentID: "intent-4", Repo: "api", Position: 1, Status: "pending"}); err != nil {
		t.Fatalf("bullets table unusable after upgrade: %v", err)
	}
	bullets, err := upgraded.ListBulletsForIntent("intent-4")
	if err != nil {
		t.Fatalf("failed to list bullets after upgrade: %v", err)
	}
	if len(bullets) != 1 {
		t.Fatalf("expected 1 bullet, got %d", len(bullets))
	}
}

// Decision O3 stores the resolved OpenSpec change on the run. A database created
// before that column existed must gain it on open, or every run query naming it
// fails and dispatch stops working against an existing installation.
func TestOpenAddsRunChangeIDToAnOlderDatabase(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "legacy-runs.db")

	st, err := Open(dbPath)
	if err != nil {
		t.Fatalf("first open failed: %v", err)
	}
	// Simulate the older schema: a runs table with no change_id column.
	if _, err := st.db.Exec("DROP TABLE runs"); err != nil {
		t.Fatalf("dropping runs: %v", err)
	}
	if _, err := st.db.Exec(`CREATE TABLE runs (
		id TEXT PRIMARY KEY,
		project TEXT NOT NULL,
		task_id TEXT NOT NULL,
		status TEXT NOT NULL,
		brief TEXT NOT NULL DEFAULT '',
		created_at DATETIME NOT NULL,
		updated_at DATETIME NOT NULL
	)`); err != nil {
		t.Fatalf("recreating legacy runs: %v", err)
	}
	if _, err := st.db.Exec(
		`INSERT INTO runs (id, project, task_id, status, brief, created_at, updated_at) VALUES ('old', 'p', 'old', 'passed', 'legacy brief', ?, ?)`,
		time.Now().UTC(), time.Now().UTC(),
	); err != nil {
		t.Fatalf("seeding legacy run: %v", err)
	}
	if err := st.Close(); err != nil {
		t.Fatalf("close failed: %v", err)
	}

	upgraded, err := Open(dbPath)
	if err != nil {
		t.Fatalf("reopen of older database failed: %v", err)
	}
	defer upgraded.Close()

	has, err := upgraded.hasColumn("runs", "change_id")
	if err != nil {
		t.Fatalf("checking runs.change_id: %v", err)
	}
	if !has {
		t.Fatal("runs.change_id was not added on open")
	}

	if err := upgraded.CreateRun(&RunRecord{
		ID: "new", Project: "p", TaskID: "new", Brief: "b", ChangeID: "add-stripe-webhooks", Status: "running",
	}); err != nil {
		t.Fatalf("runs table unusable after upgrade: %v", err)
	}

	runs, err := upgraded.ListRunsForProject("p", 10)
	if err != nil {
		t.Fatalf("listing runs after upgrade: %v", err)
	}
	byID := map[string]RunRecord{}
	for _, r := range runs {
		byID[r.ID] = r
	}
	if got := byID["new"].ChangeID; got != "add-stripe-webhooks" {
		t.Errorf("new run ChangeID = %q, want add-stripe-webhooks", got)
	}
	// The pre-existing row has no change; it must read as empty, not as a claim.
	if got := byID["old"].ChangeID; got != "" {
		t.Errorf("legacy run ChangeID = %q, want empty", got)
	}
	if got := byID["old"].Brief; got != "legacy brief" {
		t.Errorf("legacy run Brief = %q, want %q", got, "legacy brief")
	}
}

func TestUpdateStatusMovesStatusAndBumpsUpdatedAt(t *testing.T) {
	st, _ := openTestStore(t)

	intent := &IntentRecord{ID: "intent-5", Project: "p", Statement: "s", Status: "proposed"}
	if err := st.CreateIntent(intent); err != nil {
		t.Fatalf("failed to create intent: %v", err)
	}
	bullet := &BulletRecord{ID: "bullet-5", IntentID: "intent-5", Repo: "api", Position: 1, Status: "pending"}
	if err := st.CreateBullet(bullet); err != nil {
		t.Fatalf("failed to create bullet: %v", err)
	}

	// UpdatedAt is compared against the stored value, so the clock has to move.
	time.Sleep(10 * time.Millisecond)

	if err := st.UpdateIntentStatus("intent-5", "in_progress"); err != nil {
		t.Fatalf("failed to update intent status: %v", err)
	}
	movedIntent, err := st.GetIntent("intent-5")
	if err != nil {
		t.Fatalf("failed to get intent: %v", err)
	}
	if movedIntent.Status != "in_progress" {
		t.Errorf("expected intent status in_progress, got %s", movedIntent.Status)
	}
	if !movedIntent.UpdatedAt.After(intent.UpdatedAt) {
		t.Errorf("intent UpdatedAt did not advance: %v not after %v", movedIntent.UpdatedAt, intent.UpdatedAt)
	}
	if !movedIntent.CreatedAt.Equal(intent.CreatedAt) {
		t.Errorf("intent CreatedAt changed: %v became %v", intent.CreatedAt, movedIntent.CreatedAt)
	}

	if err := st.UpdateBulletStatus("bullet-5", "green"); err != nil {
		t.Fatalf("failed to update bullet status: %v", err)
	}
	bullets, err := st.ListBulletsForIntent("intent-5")
	if err != nil {
		t.Fatalf("failed to list bullets: %v", err)
	}
	if len(bullets) != 1 {
		t.Fatalf("expected 1 bullet, got %d", len(bullets))
	}
	if bullets[0].Status != "green" {
		t.Errorf("expected bullet status green, got %s", bullets[0].Status)
	}
	if !bullets[0].UpdatedAt.After(bullet.UpdatedAt) {
		t.Errorf("bullet UpdatedAt did not advance: %v not after %v", bullets[0].UpdatedAt, bullet.UpdatedAt)
	}
	if !bullets[0].CreatedAt.Equal(bullet.CreatedAt) {
		t.Errorf("bullet CreatedAt changed: %v became %v", bullet.CreatedAt, bullets[0].CreatedAt)
	}
}

// Reporting success for a status move that touched no row would be a claim the
// store cannot support.
func TestUpdateStatusOnUnknownIDIsAnError(t *testing.T) {
	st, _ := openTestStore(t)

	if err := st.UpdateIntentStatus("missing-intent", "satisfied"); err == nil {
		t.Error("expected an error updating an unknown intent")
	}
	if err := st.UpdateBulletStatus("missing-bullet", "merged"); err == nil {
		t.Error("expected an error updating an unknown bullet")
	}
}
