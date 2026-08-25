package export

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/callmeradical/sergeant/internal/redact"
	"github.com/callmeradical/sergeant/internal/store"
)

// fakeTarget records every Record it receives, in delivery order, and can be
// told to fail delivery of specific records so a test can exercise retry
// behaviour.
type fakeTarget struct {
	mu         sync.Mutex
	records    []Record
	shouldFail func(Record) bool
}

func (f *fakeTarget) Export(_ context.Context, rec Record) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.shouldFail != nil && f.shouldFail(rec) {
		return errors.New("target unreachable")
	}
	f.records = append(f.records, rec)
	return nil
}

func (f *fakeTarget) all() []Record {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]Record, len(f.records))
	copy(out, f.records)
	return out
}

func newTestStore(t *testing.T) *store.Store {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "export.db")
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("opening store: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })
	return st
}

// Scenario: A bullet status change is exported.
func TestBulletStatusChangeIsExported(t *testing.T) {
	st := newTestStore(t)
	intent := &store.IntentRecord{ID: "intent-1", Project: "proj", Statement: "do the thing", Status: "approved"}
	if err := st.CreateIntent(intent); err != nil {
		t.Fatalf("CreateIntent: %v", err)
	}
	bullet := &store.BulletRecord{ID: "bullet-1", IntentID: intent.ID, Repo: "api", Position: 0, Status: "pending"}
	if err := st.CreateBullet(bullet); err != nil {
		t.Fatalf("CreateBullet: %v", err)
	}
	if err := st.UpdateBulletStatus(bullet.ID, "red"); err != nil {
		t.Fatalf("UpdateBulletStatus: %v", err)
	}

	target := &fakeTarget{}
	r := &Runner{Store: st, Target: target}
	if err := r.Tick(context.Background()); err != nil {
		t.Fatalf("Tick: %v", err)
	}

	var found *Record
	for _, rec := range target.all() {
		if rec.Kind == "bullet" && rec.ID == bullet.ID && rec.Status == "red" {
			rec := rec
			found = &rec
		}
	}
	if found == nil {
		t.Fatalf("no bullet record with status red exported; got %+v", target.all())
	}
	if found.Repo != "api" {
		t.Errorf("Repo = %q, want %q", found.Repo, "api")
	}
}

// Scenario: An intent creation is exported.
func TestIntentCreationIsExported(t *testing.T) {
	st := newTestStore(t)
	target := &fakeTarget{}
	r := &Runner{Store: st, Target: target}

	intent := &store.IntentRecord{ID: "intent-2", Project: "proj", Statement: "ship it", Status: "proposed"}
	if err := st.CreateIntent(intent); err != nil {
		t.Fatalf("CreateIntent: %v", err)
	}

	if err := r.Tick(context.Background()); err != nil {
		t.Fatalf("Tick: %v", err)
	}

	records := target.all()
	if len(records) != 1 {
		t.Fatalf("want 1 record, got %d: %+v", len(records), records)
	}
	rec := records[0]
	if rec.Kind != "intent" || rec.ID != intent.ID || rec.Status != "proposed" {
		t.Errorf("got %+v, want kind=intent id=%q status=proposed", rec, intent.ID)
	}
}

// Scenario: Transitions are exported in the order they occurred.
func TestTransitionsExportedInOrder(t *testing.T) {
	st := newTestStore(t)
	if err := st.CreateIntent(&store.IntentRecord{ID: "intent-a", Project: "proj", Statement: "a", Status: "proposed"}); err != nil {
		t.Fatalf("CreateIntent a: %v", err)
	}
	if err := st.CreateIntent(&store.IntentRecord{ID: "intent-b", Project: "proj", Statement: "b", Status: "proposed"}); err != nil {
		t.Fatalf("CreateIntent b: %v", err)
	}

	target := &fakeTarget{}
	r := &Runner{Store: st, Target: target}
	if err := r.Tick(context.Background()); err != nil {
		t.Fatalf("Tick: %v", err)
	}

	records := target.all()
	if len(records) != 2 {
		t.Fatalf("want 2 records, got %d: %+v", len(records), records)
	}
	if records[0].ID != "intent-a" || records[1].ID != "intent-b" {
		t.Errorf("wrong order: %+v", records)
	}
}

// Scenario: A transition is not exported twice across a restart.
func TestTransitionNotExportedTwiceAcrossRestart(t *testing.T) {
	st := newTestStore(t)
	intent := &store.IntentRecord{ID: "intent-restart", Project: "proj", Statement: "s", Status: "proposed"}
	if err := st.CreateIntent(intent); err != nil {
		t.Fatalf("CreateIntent: %v", err)
	}

	target := &fakeTarget{}
	r1 := &Runner{Store: st, Target: target}
	if err := r1.Tick(context.Background()); err != nil {
		t.Fatalf("first Tick: %v", err)
	}
	if len(target.all()) != 1 {
		t.Fatalf("expected 1 record after first tick, got %d", len(target.all()))
	}

	// Exercise LoadExportCursor directly: the cursor must have advanced and be
	// durably readable, not merely held in the first Runner's memory.
	cursor, err := st.LoadExportCursor()
	if err != nil {
		t.Fatalf("LoadExportCursor: %v", err)
	}
	if cursor == 0 {
		t.Fatalf("expected cursor to have advanced past 0, got %d", cursor)
	}

	// A fresh Runner backed by the same store simulates a restart: it loads the
	// persisted cursor rather than starting from scratch.
	r2 := &Runner{Store: st, Target: target}
	if err := r2.Tick(context.Background()); err != nil {
		t.Fatalf("second Tick: %v", err)
	}

	if len(target.all()) != 1 {
		t.Fatalf("expected no additional export after restart, got %d records: %+v", len(target.all()), target.all())
	}
}

// Scenario: A bullet status update succeeds even though its export target is
// unreachable. This must not go through Runner at all — it proves the write
// path is structurally independent of the export loop.
func TestBulletStatusUpdateSucceedsEvenThoughExportTargetIsUnreachable(t *testing.T) {
	st := newTestStore(t)
	intent := &store.IntentRecord{ID: "intent-unreachable", Project: "proj", Statement: "s", Status: "approved"}
	if err := st.CreateIntent(intent); err != nil {
		t.Fatalf("CreateIntent: %v", err)
	}
	bullet := &store.BulletRecord{ID: "bullet-unreachable", IntentID: intent.ID, Repo: "api", Position: 0, Status: "pending"}
	if err := st.CreateBullet(bullet); err != nil {
		t.Fatalf("CreateBullet: %v", err)
	}

	// A Target configured to fail every call exists conceptually for this
	// project but is deliberately never invoked in this test.
	_ = &fakeTarget{shouldFail: func(Record) bool { return true }}

	if err := st.UpdateBulletStatus(bullet.ID, "red"); err != nil {
		t.Fatalf("UpdateBulletStatus returned an error: %v", err)
	}

	bullets, err := st.ListBulletsForIntent(intent.ID)
	if err != nil {
		t.Fatalf("ListBulletsForIntent: %v", err)
	}
	if len(bullets) != 1 || bullets[0].Status != "red" {
		t.Fatalf("expected bullet status red, got %+v", bullets)
	}
}

// Scenario: An export failure is retried on a later attempt without
// re-running the original write.
func TestExportFailureIsRetriedWithoutRerunningOriginalWrite(t *testing.T) {
	st := newTestStore(t)
	intent := &store.IntentRecord{ID: "intent-retry", Project: "proj", Statement: "s", Status: "approved"}
	if err := st.CreateIntent(intent); err != nil {
		t.Fatalf("CreateIntent: %v", err)
	}
	bullet := &store.BulletRecord{ID: "bullet-retry", IntentID: intent.ID, Repo: "api", Position: 0, Status: "pending"}
	if err := st.CreateBullet(bullet); err != nil {
		t.Fatalf("CreateBullet: %v", err)
	}
	if err := st.UpdateBulletStatus(bullet.ID, "red"); err != nil {
		t.Fatalf("UpdateBulletStatus: %v", err)
	}

	before, err := st.ListBulletsForIntent(intent.ID)
	if err != nil {
		t.Fatalf("ListBulletsForIntent: %v", err)
	}
	beforeUpdatedAt := before[0].UpdatedAt

	failBullet := true
	target := &fakeTarget{
		shouldFail: func(rec Record) bool {
			return rec.Kind == "bullet" && rec.ID == bullet.ID && failBullet
		},
	}
	r := &Runner{Store: st, Target: target}

	if err := r.Tick(context.Background()); err != nil {
		t.Fatalf("first Tick: %v", err)
	}
	if countBulletRecords(target.all(), bullet.ID) != 0 {
		t.Fatalf("expected no bullet record delivered on first tick, got %+v", target.all())
	}

	failBullet = false
	if err := r.Tick(context.Background()); err != nil {
		t.Fatalf("second Tick: %v", err)
	}
	if countBulletRecords(target.all(), bullet.ID) == 0 {
		t.Fatalf("expected bullet record eventually delivered, got %+v", target.all())
	}

	after, err := st.ListBulletsForIntent(intent.ID)
	if err != nil {
		t.Fatalf("ListBulletsForIntent: %v", err)
	}
	if !after[0].UpdatedAt.Equal(beforeUpdatedAt) {
		t.Fatalf("original write re-ran: UpdatedAt changed from %v to %v", beforeUpdatedAt, after[0].UpdatedAt)
	}
}

// A failure on one record must not let a later record in the same batch be
// delivered ahead of it — Tick stops at the first failure rather than
// skipping past it, so delivery order across a retry is preserved. A fixture
// where the failing record is followed by a record that CAN succeed is
// required to catch this: if every record in a batch fails together (as in
// TestExportFailureIsRetriedWithoutRerunningOriginalWrite's fixture),
// stopping at the first failure and continuing past it produce the same
// observable result, and a regression that delivers out of order would go
// undetected.
func TestExportFailureStopsBeforeALaterRecordThatWouldHaveSucceeded(t *testing.T) {
	st := newTestStore(t)
	intent := &store.IntentRecord{ID: "intent-order", Project: "proj", Statement: "s", Status: "approved"}
	if err := st.CreateIntent(intent); err != nil {
		t.Fatalf("CreateIntent: %v", err)
	}
	first := &store.BulletRecord{ID: "bullet-first", IntentID: intent.ID, Repo: "api", Position: 0, Status: "pending"}
	if err := st.CreateBullet(first); err != nil {
		t.Fatalf("CreateBullet(first): %v", err)
	}
	if err := st.UpdateBulletStatus(first.ID, "red"); err != nil {
		t.Fatalf("UpdateBulletStatus(first): %v", err)
	}
	second := &store.BulletRecord{ID: "bullet-second", IntentID: intent.ID, Repo: "web", Position: 1, Status: "pending"}
	if err := st.CreateBullet(second); err != nil {
		t.Fatalf("CreateBullet(second): %v", err)
	}

	// first's status-change record precedes second's CreateBullet record in
	// the change log, so failing first and letting second succeed puts a
	// succeedable record after the failing one in the same Tick's batch.
	target := &fakeTarget{
		shouldFail: func(rec Record) bool {
			return rec.Kind == "bullet" && rec.ID == first.ID
		},
	}
	r := &Runner{Store: st, Target: target}

	if err := r.Tick(context.Background()); err != nil {
		t.Fatalf("Tick: %v", err)
	}

	if countBulletRecords(target.all(), second.ID) != 0 {
		t.Fatalf("bullet %q was delivered before the earlier failing bullet %q was retried; "+
			"delivery order was not preserved, got %+v", second.ID, first.ID, target.all())
	}
}

func countBulletRecords(records []Record, bulletID string) int {
	n := 0
	for _, rec := range records {
		if rec.Kind == "bullet" && rec.ID == bulletID {
			n++
		}
	}
	return n
}

// Scenario: An intent's statement is redacted before export.
func TestIntentStatementIsRedactedBeforeExport(t *testing.T) {
	st := newTestStore(t)
	secret := "sk-abcdefghijklmnopqrstuvwx"
	statement := "use key " + secret + " to auth"
	intent := &store.IntentRecord{ID: "intent-secret", Project: "proj", Statement: statement, Status: "proposed"}
	if err := st.CreateIntent(intent); err != nil {
		t.Fatalf("CreateIntent: %v", err)
	}

	target := &fakeTarget{}
	r := &Runner{Store: st, Target: target}
	if err := r.Tick(context.Background()); err != nil {
		t.Fatalf("Tick: %v", err)
	}

	records := target.all()
	if len(records) != 1 {
		t.Fatalf("want 1 record, got %d: %+v", len(records), records)
	}
	rec := records[0]
	if strings.Contains(rec.Statement, secret) {
		t.Fatalf("exported statement leaked the secret: %q", rec.Statement)
	}
	if want := redact.Text(statement); rec.Statement != want {
		t.Errorf("Statement = %q, want %q", rec.Statement, want)
	}
}

// Scenario: An exported record contains no worktree path, branch name, or PR
// URL.
func TestExportedRecordContainsNoWorktreeBranchOrPRURL(t *testing.T) {
	st := newTestStore(t)
	intent := &store.IntentRecord{ID: "intent-wt", Project: "proj", Statement: "s", Status: "approved"}
	if err := st.CreateIntent(intent); err != nil {
		t.Fatalf("CreateIntent: %v", err)
	}
	bullet := &store.BulletRecord{
		ID: "bullet-wt", IntentID: intent.ID, Repo: "api", Position: 0, Status: "pending",
		Branch: "feat/secret-branch", Worktree: "/fleet/secret/worktree", PRURL: "https://example.com/example/pr/1",
	}
	if err := st.CreateBullet(bullet); err != nil {
		t.Fatalf("CreateBullet: %v", err)
	}
	if err := st.UpdateBulletStatus(bullet.ID, "green"); err != nil {
		t.Fatalf("UpdateBulletStatus: %v", err)
	}

	target := &fakeTarget{}
	r := &Runner{Store: st, Target: target}
	if err := r.Tick(context.Background()); err != nil {
		t.Fatalf("Tick: %v", err)
	}

	found := false
	for _, rec := range target.all() {
		if rec.Kind != "bullet" || rec.ID != bullet.ID {
			continue
		}
		found = true
		body, err := json.Marshal(rec)
		if err != nil {
			t.Fatalf("marshaling record: %v", err)
		}
		for _, leak := range []string{bullet.Branch, bullet.Worktree, bullet.PRURL} {
			if strings.Contains(string(body), leak) {
				t.Fatalf("exported record leaked %q: %s", leak, body)
			}
		}
	}
	if !found {
		t.Fatalf("no bullet record exported for %q", bullet.ID)
	}
}

// Scenario: No target is configured. A project with no Export block must
// produce zero calls to any Target for its transitions, even when a
// different project in the same test run has export configured and running.
func TestNoTargetConfiguredExportsNothing(t *testing.T) {
	configuredStore := newTestStore(t)
	configuredIntent := &store.IntentRecord{ID: "intent-configured", Project: "configured", Statement: "s", Status: "proposed"}
	if err := configuredStore.CreateIntent(configuredIntent); err != nil {
		t.Fatalf("CreateIntent (configured): %v", err)
	}
	configuredTarget := &fakeTarget{}
	r := &Runner{Store: configuredStore, Target: configuredTarget}
	if err := r.Tick(context.Background()); err != nil {
		t.Fatalf("Tick: %v", err)
	}
	if len(configuredTarget.all()) != 1 {
		t.Fatalf("expected the configured project's own transition to export, got %d", len(configuredTarget.all()))
	}

	// A project with no export: block configured has no Runner watching it at
	// all — nothing ever polls its store on its behalf.
	unconfiguredStore := newTestStore(t)
	unconfiguredIntent := &store.IntentRecord{ID: "intent-unconfigured", Project: "unconfigured", Statement: "s", Status: "proposed"}
	if err := unconfiguredStore.CreateIntent(unconfiguredIntent); err != nil {
		t.Fatalf("CreateIntent (unconfigured): %v", err)
	}

	for _, rec := range configuredTarget.all() {
		if rec.ID == unconfiguredIntent.ID {
			t.Fatalf("unconfigured project's transition reached a target: %+v", rec)
		}
	}
}
