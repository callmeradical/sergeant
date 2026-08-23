package store

// Tests for the envelope metadata added by the
// "envelopes-are-typed-versioned-and-correlated" change (R5.1, R5.2, R5.7).
//
// Each test corresponds to one scenario in the spec so failures map directly to
// the requirement they violate.  All tests follow the project's TDD convention
// (decision D3): the test file is written before the implementation changes that
// make them pass.

import (
	"database/sql"
	"encoding/json"
	"path/filepath"
	"testing"
	"time"
)

// minimalValidEnvelope returns an EnvelopeRecord that satisfies every
// publication requirement introduced by this change.  Individual tests remove
// or change one field at a time.
func minimalValidEnvelope() *EnvelopeRecord {
	now := time.Now().UTC()
	return &EnvelopeRecord{
		ID:            "env-valid-1",
		RunID:         "run-abc",
		Repo:          "api",
		Stage:         "build",
		Type:          "phase.completed",
		SchemaVersion: "1",
		OccurredAt:    now.Add(-5 * time.Second),
		Producer:      "sergeant/runner",
		CorrelationID: "run-abc",
		Summary:       "test envelope",
		Data:          json.RawMessage(`{}`),
	}
}

// openTestStoreWithRun creates a store and a run row so foreign-key constraints
// are satisfied for envelopes.
func openTestStoreWithRun(t *testing.T, runID string) *Store {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "test.db")
	st, err := Open(dbPath)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { st.Close() })
	if err := st.CreateRun(&RunRecord{
		ID:      runID,
		Project: "p",
		TaskID:  "t",
		Status:  "running",
	}); err != nil {
		t.Fatalf("create run: %v", err)
	}
	return st
}

// --- s-1: Publication without a type is refused ---

func TestRecordEnvelopeRefusesEmptyType(t *testing.T) {
	st := openTestStoreWithRun(t, "run-abc")
	e := minimalValidEnvelope()
	e.Type = ""

	err := st.RecordEnvelope(e)
	if err == nil {
		t.Fatal("expected an error when type is empty, got nil")
	}

	// Nothing must have been written.
	_, readErr := st.GetLatestEnvelope("run-abc", "api")
	if readErr == nil {
		t.Error("a record was written despite the refused publication")
	}
}

// --- s-2: Publication without a schema version is refused ---

func TestRecordEnvelopeRefusesEmptySchemaVersion(t *testing.T) {
	st := openTestStoreWithRun(t, "run-abc")
	e := minimalValidEnvelope()
	e.SchemaVersion = ""

	err := st.RecordEnvelope(e)
	if err == nil {
		t.Fatal("expected an error when schema_version is empty, got nil")
	}

	_, readErr := st.GetLatestEnvelope("run-abc", "api")
	if readErr == nil {
		t.Error("a record was written despite the refused publication")
	}
}

// --- s-3: A published envelope reports its type and version ---

func TestRecordEnvelopeRoundTripsTypeAndSchemaVersion(t *testing.T) {
	st := openTestStoreWithRun(t, "run-abc")
	e := minimalValidEnvelope()
	e.Type = "phase.completed"
	e.SchemaVersion = "2"

	if err := st.RecordEnvelope(e); err != nil {
		t.Fatalf("RecordEnvelope: %v", err)
	}

	got, err := st.GetLatestEnvelope("run-abc", "api")
	if err != nil {
		t.Fatalf("GetLatestEnvelope: %v", err)
	}
	if got.Type != "phase.completed" {
		t.Errorf("Type = %q, want %q", got.Type, "phase.completed")
	}
	if got.SchemaVersion != "2" {
		t.Errorf("SchemaVersion = %q, want %q", got.SchemaVersion, "2")
	}
}

// --- s-4: Both timestamps are retained ---

func TestRecordEnvelopeRetainsBothTimestamps(t *testing.T) {
	st := openTestStoreWithRun(t, "run-abc")
	e := minimalValidEnvelope()

	occurred := time.Date(2025, 6, 1, 10, 0, 0, 0, time.UTC)
	e.OccurredAt = occurred
	// PublishedAt is set by RecordEnvelope to now(); we capture it after.

	if err := st.RecordEnvelope(e); err != nil {
		t.Fatalf("RecordEnvelope: %v", err)
	}

	got, err := st.GetLatestEnvelope("run-abc", "api")
	if err != nil {
		t.Fatalf("GetLatestEnvelope: %v", err)
	}

	if !got.OccurredAt.Equal(occurred) {
		t.Errorf("OccurredAt = %v, want %v", got.OccurredAt, occurred)
	}
	// PublishedAt must be distinct from OccurredAt (they are different facts).
	if got.PublishedAt.IsZero() {
		t.Error("PublishedAt is zero after read-back")
	}
	if got.PublishedAt.Equal(got.OccurredAt) {
		t.Error("PublishedAt equals OccurredAt; they must be separate fields")
	}
}

// --- s-5: Every envelope of a run shares one correlation id ---

func TestRecordEnvelopeRunEnvelopesShareCorrelationID(t *testing.T) {
	st := openTestStoreWithRun(t, "run-abc")

	for i, id := range []string{"env-a", "env-b", "env-c"} {
		e := minimalValidEnvelope()
		e.ID = id
		// All belong to the same run; correlation is the run id.
		e.CorrelationID = "run-abc"
		_ = i
		if err := st.RecordEnvelope(e); err != nil {
			t.Fatalf("RecordEnvelope %s: %v", id, err)
		}
	}

	envelopes, err := st.ListEnvelopesForRun("run-abc")
	if err != nil {
		t.Fatalf("ListEnvelopesForRun: %v", err)
	}
	if len(envelopes) != 3 {
		t.Fatalf("expected 3 envelopes, got %d", len(envelopes))
	}
	for _, env := range envelopes {
		if env.CorrelationID != "run-abc" {
			t.Errorf("envelope %s CorrelationID = %q, want %q", env.ID, env.CorrelationID, "run-abc")
		}
	}
}

// --- s-6: A following envelope names its cause ---

func TestRecordEnvelopeFollowingEnvelopeNamesCause(t *testing.T) {
	st := openTestStoreWithRun(t, "run-abc")

	first := minimalValidEnvelope()
	first.ID = "env-first"
	first.CausationID = nil // first has no cause
	if err := st.RecordEnvelope(first); err != nil {
		t.Fatalf("RecordEnvelope first: %v", err)
	}

	causeID := "env-first"
	second := minimalValidEnvelope()
	second.ID = "env-second"
	second.CausationID = &causeID
	if err := st.RecordEnvelope(second); err != nil {
		t.Fatalf("RecordEnvelope second: %v", err)
	}

	envelopes, err := st.ListEnvelopesForRun("run-abc")
	if err != nil {
		t.Fatalf("ListEnvelopesForRun: %v", err)
	}
	byID := map[string]*EnvelopeRecord{}
	for i := range envelopes {
		byID[envelopes[i].ID] = &envelopes[i]
	}

	if got := byID["env-second"].CausationID; got == nil || *got != "env-first" {
		t.Errorf("env-second CausationID = %v, want pointer to %q", got, "env-first")
	}
}

// --- s-7: The first envelope of a run has no causation id ---

func TestRecordEnvelopeFirstEnvelopeHasNoCausationID(t *testing.T) {
	st := openTestStoreWithRun(t, "run-abc")

	e := minimalValidEnvelope()
	e.CausationID = nil
	if err := st.RecordEnvelope(e); err != nil {
		t.Fatalf("RecordEnvelope: %v", err)
	}

	got, err := st.GetLatestEnvelope("run-abc", "api")
	if err != nil {
		t.Fatalf("GetLatestEnvelope: %v", err)
	}
	// nil pointer = absent; a non-nil pointer to empty string would be "recorded but empty".
	if got.CausationID != nil {
		t.Errorf("CausationID = %v, want nil (absent)", got.CausationID)
	}
}

// --- s-8: Publication without a correlation id is refused ---

func TestRecordEnvelopeRefusesEmptyCorrelationID(t *testing.T) {
	st := openTestStoreWithRun(t, "run-abc")
	e := minimalValidEnvelope()
	e.CorrelationID = ""

	err := st.RecordEnvelope(e)
	if err == nil {
		t.Fatal("expected an error when correlation_id is empty, got nil")
	}

	_, readErr := st.GetLatestEnvelope("run-abc", "api")
	if readErr == nil {
		t.Error("a record was written despite the refused publication")
	}
}

// --- s-9: An envelope names its producer ---

func TestRecordEnvelopeRoundTripsProducer(t *testing.T) {
	st := openTestStoreWithRun(t, "run-abc")
	e := minimalValidEnvelope()
	e.Producer = "sergeant/mcp"

	if err := st.RecordEnvelope(e); err != nil {
		t.Fatalf("RecordEnvelope: %v", err)
	}

	got, err := st.GetLatestEnvelope("run-abc", "api")
	if err != nil {
		t.Fatalf("GetLatestEnvelope: %v", err)
	}
	if got.Producer != "sergeant/mcp" {
		t.Errorf("Producer = %q, want %q", got.Producer, "sergeant/mcp")
	}
}

// Publication without a producer is refused (matches the validation rule).
func TestRecordEnvelopeRefusesEmptyProducer(t *testing.T) {
	st := openTestStoreWithRun(t, "run-abc")
	e := minimalValidEnvelope()
	e.Producer = ""

	err := st.RecordEnvelope(e)
	if err == nil {
		t.Fatal("expected an error when producer is empty, got nil")
	}

	_, readErr := st.GetLatestEnvelope("run-abc", "api")
	if readErr == nil {
		t.Error("a record was written despite the refused publication")
	}
}

// --- s-10: Republishing an existing id is refused ---

func TestRecordEnvelopeRefusesRepublishOfExistingID(t *testing.T) {
	st := openTestStoreWithRun(t, "run-abc")
	e := minimalValidEnvelope()
	e.Summary = "original summary"

	if err := st.RecordEnvelope(e); err != nil {
		t.Fatalf("first RecordEnvelope: %v", err)
	}

	e2 := minimalValidEnvelope() // same ID "env-valid-1"
	e2.Summary = "overwritten summary"

	if err := st.RecordEnvelope(e2); err == nil {
		t.Fatal("expected an error when republishing an existing id, got nil")
	}

	// The stored record must be the original, not the new one.
	got, err := st.GetLatestEnvelope("run-abc", "api")
	if err != nil {
		t.Fatalf("GetLatestEnvelope: %v", err)
	}
	if got.Summary != "original summary" {
		t.Errorf("Summary = %q after refused republish, want %q", got.Summary, "original summary")
	}
}

// --- s-11: An older envelope reads back without a type ---

// TestOlderEnvelopeReadsBackWithEmptyType simulates a row written before the
// type/schema_version/producer/correlation_id columns existed.  It must read
// back without error and with an empty Type field, not with a default value
// invented by the migration.
func TestOlderEnvelopeReadsBackWithEmptyType(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "legacy-envelopes.db")

	st, err := Open(dbPath)
	if err != nil {
		t.Fatalf("first open: %v", err)
	}
	// Seed a run row so the FK is satisfied.  Use raw Exec (two return values).
	if _, execErr := st.db.Exec(
		`INSERT INTO runs (id, project, task_id, status, created_at, updated_at)
		 VALUES ('legacy-run', 'p', 't', 'passed', ?, ?)`,
		time.Now().UTC(), time.Now().UTC(),
	); execErr != nil {
		// Tolerate a duplicate if the row was already seeded.
		t.Logf("seeding run (may already exist): %v", execErr)
	}
	// Bypass RecordEnvelope's new validation by writing raw SQL, so we can
	// simulate a row that pre-dates the type/schema_version columns.
	if _, rawErr := st.db.Exec(
		`INSERT INTO envelopes (id, run_id, repo, stage, summary, artifacts, data, created_at)
		 VALUES ('legacy-env-1', 'legacy-run', 'api', 'build', 'old summary', '[]', '{}', ?)`,
		time.Now().UTC(),
	); rawErr != nil {
		t.Fatalf("seeding legacy envelope: %v", rawErr)
	}
	if err := st.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	// Now drop the new columns to simulate a pre-migration database and reopen.
	// SQLite does not support DROP COLUMN on older versions, so instead we
	// simulate by reopening: the migration is additive and pre-existing rows
	// have NULL in the new columns. We just verify the read path handles NULL.
	//
	// Reopen (migrations run, new columns exist with DEFAULT '' / NULL).
	upgraded, err := Open(dbPath)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer upgraded.Close()

	got, err := upgraded.GetLatestEnvelope("legacy-run", "api")
	if err != nil {
		t.Fatalf("GetLatestEnvelope on legacy row: %v", err)
	}
	if got.Type != "" {
		t.Errorf("legacy envelope Type = %q, want empty (no backfill)", got.Type)
	}
	if got.Summary != "old summary" {
		t.Errorf("legacy envelope Summary = %q, want %q", got.Summary, "old summary")
	}
}

// TestEnvelopePhaseIDRoundTrips ensures PhaseID survives a store round-trip.
// PhaseID is the missing reference link named in the design.
func TestEnvelopePhaseIDRoundTrips(t *testing.T) {
	st := openTestStoreWithRun(t, "run-abc")
	e := minimalValidEnvelope()
	e.PhaseID = "phase-42"

	if err := st.RecordEnvelope(e); err != nil {
		t.Fatalf("RecordEnvelope: %v", err)
	}

	got, err := st.GetLatestEnvelope("run-abc", "api")
	if err != nil {
		t.Fatalf("GetLatestEnvelope: %v", err)
	}
	if got.PhaseID != "phase-42" {
		t.Errorf("PhaseID = %q, want %q", got.PhaseID, "phase-42")
	}
}

// TestEnvelopeColumnsAddedOnReopen verifies the PRAGMA-guarded migration adds
// every new column to a database that predates this change.
func TestEnvelopeColumnsAddedOnReopen(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "pre-metadata.db")

	st, err := Open(dbPath)
	if err != nil {
		t.Fatalf("first open: %v", err)
	}
	// Simulate the pre-change schema: drop and recreate envelopes without the
	// new columns.
	if _, err := st.db.Exec("DROP TABLE envelopes"); err != nil {
		t.Fatalf("drop envelopes: %v", err)
	}
	if _, err := st.db.Exec(`CREATE TABLE envelopes (
		id TEXT PRIMARY KEY,
		run_id TEXT NOT NULL,
		repo TEXT NOT NULL,
		stage TEXT NOT NULL,
		summary TEXT NOT NULL,
		artifacts TEXT,
		data TEXT NOT NULL,
		created_at DATETIME NOT NULL,
		FOREIGN KEY (run_id) REFERENCES runs(id)
	)`); err != nil {
		t.Fatalf("recreate legacy envelopes: %v", err)
	}
	if err := st.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	upgraded, err := Open(dbPath)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer upgraded.Close()

	newCols := []string{
		"type", "schema_version", "occurred_at", "published_at",
		"producer", "correlation_id", "causation_id", "phase_id",
	}
	for _, col := range newCols {
		has, err := upgraded.hasColumn("envelopes", col)
		if err != nil {
			t.Fatalf("hasColumn envelopes.%s: %v", col, err)
		}
		if !has {
			t.Errorf("column envelopes.%s was not added on reopen", col)
		}
	}
}

// TestListEnvelopesForRunIncludesNewFields verifies that ListEnvelopesForRun
// (the bulk reader) returns the new fields, not just GetLatestEnvelope.
func TestListEnvelopesForRunIncludesNewFields(t *testing.T) {
	st := openTestStoreWithRun(t, "run-abc")
	e := minimalValidEnvelope()
	e.Type = "phase.completed"
	e.SchemaVersion = "1"
	e.Producer = "sergeant/runner"
	e.CorrelationID = "run-abc"

	if err := st.RecordEnvelope(e); err != nil {
		t.Fatalf("RecordEnvelope: %v", err)
	}

	list, err := st.ListEnvelopesForRun("run-abc")
	if err != nil {
		t.Fatalf("ListEnvelopesForRun: %v", err)
	}
	if len(list) != 1 {
		t.Fatalf("expected 1 envelope, got %d", len(list))
	}
	got := list[0]
	if got.Type != "phase.completed" {
		t.Errorf("Type = %q, want phase.completed", got.Type)
	}
	if got.Producer != "sergeant/runner" {
		t.Errorf("Producer = %q, want sergeant/runner", got.Producer)
	}
	if got.CorrelationID != "run-abc" {
		t.Errorf("CorrelationID = %q, want run-abc", got.CorrelationID)
	}
}

// TestRecordEnvelopeSetsPublishedAt verifies that RecordEnvelope stamps
// PublishedAt itself (the caller is responsible for OccurredAt only).
func TestRecordEnvelopeSetsPublishedAt(t *testing.T) {
	st := openTestStoreWithRun(t, "run-abc")
	before := time.Now().UTC()
	e := minimalValidEnvelope()
	if err := st.RecordEnvelope(e); err != nil {
		t.Fatalf("RecordEnvelope: %v", err)
	}
	after := time.Now().UTC()

	got, err := st.GetLatestEnvelope("run-abc", "api")
	if err != nil {
		t.Fatalf("GetLatestEnvelope: %v", err)
	}
	if got.PublishedAt.Before(before) || got.PublishedAt.After(after) {
		t.Errorf("PublishedAt %v not in [%v, %v]", got.PublishedAt, before, after)
	}
}

// TestOlderEnvelopeNullCausationIDIsNil verifies that a NULL causation_id in
// the database (pre-migration row) reads back as nil, not as a pointer to "".
// This tests the "absent distinguishable from empty" invariant for legacy rows.
func TestOlderEnvelopeNullCausationIDIsNil(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "null-causation.db")
	st, err := Open(dbPath)
	if err != nil {
		t.Fatalf("open: %v", err)
	}

	// Seed run and a raw envelope row (causation_id will be NULL by default).
	_, _ = st.db.Exec(
		`INSERT INTO runs (id, project, task_id, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)`,
		"run-nc", "p", "t", "running", time.Now().UTC(), time.Now().UTC(),
	)
	_, err = st.db.Exec(
		`INSERT INTO envelopes (id, run_id, repo, stage, summary, artifacts, data, created_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		"env-nc-1", "run-nc", "api", "build", "s", "[]", "{}", time.Now().UTC(),
	)
	if err != nil {
		t.Fatalf("seed raw envelope: %v", err)
	}
	st.Close()

	reopened, err := Open(dbPath)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer reopened.Close()

	got, err := reopened.GetLatestEnvelope("run-nc", "api")
	if err != nil {
		t.Fatalf("GetLatestEnvelope: %v", err)
	}
	if got.CausationID != nil {
		t.Errorf("legacy envelope CausationID = %v, want nil", got.CausationID)
	}

	// Verify via ListEnvelopesForRun too.
	list, err := reopened.ListEnvelopesForRun("run-nc")
	if err != nil {
		t.Fatalf("ListEnvelopesForRun: %v", err)
	}
	if len(list) != 1 {
		t.Fatalf("expected 1, got %d", len(list))
	}
	if list[0].CausationID != nil {
		t.Errorf("legacy envelope CausationID (list) = %v, want nil", list[0].CausationID)
	}
}

// Ensure sql.NullString is not imported unnecessarily — the store uses a *string
// for CausationID so nil is "absent" and a non-nil pointer is "present".
var _ *string = (*string)(nil)
var _ sql.NullString = sql.NullString{}
