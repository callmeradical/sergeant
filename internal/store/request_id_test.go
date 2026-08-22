package store

import (
	"database/sql"
	"errors"
	"path/filepath"
	"testing"
	"time"
)

// A dispatch is idempotent under a caller-supplied key (decision D10, adopted
// from AHP's runAutomation). The guarantee belongs to the database, not to a
// handler: two concurrent POSTs that both looked before they inserted would both
// see nothing and both insert. A unique index cannot be raced, so these tests
// assert on CreateRun's behaviour rather than on any caller's discipline.

// Scenario: A repeated key returns the original run — the store half. The second
// insert must be refused, and refused in a way the caller can classify, because
// a generic error is indistinguishable from a disk failure and would have to be
// answered with a 500 rather than the original run.
func TestCreateRunWithARepeatedRequestIDIsRefusedAsADuplicate(t *testing.T) {
	st, _ := openTestStore(t)

	first := &RunRecord{ID: "sgt-1", Project: "p", TaskID: "sgt-1", Status: "running", RequestID: "retry-me"}
	if err := st.CreateRun(first); err != nil {
		t.Fatalf("first run with a request id was refused: %v", err)
	}

	second := &RunRecord{ID: "sgt-2", Project: "p", TaskID: "sgt-2", Status: "running", RequestID: "retry-me"}
	err := st.CreateRun(second)
	if err == nil {
		t.Fatal("a repeated request id was accepted; the unique index is missing")
	}
	if !errors.Is(err, ErrDuplicateRequestID) {
		t.Fatalf("CreateRun error = %v, want it to wrap ErrDuplicateRequestID so the caller can return the original run", err)
	}

	runs, err := st.ListRecentRuns(50)
	if err != nil {
		t.Fatal(err)
	}
	if len(runs) != 1 {
		t.Fatalf("store holds %d runs for one request id, want 1: %+v", len(runs), runs)
	}
	if runs[0].ID != "sgt-1" {
		t.Errorf("surviving run = %q, want the first one (sgt-1)", runs[0].ID)
	}
}

// Scenario: An omitted key remains valid. Two absent keys must not deduplicate
// against each other. SQLite treats NULL as distinct in a unique index and the
// empty string as equal to itself, so this passes only if the absent case is
// stored as NULL.
func TestRunsWithNoRequestIDNeverCollide(t *testing.T) {
	st, _ := openTestStore(t)

	for i, id := range []string{"sgt-a", "sgt-b", "sgt-c"} {
		if err := st.CreateRun(&RunRecord{ID: id, Project: "p", TaskID: id, Status: "running"}); err != nil {
			t.Fatalf("run %d with no request id was refused: %v", i+1, err)
		}
	}

	runs, err := st.ListRecentRuns(50)
	if err != nil {
		t.Fatal(err)
	}
	if len(runs) != 3 {
		t.Fatalf("store holds %d runs, want 3: %+v", len(runs), runs)
	}
}

// The absent case is stored as SQL NULL, never as ”. This is asserted against
// the column directly rather than through the Go API, because ” and NULL are
// indistinguishable once COALESCE has read them back — and the difference is the
// whole reason two absent keys do not collide.
func TestAbsentRequestIDIsStoredAsNullNotEmptyString(t *testing.T) {
	st, _ := openTestStore(t)

	if err := st.CreateRun(&RunRecord{ID: "no-key", Project: "p", TaskID: "no-key", Status: "running"}); err != nil {
		t.Fatal(err)
	}
	// A key of nothing but whitespace is a key the caller did not supply. It must
	// land as NULL too, or "  " and "   " become two distinct keys that both look
	// absent to anyone reading the dashboard.
	if err := st.CreateRun(&RunRecord{ID: "blank-key", Project: "p", TaskID: "blank-key", Status: "running", RequestID: "   "}); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateRun(&RunRecord{ID: "real-key", Project: "p", TaskID: "real-key", Status: "running", RequestID: "k"}); err != nil {
		t.Fatal(err)
	}

	var nulls int
	if err := st.db.QueryRow(`SELECT COUNT(*) FROM runs WHERE request_id IS NULL`).Scan(&nulls); err != nil {
		t.Fatal(err)
	}
	if nulls != 2 {
		t.Errorf("%d rows hold a NULL request_id, want 2", nulls)
	}

	var empties int
	if err := st.db.QueryRow(`SELECT COUNT(*) FROM runs WHERE request_id = ''`).Scan(&empties); err != nil {
		t.Fatal(err)
	}
	if empties != 0 {
		t.Errorf("%d rows hold an empty-string request_id; the absent case must be NULL", empties)
	}
}

// The lookup that serves a deduplicated repeat. It must read every column the
// other run queries read, so a repeat cannot answer with a run that is missing
// the intent it serves.
func TestGetRunByRequestIDReturnsTheOriginalRun(t *testing.T) {
	st, _ := openTestStore(t)

	want := &RunRecord{
		ID: "sgt-orig", Project: "proj", TaskID: "sgt-orig", Brief: "add stripe webhooks",
		ChangeID: "add-stripe-webhooks", IntentID: "sgt-orig-intent", Status: "running",
		RequestID: "retry-me",
	}
	if err := st.CreateRun(want); err != nil {
		t.Fatal(err)
	}

	got, err := st.GetRunByRequestID("retry-me")
	if err != nil {
		t.Fatalf("GetRunByRequestID: %v", err)
	}
	if got.ID != want.ID {
		t.Errorf("id = %q, want %q", got.ID, want.ID)
	}
	if got.Project != want.Project {
		t.Errorf("project = %q, want %q", got.Project, want.Project)
	}
	if got.ChangeID != want.ChangeID {
		t.Errorf("change id = %q, want %q", got.ChangeID, want.ChangeID)
	}
	if got.IntentID != want.IntentID {
		t.Errorf("intent id = %q, want %q", got.IntentID, want.IntentID)
	}
	if got.RequestID != want.RequestID {
		t.Errorf("request id = %q, want %q", got.RequestID, want.RequestID)
	}

	// An unknown key is not an error condition the handler can paper over: it
	// means no run was ever recorded for it, which must be distinguishable from a
	// real failure so a caller can tell 404 from 500.
	if _, err := st.GetRunByRequestID("never-dispatched"); !errors.Is(err, sql.ErrNoRows) {
		t.Errorf("GetRunByRequestID on an unknown key = %v, want sql.ErrNoRows", err)
	}
	// An absent key is not a key. Looking one up must never return a run that
	// merely happens to have no key, or every keyless dispatch would deduplicate
	// against the first one.
	if _, err := st.GetRunByRequestID(""); !errors.Is(err, sql.ErrNoRows) {
		t.Errorf("GetRunByRequestID(\"\") = %v, want sql.ErrNoRows", err)
	}
}

// Every run reader reads every column. runColumns exists so that a column added
// to RunRecord cannot be read by one query and silently omitted by another, and a
// reader that omits one reports "no key was supplied" for a run that supplied
// one — a claim the store cannot support.
func TestEveryRunReaderReadsTheRequestID(t *testing.T) {
	st, _ := openTestStore(t)

	if err := st.CreateRun(&RunRecord{
		ID: "sgt-1", Project: "p", TaskID: "sgt-1", Status: "running",
		IntentID: "sgt-1-intent", RequestID: "retry-me",
	}); err != nil {
		t.Fatal(err)
	}

	byID, err := st.GetRun("sgt-1")
	if err != nil {
		t.Fatal(err)
	}
	readers := map[string]RunRecord{"GetRun": *byID}

	byKey, err := st.GetRunByRequestID("retry-me")
	if err != nil {
		t.Fatal(err)
	}
	readers["GetRunByRequestID"] = *byKey

	recent, err := st.ListRecentRuns(10)
	if err != nil {
		t.Fatal(err)
	}
	if len(recent) != 1 {
		t.Fatalf("ListRecentRuns returned %d runs, want 1", len(recent))
	}
	readers["ListRecentRuns"] = recent[0]

	forProject, err := st.ListRunsForProject("p", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(forProject) != 1 {
		t.Fatalf("ListRunsForProject returned %d runs, want 1", len(forProject))
	}
	readers["ListRunsForProject"] = forProject[0]

	for name, r := range readers {
		if r.RequestID != "retry-me" {
			t.Errorf("%s: RequestID = %q, want retry-me", name, r.RequestID)
		}
		if r.IntentID != "sgt-1-intent" {
			t.Errorf("%s: IntentID = %q, want sgt-1-intent", name, r.IntentID)
		}
	}
}

// A duplicate run id and a duplicate request id are both UNIQUE violations and
// must not be confused. Reporting a colliding id as a repeated key would answer
// a genuinely new dispatch with somebody else's run.
func TestADuplicateRunIDIsNotReportedAsADuplicateRequestID(t *testing.T) {
	st, _ := openTestStore(t)

	if err := st.CreateRun(&RunRecord{ID: "same", Project: "p", TaskID: "same", Status: "running", RequestID: "k1"}); err != nil {
		t.Fatal(err)
	}
	err := st.CreateRun(&RunRecord{ID: "same", Project: "p", TaskID: "same", Status: "running", RequestID: "k2"})
	if err == nil {
		t.Fatal("a duplicate run id was accepted")
	}
	if errors.Is(err, ErrDuplicateRequestID) {
		t.Errorf("a duplicate run id was classified as a duplicate request id: %v", err)
	}
}

// Any other unique index on runs must not be mistaken for the request_id one.
// SQLite reports every unique violation with the same result code, so a
// classifier that read the code alone would answer a genuinely new dispatch with
// an unrelated caller's run. The column name in the message is what separates
// them, and this test is the reason that check exists.
func TestAnotherUniqueIndexOnRunsIsNotReportedAsADuplicateRequestID(t *testing.T) {
	st, _ := openTestStore(t)

	if _, err := st.db.Exec(`CREATE UNIQUE INDEX idx_runs_task_id ON runs(task_id)`); err != nil {
		t.Fatal(err)
	}

	if err := st.CreateRun(&RunRecord{ID: "r1", Project: "p", TaskID: "shared", Status: "running", RequestID: "k1"}); err != nil {
		t.Fatal(err)
	}
	err := st.CreateRun(&RunRecord{ID: "r2", Project: "p", TaskID: "shared", Status: "running", RequestID: "k2"})
	if err == nil {
		t.Fatal("the unique index on runs.task_id did not fire")
	}
	if errors.Is(err, ErrDuplicateRequestID) {
		t.Errorf("a violation of runs.task_id was classified as a duplicate request id: %v", err)
	}
}

// The column and its unique index are additive in exactly the way change_id,
// slug and intent_id are. An installation created before dispatches carried a
// key must gain both on open rather than break every run query.
//
// The legacy rows must arrive as NULL, not ”. Backfilling ” would make the
// unique index impossible to create over two or more legacy runs, so this test
// seeds two.
func TestOpenAddsRunRequestIDToAnOlderDatabase(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "legacy-keyless.db")

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
	now := time.Now().UTC()
	for _, id := range []string{"old-1", "old-2"} {
		if _, err := st.db.Exec(
			`INSERT INTO runs (id, project, task_id, status, brief, slug, change_id, intent_id, created_at, updated_at)
			 VALUES (?, 'p', ?, 'passed', 'legacy brief', ?, 'legacy-change', '', ?, ?)`,
			id, id, "slug-"+id, now, now,
		); err != nil {
			t.Fatalf("seeding legacy run %s: %v", id, err)
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

	has, err := upgraded.hasColumn("runs", "request_id")
	if err != nil {
		t.Fatalf("checking runs.request_id: %v", err)
	}
	if !has {
		t.Fatal("runs.request_id was not added on open")
	}

	// Both legacy rows must read NULL. If either had been backfilled with '', the
	// unique index below could not exist and the guarantee would be unenforced.
	var nulls int
	if err := upgraded.db.QueryRow(`SELECT COUNT(*) FROM runs WHERE request_id IS NULL`).Scan(&nulls); err != nil {
		t.Fatal(err)
	}
	if nulls != 2 {
		t.Errorf("%d legacy rows hold NULL request_id, want 2", nulls)
	}

	if !upgraded.hasUniqueRequestIDIndex(t) {
		t.Error("the unique index on runs.request_id was not created on open")
	}

	// The upgraded table is usable, and it enforces the guarantee.
	if err := upgraded.CreateRun(&RunRecord{
		ID: "new-1", Project: "p", TaskID: "new-1", Status: "running", RequestID: "k",
	}); err != nil {
		t.Fatalf("runs table unusable after upgrade: %v", err)
	}
	if err := upgraded.CreateRun(&RunRecord{
		ID: "new-2", Project: "p", TaskID: "new-2", Status: "running", RequestID: "k",
	}); !errors.Is(err, ErrDuplicateRequestID) {
		t.Errorf("repeat after upgrade = %v, want ErrDuplicateRequestID", err)
	}

	// Legacy runs still read back, and they claim no key rather than an unknown one.
	runs, err := upgraded.ListRecentRuns(50)
	if err != nil {
		t.Fatalf("ListRecentRuns after upgrade: %v", err)
	}
	byID := map[string]RunRecord{}
	for _, r := range runs {
		byID[r.ID] = r
	}
	if got := byID["old-1"].RequestID; got != "" {
		t.Errorf("legacy run RequestID = %q, want empty", got)
	}
	if got := byID["old-1"].ChangeID; got != "legacy-change" {
		t.Errorf("legacy run ChangeID = %q, want legacy-change", got)
	}
	if got := byID["new-1"].RequestID; got != "k" {
		t.Errorf("new run RequestID = %q, want k", got)
	}
}

// Reopening a current database must not fail on an index that already exists,
// and must not lose the guarantee.
func TestUniqueRequestIDIndexSurvivesReopen(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "reopen.db")

	st, err := Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.CreateRun(&RunRecord{ID: "r1", Project: "p", TaskID: "r1", Status: "running", RequestID: "k"}); err != nil {
		t.Fatal(err)
	}
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}

	again, err := Open(dbPath)
	if err != nil {
		t.Fatalf("reopen failed: %v", err)
	}
	defer again.Close()

	if !again.hasUniqueRequestIDIndex(t) {
		t.Error("the unique index on runs.request_id did not survive a reopen")
	}
	if err := again.CreateRun(&RunRecord{ID: "r2", Project: "p", TaskID: "r2", Status: "running", RequestID: "k"}); !errors.Is(err, ErrDuplicateRequestID) {
		t.Errorf("repeat after reopen = %v, want ErrDuplicateRequestID", err)
	}
}

// hasUniqueRequestIDIndex proves the guarantee is held by the database. Asserting
// that a duplicate insert fails would pass against a check-then-insert in Go; only
// the index proves two concurrent inserts cannot both succeed.
func (s *Store) hasUniqueRequestIDIndex(t *testing.T) bool {
	t.Helper()
	rows, err := s.db.Query(`PRAGMA index_list(runs)`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	for rows.Next() {
		var seq int
		var name string
		var unique, origin, partial interface{}
		if err := rows.Scan(&seq, &name, &unique, &origin, &partial); err != nil {
			t.Fatal(err)
		}
		isUnique := false
		switch v := unique.(type) {
		case int64:
			isUnique = v == 1
		case bool:
			isUnique = v
		}
		if !isUnique {
			continue
		}
		cols, err := s.db.Query(`PRAGMA index_info(` + name + `)`)
		if err != nil {
			t.Fatal(err)
		}
		for cols.Next() {
			var seqno, cid int
			var colName interface{}
			if err := cols.Scan(&seqno, &cid, &colName); err != nil {
				cols.Close()
				t.Fatal(err)
			}
			if s, ok := colName.(string); ok && s == "request_id" {
				cols.Close()
				return true
			}
		}
		cols.Close()
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return false
}
