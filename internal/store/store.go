package store

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/callmeradical/sergeant/internal/naming"
	"github.com/callmeradical/sergeant/internal/redact"

	// Imported for its name, not only for its driver registration: classifying a
	// unique-index violation requires the driver's error type, and that
	// classification is what makes a dispatch idempotent.
	"modernc.org/sqlite"
	sqlite3 "modernc.org/sqlite/lib"
)

type Store struct {
	db *sql.DB

	// subs is the in-process fan-out of appended change sequence numbers, so a
	// subscriber learns that state moved without polling. See SubscribeChanges.
	subMu     sync.Mutex
	subs      map[int64]chan int64
	nextSubID int64
}

type RunRecord struct {
	ID      string `json:"id"`
	Project string `json:"project"`
	TaskID  string `json:"task_id"`
	Brief   string `json:"brief"`
	// ChangeID is the OpenSpec change this run is accountable to (decision O3).
	// It is resolved before the run row is written, so a stored run always names
	// the change whose openspec/changes/<id>/ directory travels in its PR.
	ChangeID string `json:"change_id"`
	// Type is the work type this run was dispatched as (decision O2): one of
	// feat, fix, refactor, docs, chore, test. It is resolved and validated
	// before the run row is written, so a stored run always names the type its
	// dispatched branch is named from.
	Type string `json:"type"`
	// IntentID names the intent this run serves (decision D4). It is derived from
	// the run id rather than generated independently, so the link is
	// reconstructible from either side without a join table. It reads empty for
	// runs written before a dispatch persisted its intent; empty means "no intent
	// was recorded", never "the intent is unknown but exists".
	IntentID string `json:"intent_id"`
	// Slug is a short, speakable label for the run (adverb-adjective-noun). It is
	// a display and speech label only; ID remains the run's identity.
	Slug string `json:"slug"`
	// RequestID is the caller's idempotency key (decision D10, from AHP's
	// runAutomation). It is not sergeant's identifier for the run — ID is — it is
	// the caller's statement that a second POST is a retry of the first rather
	// than a new request. Empty means the caller supplied none, and two runs that
	// supplied none never deduplicate against each other: the absent case is
	// stored as SQL NULL, which a unique index treats as distinct.
	RequestID string    `json:"request_id,omitempty"`
	Status    string    `json:"status"` // running, passed, failed
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

type PhaseRecord struct {
	ID         string          `json:"id"`
	RunID      string          `json:"run_id"`
	Repo       string          `json:"repo"`
	Name       string          `json:"name"`   // plan, build, test, review, doc
	Kind       string          `json:"kind"`   // agent, code
	Status     string          `json:"status"` // running, passed, failed
	Error      string          `json:"error,omitempty"`
	DurationMs int64           `json:"duration_ms"`
	Payload    json.RawMessage `json:"payload,omitempty"`
	// Attempt is the 1-based sequence number for this phase invocation. The first
	// attempt is 1; each retry increments by 1 with no gaps. A value of 0 means
	// the record predates this field and the attempt count is unknown.
	Attempt   int       `json:"attempt,omitempty"`
	CreatedAt time.Time `json:"created_at"`
}

// IntentRecord is the primary durable object. An intent may span repositories;
// the ordering between them lives in its bullets' Position values.
type IntentRecord struct {
	ID        string `json:"id"`
	Project   string `json:"project"`
	Statement string `json:"statement"`
	Status    string `json:"status"` // proposed, approved, in_progress, satisfied, abandoned
	// ChangeID and ChangeRepo record the OpenSpec change (decision O3) this
	// intent was resolved against at the time it was created — proposed or
	// dispatched immediately, either way. A proposed intent's approval must
	// reuse these exact values rather than re-resolving the change a second
	// time: re-resolving with different inputs (an approval request carries
	// no caller-supplied change_id, and repo selection can depend on
	// argument order) can silently pick a different repository or scaffold
	// a second change, discarding whatever change_id the caller named at
	// proposal time.
	ChangeID   string    `json:"change_id,omitempty"`
	ChangeRepo string    `json:"change_repo,omitempty"`
	// Type is the work type a proposed plan was resolved with (decision O2),
	// for the same reason ChangeID/ChangeRepo are recorded here: an approval
	// reuses it verbatim rather than requiring the caller to state it again.
	Type      string    `json:"type,omitempty"`
	// ShippingGateStatus is "", "passed", or "failed". Empty means the intent's
	// bullets have not all reached sealed/merged yet, OR they have and no
	// shipping gates are configured for the project — in the latter case
	// "passed" is written immediately (handleCreatePR), so a caller never has
	// to distinguish "not evaluated" from "trivially passed" by reading config
	// elsewhere.
	ShippingGateStatus string `json:"shipping_gate_status,omitempty"`
	// ShippingGateReason is set only when ShippingGateStatus is "failed",
	// mirroring BulletRecord.BlockedReason's existing pattern exactly.
	ShippingGateReason string    `json:"shipping_gate_reason,omitempty"`
	CreatedAt          time.Time `json:"created_at"`
	UpdatedAt          time.Time `json:"updated_at"`
}

// BulletRecord is a tracer bullet: exactly ONE repository, a vertical slice
// through that repo's stack, yielding one commit and one PR. Repo is a single
// string on purpose — work in a second repository is a second bullet.
type BulletRecord struct {
	ID        string    `json:"id"`
	IntentID  string    `json:"intent_id"`
	Repo      string    `json:"repo"`
	Position  int       `json:"position"` // merge order within the intent
	Status    string    `json:"status"`   // one of BulletStatuses()
	Branch    string    `json:"branch,omitempty"`
	Worktree  string    `json:"worktree,omitempty"`
	CommitSHA string    `json:"commit_sha,omitempty"`
	PRURL     string    `json:"pr_url,omitempty"`
	// BlockedReason is a human-readable explanation of why the bullet is
	// stuck. Empty unless Status is "blocked".
	BlockedReason string    `json:"blocked_reason,omitempty"`
	CreatedAt     time.Time `json:"created_at"`
	UpdatedAt     time.Time `json:"updated_at"`
}

// BulletStatuses is the full set of BulletRecord.Status values, in lifecycle
// order: a bullet may first be proposed as part of a plan awaiting approval
// (D2), then created pending, records red then green evidence (D3), is sealed
// into a PR, and is merged by a human (D6). failed and blocked are terminal
// alternatives and sort last because either can be reached from any earlier
// state. failed is what a stuck run's outcome wrote before this status
// existed and remains a valid value for those historical rows; blocked, which
// carries BlockedReason, is what a stuck run's outcome writes going forward.
//
// This exists as code rather than only as a comment because the dashboard renders
// the lifecycle as the tail of the workflow graph. A hand-copied list in the UI
// would be free to invent a status the store never writes.
//
// A fresh slice is returned on every call so no caller can mutate it.
func BulletStatuses() []string {
	return []string{"proposed", "pending", "red", "green", "sealed", "merged", "failed", "blocked"}
}

// BulletProgression is the ordered lifecycle a bullet advances through. It
// deliberately excludes "failed": failure is a state any step can be in, not a
// step that follows "merged". Rendering it as the end of a chain would tell an
// operator that failure comes after merge.
func BulletProgression() []string {
	return []string{"pending", "red", "green", "sealed", "merged"}
}

type EnvelopeRecord struct {
	ID        string          `json:"id"`
	RunID     string          `json:"run_id"`
	Repo      string          `json:"repo"`
	Stage     string          `json:"stage"`
	Summary   string          `json:"summary"`
	Artifacts []string        `json:"artifacts"`
	Data      json.RawMessage `json:"data"`
	CreatedAt time.Time       `json:"created_at"`

	// Metadata added by R5.1/R5.2 (envelopes-are-typed-versioned-and-correlated).
	// Fields are empty for envelopes written before this change; that is the truth
	// about them — no type was ever declared, so none is backfilled.

	// Type names what this envelope is (e.g. "phase.completed").
	Type string `json:"type"`
	// SchemaVersion declares which payload shape this envelope carries.
	SchemaVersion string `json:"schema_version"`
	// OccurredAt is when the event happened — set by the caller.
	// PublishedAt is when it was recorded by the store — set by RecordEnvelope.
	// They are separate because collapsing them hides transport delay.
	OccurredAt  time.Time `json:"occurred_at"`
	PublishedAt time.Time `json:"published_at"`
	// Producer names what emitted this envelope (e.g. "sergeant/runner").
	Producer string `json:"producer"`
	// CorrelationID is stable across all envelopes belonging to one run.
	// It is set to the run id so the chain cannot drift from the records it
	// describes.
	CorrelationID string `json:"correlation_id"`
	// CausationID is the id of the envelope that caused this one within the run.
	// nil means absent (the first envelope of a run has no cause).
	// A non-nil pointer to "" would mean "something caused it but was not
	// recorded"; that case is not representable in the current design.
	CausationID *string `json:"causation_id,omitempty"`
	// PhaseID is the phase this envelope belongs to.
	PhaseID string `json:"phase_id,omitempty"`
}

func Open(dbPath string) (*Store, error) {
	if dbPath == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return nil, fmt.Errorf("resolving home directory: %w", err)
		}
		dbPath = filepath.Join(home, ".local", "share", "sergeant", "sergeant.db")
	}

	if err := os.MkdirAll(filepath.Dir(dbPath), 0755); err != nil {
		return nil, fmt.Errorf("creating db directory: %w", err)
	}

	db, err := sql.Open("sqlite", dbPath+"?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)")
	if err != nil {
		return nil, fmt.Errorf("opening sqlite db: %w", err)
	}

	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		db.Close()
		return nil, fmt.Errorf("migrating db: %w", err)
	}

	return s, nil
}

func (s *Store) Close() error {
	return s.db.Close()
}

// createIntentsTable and createBulletsTable are consts because the same DDL is
// needed twice: once in the initial schema, and once by migrateAddTables when an
// older database is reopened.
const createIntentsTable = `
	CREATE TABLE IF NOT EXISTS intents (
		id TEXT PRIMARY KEY,
		project TEXT NOT NULL,
		statement TEXT NOT NULL,
		status TEXT NOT NULL,
		change_id TEXT NOT NULL DEFAULT '',
		change_repo TEXT NOT NULL DEFAULT '',
		type TEXT NOT NULL DEFAULT '',
		created_at DATETIME NOT NULL,
		updated_at DATETIME NOT NULL
	);`

const createBulletsTable = `
	CREATE TABLE IF NOT EXISTS bullets (
		id TEXT PRIMARY KEY,
		intent_id TEXT NOT NULL,
		repo TEXT NOT NULL,
		position INTEGER NOT NULL,
		status TEXT NOT NULL,
		branch TEXT NOT NULL DEFAULT '',
		worktree TEXT NOT NULL DEFAULT '',
		commit_sha TEXT NOT NULL DEFAULT '',
		pr_url TEXT NOT NULL DEFAULT '',
		blocked_reason TEXT NOT NULL DEFAULT '',
		created_at DATETIME NOT NULL,
		updated_at DATETIME NOT NULL,
		FOREIGN KEY (intent_id) REFERENCES intents(id)
	);`

func (s *Store) migrate() error {
	schema := `
	CREATE TABLE IF NOT EXISTS runs (
		id TEXT PRIMARY KEY,
		project TEXT NOT NULL,
		task_id TEXT NOT NULL,
		status TEXT NOT NULL,
		brief TEXT NOT NULL DEFAULT '',
		slug TEXT NOT NULL DEFAULT '',
		change_id TEXT NOT NULL DEFAULT '',
		type TEXT NOT NULL DEFAULT '',
		intent_id TEXT NOT NULL DEFAULT '',
		-- request_id is deliberately nullable and deliberately has no DEFAULT ''.
		-- The unique index below is what makes a dispatch idempotent, and SQLite
		-- treats NULL as distinct in a unique index but '' as equal to itself. A
		-- default of '' would therefore make the second keyless dispatch collide
		-- with the first. See migrateAddIndexes.
		request_id TEXT,
		created_at DATETIME NOT NULL,
		updated_at DATETIME NOT NULL
	);

	CREATE TABLE IF NOT EXISTS phases (
		id TEXT PRIMARY KEY,
		run_id TEXT NOT NULL,
		repo TEXT NOT NULL,
		name TEXT NOT NULL,
		kind TEXT NOT NULL,
		status TEXT NOT NULL,
		error TEXT,
		duration_ms INTEGER,
		payload TEXT,
		attempt INTEGER NOT NULL DEFAULT 0,
		created_at DATETIME NOT NULL,
		FOREIGN KEY (run_id) REFERENCES runs(id)
	);

	CREATE TABLE IF NOT EXISTS envelopes (
		id TEXT PRIMARY KEY,
		run_id TEXT NOT NULL,
		repo TEXT NOT NULL,
		stage TEXT NOT NULL,
		summary TEXT NOT NULL,
		artifacts TEXT,
		data TEXT NOT NULL,
		created_at DATETIME NOT NULL,
		FOREIGN KEY (run_id) REFERENCES runs(id)
	);
	` + createIntentsTable + createBulletsTable + createChangesTable + createDeliveriesTable + createArtifactsTable + createRetentionRollupsTable
	if _, err := s.db.Exec(schema); err != nil {
		return err
	}
	if err := s.migrateAddTables(); err != nil {
		return err
	}
	if err := s.migrateAddColumns(); err != nil {
		return err
	}
	// Indexes come after columns, not in the schema above: on a database created
	// before request_id existed, CREATE INDEX would name a column that
	// migrateAddColumns has not added yet and the whole open would fail.
	if err := s.migrateAddIndexes(); err != nil {
		return err
	}
	return s.backfillSlugs()
}

// backfillSlugs labels runs that predate the slug column. The slug is derived
// from the run id, so this is deterministic and idempotent: a run always gets
// the same label whether it was written before or after the column existed.
// Terminal runs may share a label; uniqueness is only enforced among live runs,
// at creation time, because a slug is a speech label rather than a key.
func (s *Store) backfillSlugs() error {
	rows, err := s.db.Query(`SELECT id FROM runs WHERE slug IS NULL OR slug = ''`)
	if err != nil {
		return err
	}
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return err
		}
		ids = append(ids, id)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	for _, id := range ids {
		if _, err := s.db.Exec(`UPDATE runs SET slug = ? WHERE id = ?`, naming.Slug(id), id); err != nil {
			return err
		}
	}
	return nil
}

// migrateAddTables brings pre-existing databases up to the current set of
// tables. It is belt-and-braces next to the CREATE TABLE IF NOT EXISTS above:
// it proves with PRAGMA that each table the code queries is really there, so a
// database that was created before intents and bullets existed cannot be
// reopened into a state where every intent query fails.
func (s *Store) migrateAddTables() error {
	wanted := []struct{ table, ddl string }{
		{"intents", createIntentsTable},
		{"bullets", createBulletsTable},
		{"changes", createChangesTable},
		{"deliveries", createDeliveriesTable},
		{"export_cursor", createExportCursorTable},
		{"artifacts", createArtifactsTable},
		{"retention_rollups", createRetentionRollupsTable},
	}
	for _, w := range wanted {
		has, err := s.hasTable(w.table)
		if err != nil {
			return err
		}
		if has {
			continue
		}
		if _, err := s.db.Exec(w.ddl); err != nil {
			return fmt.Errorf("creating %s: %w", w.table, err)
		}
	}
	return nil
}

// migrateAddColumns brings pre-existing databases up to the current schema.
// CREATE TABLE IF NOT EXISTS is a no-op on an existing table, so new columns
// must be added explicitly or every query naming them fails.
func (s *Store) migrateAddColumns() error {
	wanted := []struct{ table, column, ddl string }{
		{"runs", "brief", "ALTER TABLE runs ADD COLUMN brief TEXT NOT NULL DEFAULT ''"},
		{"runs", "change_id", "ALTER TABLE runs ADD COLUMN change_id TEXT NOT NULL DEFAULT ''"},
		{"runs", "slug", "ALTER TABLE runs ADD COLUMN slug TEXT NOT NULL DEFAULT ''"},
		{"runs", "intent_id", "ALTER TABLE runs ADD COLUMN intent_id TEXT NOT NULL DEFAULT ''"},
		// No NOT NULL and no DEFAULT '', unlike every other column here. Every
		// pre-existing run must arrive as NULL: '' is equal to itself under the
		// unique index, so backfilling '' would make the index impossible to
		// create over two or more legacy runs and would break the open entirely.
		{"runs", "request_id", "ALTER TABLE runs ADD COLUMN request_id TEXT"},
		{"bullets", "branch", "ALTER TABLE bullets ADD COLUMN branch TEXT NOT NULL DEFAULT ''"},
		{"bullets", "worktree", "ALTER TABLE bullets ADD COLUMN worktree TEXT NOT NULL DEFAULT ''"},
		{"bullets", "commit_sha", "ALTER TABLE bullets ADD COLUMN commit_sha TEXT NOT NULL DEFAULT ''"},
		{"bullets", "pr_url", "ALTER TABLE bullets ADD COLUMN pr_url TEXT NOT NULL DEFAULT ''"},
		// blocked_reason was added when "blocked" replaced "failed" as the
		// outcome of a stuck run; existing rows have no reason to backfill.
		{"bullets", "blocked_reason", "ALTER TABLE bullets ADD COLUMN blocked_reason TEXT NOT NULL DEFAULT ''"},
		// change_id/change_repo record the OpenSpec change an intent was
		// resolved against; existing rows predate plan approval and have
		// nothing to backfill.
		{"intents", "change_id", "ALTER TABLE intents ADD COLUMN change_id TEXT NOT NULL DEFAULT ''"},
		{"intents", "change_repo", "ALTER TABLE intents ADD COLUMN change_repo TEXT NOT NULL DEFAULT ''"},
		// type is the work type (decision O2) a run/plan was dispatched or
		// proposed as; existing rows predate the requirement and have nothing
		// to backfill.
		{"runs", "type", "ALTER TABLE runs ADD COLUMN type TEXT NOT NULL DEFAULT ''"},
		{"intents", "type", "ALTER TABLE intents ADD COLUMN type TEXT NOT NULL DEFAULT ''"},
		// attempt is 1-based; 0 means "pre-dates this field" (unknown attempt count).
		{"phases", "attempt", "ALTER TABLE phases ADD COLUMN attempt INTEGER NOT NULL DEFAULT 0"},

		// Envelope metadata added by R5.1/R5.2. DEFAULT '' so existing rows read
		// back as empty rather than NULL, making the zero value the "no type
		// declared" truth about pre-migration envelopes.
		{"envelopes", "type", "ALTER TABLE envelopes ADD COLUMN type TEXT NOT NULL DEFAULT ''"},
		{"envelopes", "schema_version", "ALTER TABLE envelopes ADD COLUMN schema_version TEXT NOT NULL DEFAULT ''"},
		// occurred_at and published_at default to the epoch (zero time) so the
		// DATETIME column is always parseable; callers distinguish "not set" from
		// a real time by checking the zero value.
		{"envelopes", "occurred_at", "ALTER TABLE envelopes ADD COLUMN occurred_at DATETIME NOT NULL DEFAULT '0001-01-01 00:00:00'"},
		{"envelopes", "published_at", "ALTER TABLE envelopes ADD COLUMN published_at DATETIME NOT NULL DEFAULT '0001-01-01 00:00:00'"},
		{"envelopes", "producer", "ALTER TABLE envelopes ADD COLUMN producer TEXT NOT NULL DEFAULT ''"},
		{"envelopes", "correlation_id", "ALTER TABLE envelopes ADD COLUMN correlation_id TEXT NOT NULL DEFAULT ''"},
		// causation_id is intentionally nullable: NULL means "no cause" (the first
		// envelope of a run), which must be distinguishable from an empty string.
		{"envelopes", "causation_id", "ALTER TABLE envelopes ADD COLUMN causation_id TEXT"},
		{"envelopes", "phase_id", "ALTER TABLE envelopes ADD COLUMN phase_id TEXT NOT NULL DEFAULT ''"},
		// error_class was added after deliveries first shipped (R5.4 error
		// classification); a database that created the table before this column
		// existed needs it added explicitly, same as every other column here.
		{"deliveries", "error_class", "ALTER TABLE deliveries ADD COLUMN error_class TEXT NOT NULL DEFAULT ''"},
		// recovery_instructions was added by R5.5 dead-lettering; a database that
		// created the table before this column existed needs it added explicitly.
		// DEFAULT '' so existing rows read back as empty rather than NULL.
		{"deliveries", "recovery_instructions", "ALTER TABLE deliveries ADD COLUMN recovery_instructions TEXT NOT NULL DEFAULT ''"},
		// shipping_gate_status/shipping_gate_reason were added by the intent-
		// scoped shipping gate; existing rows predate it and have nothing to
		// backfill, so an empty status reads back as "not yet evaluated", the
		// same as a freshly created intent.
		{"intents", "shipping_gate_status", "ALTER TABLE intents ADD COLUMN shipping_gate_status TEXT NOT NULL DEFAULT ''"},
		{"intents", "shipping_gate_reason", "ALTER TABLE intents ADD COLUMN shipping_gate_reason TEXT NOT NULL DEFAULT ''"},
		// cancelled_count/interrupted_count were missing from
		// retention_rollups' first cut despite rotationEligibleStatusesSQL
		// (which RotateProject filters on) including both statuses --
		// without them, rotating a cancelled or interrupted run silently
		// dropped its contribution to WorkAnalytics.ByStatus instead of
		// folding it in, violating spec.md's "aggregate totals unchanged by
		// rotation". Found by Review 036's critic.
		{"retention_rollups", "cancelled_count", "ALTER TABLE retention_rollups ADD COLUMN cancelled_count INTEGER NOT NULL DEFAULT 0"},
		{"retention_rollups", "interrupted_count", "ALTER TABLE retention_rollups ADD COLUMN interrupted_count INTEGER NOT NULL DEFAULT 0"},
	}
	for _, w := range wanted {
		has, err := s.hasColumn(w.table, w.column)
		if err != nil {
			return err
		}
		if has {
			continue
		}
		if _, err := s.db.Exec(w.ddl); err != nil {
			return fmt.Errorf("adding %s.%s: %w", w.table, w.column, err)
		}
	}
	return nil
}

// requestIDIndex makes a dispatch idempotent under the caller's key.
//
// It is a database constraint rather than a check in the handler on purpose. Two
// concurrent POSTs carrying the same key would both find nothing if they looked
// before inserting, and both would then insert — the classic check-then-insert
// race. A unique index cannot be raced: one insert wins and the other is refused
// with SQLITE_CONSTRAINT_UNIQUE, which is the signal the handler turns into "here
// is the run you already have".
//
// NULL is the absent case. SQLite considers two NULLs distinct for uniqueness, so
// any number of dispatches may omit the key without deduplicating against each
// other, which is what makes the key optional.
const requestIDIndex = `CREATE UNIQUE INDEX IF NOT EXISTS idx_runs_request_id ON runs(request_id)`

// migrateAddIndexes creates the indexes the code depends on for correctness
// rather than for speed. IF NOT EXISTS makes it idempotent across reopens.
func (s *Store) migrateAddIndexes() error {
	if _, err := s.db.Exec(requestIDIndex); err != nil {
		return fmt.Errorf("creating the unique index on runs.request_id: %w", err)
	}
	return nil
}

// hasTable reports whether a table exists. PRAGMA table_info on a missing table
// yields no rows and no error, which is why a bare ALTER on an absent table is
// the failure this guards against.
func (s *Store) hasTable(table string) (bool, error) {
	var name string
	err := s.db.QueryRow(
		`SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?`, table,
	).Scan(&name)
	if err == sql.ErrNoRows {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, nil
}

func (s *Store) hasColumn(table, column string) (bool, error) {
	rows, err := s.db.Query(fmt.Sprintf("PRAGMA table_info(%s)", table))
	if err != nil {
		return false, err
	}
	defer rows.Close()
	for rows.Next() {
		var cid int
		var name, ctype string
		var notnull int
		var dflt interface{}
		var pk int
		if err := rows.Scan(&cid, &name, &ctype, &notnull, &dflt, &pk); err != nil {
			return false, err
		}
		if name == column {
			return true, nil
		}
	}
	return false, rows.Err()
}

// terminalRunStatuses are the states a run does not leave on its own.
//
// It is one list because two consumers depend on it and must agree. A slug may be
// reused after a run reaches one of these states, because a slug is a speech
// label that only has to be unambiguous while the run is live. And a caller
// waiting for a run to finish returns when it reaches one of these states — a
// second, shorter copy of this list would make such a wait block forever on a
// status this one calls finished.
//
// timed_out is here because a timed-out run is finished: it is listed as
// resumable precisely because nothing resumes it by itself.
//
// interrupted is here for the same reason: the coordinator stopped, not the
// work. A coordinator that just started is driving no runs, so any run it finds
// marked running is unowned and is reconciled to interrupted on startup. That
// reconciled status must be terminal so waiters and slug assignment treat it as
// finished, even though resume can re-enter it.
var terminalRunStatuses = map[string]bool{
	"passed":      true,
	"failed":      true,
	"cancelled":   true,
	"timed_out":   true,
	"interrupted": true,
}

// ResumableRunStatuses are the run statuses the store considers resumable.
//
// This list lives in the store package so store-layer tests can assert on it
// without importing the ui package. The server's ResumableStatuses slice must
// agree with this list; both are derived from the same design decision.
//
// interrupted is resumable: the coordinator stopped, not the work. Nothing
// judged the run; it was merely cut off. Recording it as failed would assert a
// verdict no gate produced.
func ResumableRunStatuses() []string {
	return []string{"failed", "cancelled", "timed_out", "interrupted"}
}

// IsTerminalRunStatus reports whether a run in this status has finished.
//
// A wait for a run to complete asks this and nothing else. It must never be
// answered by inference from elapsed time: a run's status is whatever the store
// says, not whatever a caller's patience implies.
func IsTerminalRunStatus(status string) bool {
	return terminalRunStatuses[status]
}

// assignSlug gives r a speakable label, avoiding any slug currently held by a
// non-terminal run. The label is derived from the run id, so it is reproducible;
// on collision it steps deterministically to the next candidate.
func (s *Store) assignSlug(r *RunRecord) error {
	if r.Slug != "" {
		return nil
	}
	taken := map[string]bool{}
	rows, err := s.db.Query(`SELECT COALESCE(slug, ''), status FROM runs WHERE slug != ''`)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var slug, status string
		if err := rows.Scan(&slug, &status); err != nil {
			return err
		}
		if !terminalRunStatuses[status] {
			taken[slug] = true
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}

	// naming.Combinations bounds this loop; in practice it exits on the first try.
	for attempt := 0; attempt < 64; attempt++ {
		candidate := naming.SlugAttempt(r.ID, attempt)
		if !taken[candidate] {
			r.Slug = candidate
			return nil
		}
	}
	// Every candidate collided with a live run. Fall back to the id rather than
	// blocking the dispatch; the id is the real identity in any case.
	r.Slug = r.ID
	return nil
}

// ErrDuplicateRequestID reports that a run already exists for the caller's
// idempotency key, so this insert was a retry rather than a new request.
//
// It is a distinct sentinel because the alternative — a generic error — is
// indistinguishable from a disk failure, and the two demand opposite answers: a
// retry is answered with the original run and a 200, a disk failure with a 500.
var ErrDuplicateRequestID = errors.New("a run already exists for this request id")

// CreateRun writes a run row.
//
// When the run carries a RequestID, this insert is also the claim on that key.
// The claim is made by inserting and inspecting the failure, never by querying
// first: a query would let two concurrent callers both observe an unused key. A
// caller that receives ErrDuplicateRequestID should load the existing run with
// GetRunByRequestID and answer with it.
func (s *Store) CreateRun(r *RunRecord) error {
	if err := s.assignSlug(r); err != nil {
		return err
	}
	now := time.Now().UTC()
	r.CreatedAt = now
	r.UpdatedAt = now
	// The key is normalised here rather than at the call site so that no caller
	// can store a variant this lookup would then miss.
	r.RequestID = strings.TrimSpace(r.RequestID)
	_, err := s.db.Exec(
		`INSERT INTO runs (id, project, task_id, status, brief, change_id, type, intent_id, slug, request_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		r.ID, r.Project, r.TaskID, r.Status, r.Brief, r.ChangeID, r.Type, r.IntentID, r.Slug,
		nullableText(r.RequestID), r.CreatedAt, r.UpdatedAt,
	)
	if err != nil && isDuplicateRequestID(err) {
		// A refused key changed nothing, so nothing is appended to the sequence. A
		// change row here would make a deduplicated repeat look like a transition
		// and every subscriber would render a run that was not created.
		return fmt.Errorf("request id %q: %w", r.RequestID, ErrDuplicateRequestID)
	}
	if err != nil {
		return err
	}
	return s.recordTransition(ChannelRun, r.ID, map[string]interface{}{
		"transition": "created",
		"id":         r.ID,
		"project":    r.Project,
		"status":     r.Status,
		"slug":       r.Slug,
		"intent_id":  r.IntentID,
		"change_id":  r.ChangeID,
	})
}

// nullableText binds an absent string as SQL NULL rather than as ”.
//
// This is the whole mechanism behind an optional idempotency key. Under a unique
// index SQLite treats two NULLs as distinct and two empty strings as equal, so
// binding ” would make the second dispatch that omitted a key collide with the
// first.
func nullableText(v string) interface{} {
	if v == "" {
		return nil
	}
	return v
}

// isDuplicateRequestID reports whether err is the unique index on
// runs.request_id being violated, and not some other constraint.
//
// The result code alone is not enough. A duplicate run id is also reported as
// SQLITE_CONSTRAINT_UNIQUE, and treating that as a repeated key would answer a
// genuinely new dispatch with an unrelated run. SQLite names the offending index
// column in the message, so the column name is checked too: if another unique
// index is ever added to runs, this returns false and the caller reports a
// failure rather than silently returning the wrong run.
func isDuplicateRequestID(err error) bool {
	var se *sqlite.Error
	if !errors.As(err, &se) {
		return false
	}
	if se.Code() != sqlite3.SQLITE_CONSTRAINT_UNIQUE {
		return false
	}
	return strings.Contains(se.Error(), "runs.request_id")
}

// GetRunByRequestID loads the run that claimed an idempotency key.
//
// An empty key is not a key: returning the first run that happens to hold no key
// would make every keyless dispatch deduplicate against it, so an empty key
// reports ErrNoRows. ErrNoRows also distinguishes "no run ever claimed this key"
// from a real failure.
func (s *Store) GetRunByRequestID(requestID string) (*RunRecord, error) {
	requestID = strings.TrimSpace(requestID)
	if requestID == "" {
		return nil, sql.ErrNoRows
	}
	r, err := scanRun(s.db.QueryRow(
		`SELECT `+runColumns+` FROM runs WHERE request_id = ?`, requestID,
	))
	if err != nil {
		return nil, err
	}
	return &r, nil
}

func (s *Store) UpdateRunStatus(runID, status string) error {
	res, err := s.db.Exec(
		`UPDATE runs SET status = ?, updated_at = ? WHERE id = ?`,
		status, time.Now().UTC(), runID,
	)
	if err != nil {
		return err
	}
	// Only a row that actually moved is announced. This update matches nothing
	// when the id names no run, and a change row for it would tell every
	// subscriber that a run it cannot read had changed status. Unlike
	// UpdateIntentStatus this does not report the miss as an error: several callers
	// relabel a run they do not know still exists, and turning that into a failure
	// is a separate decision from keeping the sequence truthful.
	if !changedARow(res) {
		return nil
	}
	return s.recordTransition(ChannelRun, runID, map[string]interface{}{
		"transition": "status",
		"id":         runID,
		"status":     status,
		"terminal":   IsTerminalRunStatus(status),
	})
}

// changedARow reports whether a statement actually modified something. A driver
// that cannot say is treated as "yes": announcing a transition that may not have
// happened costs a subscriber one redundant re-read, while staying silent about
// one that did costs it the update entirely.
func changedARow(res sql.Result) bool {
	n, err := res.RowsAffected()
	if err != nil {
		return true
	}
	return n > 0
}

func (s *Store) RecordPhase(p *PhaseRecord) error {
	p.CreatedAt = time.Now().UTC()

	// R4.4: redact here, at the one place every PhaseRecord passes through no
	// matter which caller built it, rather than trusting each call site to
	// remember to redact before constructing one. Point-fixing individual
	// call sites (RunAgentPhase, RunCodeGate, sergeant_emit_envelope) closed
	// specific leaks across several review rounds but kept missing others
	// built the same way — this is the choke point instead of another one.
	p.Error = redact.Text(p.Error)
	p.Payload = redact.JSON(p.Payload)

	payloadStr := ""
	if len(p.Payload) > 0 {
		payloadStr = string(p.Payload)
	}
	_, err := s.db.Exec(
		`INSERT OR REPLACE INTO phases (id, run_id, repo, name, kind, status, error, duration_ms, payload, attempt, created_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		p.ID, p.RunID, p.Repo, p.Name, p.Kind, p.Status, p.Error, p.DurationMs, payloadStr, p.Attempt, p.CreatedAt,
	)
	if err != nil {
		return err
	}

	// Phase activity is run activity. A client decides whether to re-read a run's
	// detail from changes to runs.updated_at; without this the run appears frozen
	// at its first phase for its entire lifetime, and a mid-run gate failure is
	// never surfaced. This must stay in sync with any other writer of run state.
	if _, err := s.db.Exec(`UPDATE runs SET updated_at = ? WHERE id = ?`, p.CreatedAt, p.RunID); err != nil {
		return err
	}

	// The phase is announced on its own channel, carrying the run it belongs to.
	// That is what lets a client refresh one run's detail instead of re-reading
	// the whole list, which is the incremental update the polling loop could not
	// express.
	return s.recordTransition(ChannelPhase, p.ID, map[string]interface{}{
		"id":          p.ID,
		"run_id":      p.RunID,
		"repo":        p.Repo,
		"name":        p.Name,
		"kind":        p.Kind,
		"status":      p.Status,
		"duration_ms": p.DurationMs,
	})
}

// ErrDuplicateEnvelopeID is returned when an envelope with the same id has
// already been published. R5.1 requires immutability after publication.
var ErrDuplicateEnvelopeID = errors.New("an envelope with this id has already been published")

// RecordEnvelope validates, stamps PublishedAt and writes the envelope.
//
// Validation rules (all apply to new writes only; existing rows are unaffected):
//   - Type must not be empty.
//   - SchemaVersion must not be empty.
//   - Producer must not be empty.
//   - CorrelationID must not be empty.
//   - The id must not already exist (immutability after publication).
//
// On any validation failure the function returns an error and writes nothing.
func (s *Store) RecordEnvelope(e *EnvelopeRecord) error {
	// --- validation ---
	if e.Type == "" {
		return fmt.Errorf("envelope %q: type must not be empty", e.ID)
	}
	if e.SchemaVersion == "" {
		return fmt.Errorf("envelope %q: schema_version must not be empty", e.ID)
	}
	if e.Producer == "" {
		return fmt.Errorf("envelope %q: producer must not be empty", e.ID)
	}
	if e.CorrelationID == "" {
		return fmt.Errorf("envelope %q: correlation_id must not be empty", e.ID)
	}

	// --- redact (R4.4) ---
	// The same choke-point reasoning as RecordPhase: every EnvelopeRecord
	// passes through here regardless of which caller (RunAgentPhase, the MCP
	// server, handleCreatePR, ...) built it.
	e.Summary = redact.Text(e.Summary)
	e.Data = redact.JSON(e.Data)
	for i, a := range e.Artifacts {
		e.Artifacts[i] = redact.Text(a)
	}

	// --- stamp ---
	now := time.Now().UTC()
	e.CreatedAt = now
	e.PublishedAt = now

	// --- write ---
	artBytes, _ := json.Marshal(e.Artifacts)
	dataStr := string(e.Data)
	_, err := s.db.Exec(
		`INSERT INTO envelopes
		 (id, run_id, repo, stage, summary, artifacts, data, created_at,
		  type, schema_version, occurred_at, published_at, producer, correlation_id, causation_id, phase_id)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		e.ID, e.RunID, e.Repo, e.Stage, e.Summary, string(artBytes), dataStr, e.CreatedAt,
		e.Type, e.SchemaVersion, e.OccurredAt, e.PublishedAt, e.Producer, e.CorrelationID,
		nullableText(causationIDValue(e.CausationID)), e.PhaseID,
	)
	if err != nil {
		if isDuplicateEnvelopeID(err) {
			return fmt.Errorf("envelope %q: %w", e.ID, ErrDuplicateEnvelopeID)
		}
		return err
	}
	return s.recordTransition(ChannelEnvelope, e.ID, map[string]interface{}{
		"id":     e.ID,
		"run_id": e.RunID,
		"repo":   e.Repo,
		"stage":  e.Stage,
	})
}

// causationIDValue dereferences a *string or returns "" (which nullableText
// turns into SQL NULL) when the pointer is nil.
func causationIDValue(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

// isDuplicateEnvelopeID reports whether err is a constraint violation on
// envelopes.id (its PRIMARY KEY) rather than some other constraint.
//
// envelopes.id is TEXT PRIMARY KEY, not a separate UNIQUE index, so a
// duplicate insert raises SQLITE_CONSTRAINT_PRIMARYKEY (1555), not
// SQLITE_CONSTRAINT_UNIQUE (2067) — checking only the latter (as this
// function originally did) meant it never matched a real duplicate-id
// insert, silently making ErrDuplicateEnvelopeID unreachable. Republication
// was still refused either way, because the raw INSERT itself fails
// regardless of how this classifier reads the error; the bug was that no
// caller checking errors.Is(err, ErrDuplicateEnvelopeID) could ever see it.
func isDuplicateEnvelopeID(err error) bool {
	var se *sqlite.Error
	if !errors.As(err, &se) {
		return false
	}
	switch se.Code() {
	case sqlite3.SQLITE_CONSTRAINT_PRIMARYKEY, sqlite3.SQLITE_CONSTRAINT_UNIQUE:
	default:
		return false
	}
	return strings.Contains(se.Error(), "envelopes.id")
}

// safeRawJSON guards the API against rows whose JSON was written by a buggy
// producer. An invalid json.RawMessage fails to marshal and takes the entire
// response down with it, so preserve the bytes as a string instead.
func safeRawJSON(s string) json.RawMessage {
	if s == "" {
		return nil
	}
	if b := []byte(s); json.Valid(b) {
		return json.RawMessage(b)
	}
	wrapped, err := json.Marshal(map[string]string{"malformed_raw": s})
	if err != nil {
		return json.RawMessage(`{"malformed_raw":""}`)
	}
	return json.RawMessage(wrapped)
}

// envelopeColumns is the SELECT list shared by every envelope query so a column
// added to EnvelopeRecord cannot be read by one path and silently omitted by
// another. scanEnvelope consumes it in the same order.
//
// DATETIME columns that may be wrapped in COALESCE are scanned as strings and
// parsed by scanEnvelope because the modernc/sqlite driver returns COALESCE
// results as driver.Value (string), which cannot be Scan'd into time.Time
// directly. The plain created_at column is selected without COALESCE and scanned
// directly — the driver handles that case.
const envelopeColumns = `id, run_id, repo, stage, summary,
	COALESCE(artifacts, ''),
	COALESCE(data, ''),
	created_at,
	COALESCE(type, ''),
	COALESCE(schema_version, ''),
	occurred_at,
	published_at,
	COALESCE(producer, ''),
	COALESCE(correlation_id, ''),
	causation_id,
	COALESCE(phase_id, '')`

// parseSQLiteTime parses the datetime string formats that the modernc/sqlite
// driver stores DATETIME values in.  It returns the zero time for an empty or
// unrecognised value so callers can distinguish "never set" from a real time.
func parseSQLiteTime(s string) time.Time {
	if s == "" {
		return time.Time{}
	}
	formats := []string{
		"2006-01-02 15:04:05.999999999-07:00",
		"2006-01-02 15:04:05.999999999",
		"2006-01-02T15:04:05.999999999Z07:00",
		"2006-01-02T15:04:05.999999999Z",
		"2006-01-02 15:04:05",
		"2006-01-02T15:04:05Z",
		"0001-01-01 00:00:00",
		"0001-01-01T00:00:00Z",
	}
	for _, f := range formats {
		if t, err := time.Parse(f, s); err == nil {
			return t.UTC()
		}
	}
	return time.Time{}
}

// scanEnvelope reads one envelope row from r, handling the new nullable columns
// so callers do not each have to duplicate the NULL-handling logic.
//
// The occurred_at and published_at DATETIME columns are scanned as sql.NullString
// and parsed by parseSQLiteTime because the modernc/sqlite driver returns COALESCE
// and nullable DATETIME results as strings, not time.Time values.
func scanEnvelope(r rowScanner) (EnvelopeRecord, error) {
	var e EnvelopeRecord
	var artStr, dataStr string
	var causationStr sql.NullString
	var occurredStr, publishedStr sql.NullString
	err := r.Scan(
		&e.ID, &e.RunID, &e.Repo, &e.Stage, &e.Summary,
		&artStr, &dataStr, &e.CreatedAt,
		&e.Type, &e.SchemaVersion,
		&occurredStr, &publishedStr,
		&e.Producer, &e.CorrelationID,
		&causationStr,
		&e.PhaseID,
	)
	if err != nil {
		return EnvelopeRecord{}, err
	}
	_ = json.Unmarshal([]byte(artStr), &e.Artifacts)
	e.Data = safeRawJSON(dataStr)
	if occurredStr.Valid {
		e.OccurredAt = parseSQLiteTime(occurredStr.String)
	}
	if publishedStr.Valid {
		e.PublishedAt = parseSQLiteTime(publishedStr.String)
	}
	if causationStr.Valid {
		e.CausationID = &causationStr.String
	}
	return e, nil
}

func (s *Store) GetLatestEnvelope(runID, repo string) (*EnvelopeRecord, error) {
	row := s.db.QueryRow(
		`SELECT `+envelopeColumns+` FROM envelopes
		 WHERE run_id = ? AND repo = ? ORDER BY created_at DESC LIMIT 1`,
		runID, repo,
	)
	e, err := scanEnvelope(row)
	if err != nil {
		return nil, err
	}
	return &e, nil
}

// CausationFromLatest returns the id of the most recently published envelope
// for runID/repo, or nil if there is none. Callers use this to set a new
// envelope's CausationID: an envelope that follows another within a run names
// it as its cause, and the first envelope of a run has no cause.
func (s *Store) CausationFromLatest(runID, repo string) *string {
	latest, err := s.GetLatestEnvelope(runID, repo)
	if err != nil {
		return nil
	}
	id := latest.ID
	return &id
}

// runColumns is shared by every run query so a column added to RunRecord cannot
// be read by one lister and silently omitted by another. scanRun consumes it in
// the same order.
const runColumns = `id, project, task_id, status,
	COALESCE(brief, ''), COALESCE(change_id, ''), COALESCE(type, ''), COALESCE(intent_id, ''), COALESCE(slug, ''),
	COALESCE(request_id, ''), created_at, updated_at`

// rowScanner is satisfied by both *sql.Row and *sql.Rows, so a single-row lookup
// and a listing share one run-scanning helper instead of each maintaining its own
// column order.
type rowScanner interface {
	Scan(dest ...interface{}) error
}

func scanRun(row rowScanner) (RunRecord, error) {
	var r RunRecord
	err := row.Scan(
		&r.ID, &r.Project, &r.TaskID, &r.Status,
		&r.Brief, &r.ChangeID, &r.Type, &r.IntentID, &r.Slug,
		&r.RequestID, &r.CreatedAt, &r.UpdatedAt,
	)
	return r, err
}

func (s *Store) ListRecentRuns(limit int) ([]RunRecord, error) {
	rows, err := s.db.Query(
		`SELECT `+runColumns+` FROM runs ORDER BY created_at DESC LIMIT ?`,
		limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var list []RunRecord
	for rows.Next() {
		r, err := scanRun(rows)
		if err != nil {
			return nil, err
		}
		list = append(list, r)
	}
	return list, rows.Err()
}

// rotationEligibleStatusesSQL is the terminal-status list RunsEligibleForCleanup
// and RotateProject (internal/store/retention.go) both filter on. It is a
// single named literal, not two copies, so a future change to either list
// cannot silently drift from the other. It excludes "timed_out" even though
// IsTerminalRunStatus treats that status as terminal — narrower on purpose,
// matching RunsEligibleForCleanup's already-shipped behavior, which this
// does not change.
const rotationEligibleStatusesSQL = `'passed','failed','cancelled','interrupted'`

// RunsEligibleForCleanup returns terminal runs whose UpdatedAt is at or
// before cutoff — used by the automatic fleet-cleanup pass so it does not
// have to rely on ListRecentRuns' fixed 200-row window, which answers "is
// this specific recent run still running", not "find every old terminal
// run". A run in status "running" is never eligible, no matter how old.
func (s *Store) RunsEligibleForCleanup(cutoff time.Time) ([]RunRecord, error) {
	rows, err := s.db.Query(
		`SELECT `+runColumns+` FROM runs
		 WHERE status IN (`+rotationEligibleStatusesSQL+`)
		   AND updated_at <= ?
		 ORDER BY updated_at ASC`,
		cutoff,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var list []RunRecord
	for rows.Next() {
		r, err := scanRun(rows)
		if err != nil {
			return nil, err
		}
		list = append(list, r)
	}
	return list, rows.Err()
}

// GetRun loads one run by id. ErrNoRows distinguishes "no such run" from a real
// failure, so a caller can answer 404 rather than 500.
//
// It reads runColumns like every other run query. It used to inline its own
// column list, which is what runColumns exists to prevent: the list had fallen a
// column behind, so a run loaded here reported no intent whatever it served.
func (s *Store) GetRun(runID string) (*RunRecord, error) {
	r, err := scanRun(s.db.QueryRow(
		`SELECT `+runColumns+` FROM runs WHERE id = ?`, runID,
	))
	if err != nil {
		return nil, err
	}
	return &r, nil
}

func (s *Store) ListPhasesForRun(runID string) ([]PhaseRecord, error) {
	rows, err := s.db.Query(
		`SELECT id, run_id, repo, name, kind, status, error, duration_ms, payload, attempt, created_at FROM phases WHERE run_id = ? ORDER BY created_at ASC`,
		runID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var list []PhaseRecord
	for rows.Next() {
		var p PhaseRecord
		var payloadStr sql.NullString
		var errStr sql.NullString
		if err := rows.Scan(&p.ID, &p.RunID, &p.Repo, &p.Name, &p.Kind, &p.Status, &errStr, &p.DurationMs, &payloadStr, &p.Attempt, &p.CreatedAt); err != nil {
			return nil, err
		}
		if errStr.Valid {
			p.Error = errStr.String
		}
		p.Payload = safeRawJSON(payloadStr.String)
		list = append(list, p)
	}
	return list, nil
}

func (s *Store) ListEnvelopesForRun(runID string) ([]EnvelopeRecord, error) {
	rows, err := s.db.Query(
		`SELECT `+envelopeColumns+` FROM envelopes WHERE run_id = ? ORDER BY created_at ASC`,
		runID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var list []EnvelopeRecord
	for rows.Next() {
		e, err := scanEnvelope(rows)
		if err != nil {
			return nil, err
		}
		list = append(list, e)
	}
	return list, rows.Err()
}

func (s *Store) DeleteRun(runID string) error {
	_, err := s.db.Exec(`DELETE FROM phases WHERE run_id = ?`, runID)
	if err != nil {
		return err
	}
	_, err = s.db.Exec(`DELETE FROM envelopes WHERE run_id = ?`, runID)
	if err != nil {
		return err
	}
	res, err := s.db.Exec(`DELETE FROM runs WHERE id = ?`, runID)
	if err != nil {
		return err
	}
	// A deletion is a transition too. Without it a client that follows the
	// sequence keeps rendering a run that no longer exists until it happens to
	// re-read the whole list. Deleting an id that was never there is not a
	// transition, so it is not announced.
	if !changedARow(res) {
		return nil
	}
	return s.recordTransition(ChannelRun, runID, map[string]interface{}{
		"transition": "deleted",
		"id":         runID,
	})
}

func (s *Store) CreateIntent(i *IntentRecord) error {
	now := time.Now().UTC()
	i.CreatedAt = now
	i.UpdatedAt = now
	_, err := s.db.Exec(
		`INSERT INTO intents (id, project, statement, status, change_id, change_repo, type, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		i.ID, i.Project, i.Statement, i.Status, i.ChangeID, i.ChangeRepo, i.Type, i.CreatedAt, i.UpdatedAt,
	)
	if err != nil {
		return err
	}
	return s.recordTransition(ChannelIntent, i.ID, map[string]interface{}{
		"transition": "created",
		"id":         i.ID,
		"project":    i.Project,
		"status":     i.Status,
	})
}

// intentColumns is the SELECT list shared by every intent query so a column
// added to IntentRecord cannot be read by one lister and silently omitted by
// another, the same reasoning as runColumns. scanIntent consumes it in the
// same order.
const intentColumns = `id, project, COALESCE(statement, ''), status,
	COALESCE(change_id, ''), COALESCE(change_repo, ''), COALESCE(type, ''),
	COALESCE(shipping_gate_status, ''), COALESCE(shipping_gate_reason, ''),
	created_at, updated_at`

func scanIntent(r rowScanner) (IntentRecord, error) {
	var i IntentRecord
	err := r.Scan(&i.ID, &i.Project, &i.Statement, &i.Status, &i.ChangeID, &i.ChangeRepo, &i.Type,
		&i.ShippingGateStatus, &i.ShippingGateReason,
		&i.CreatedAt, &i.UpdatedAt)
	return i, err
}

func (s *Store) GetIntent(intentID string) (*IntentRecord, error) {
	i, err := scanIntent(s.db.QueryRow(
		`SELECT `+intentColumns+` FROM intents WHERE id = ?`,
		intentID,
	))
	if err != nil {
		return nil, err
	}
	return &i, nil
}

// GetBullet resolves a single bullet by id.
//
// It exists alongside ListBulletsForIntent (which requires already knowing
// the intent) because a caller that only has a bullet id — internal/export's
// Runner, resolving a ChannelBullet change log entry whose payload carries
// no intent_id — has no other way to reach the current row.
func (s *Store) GetBullet(bulletID string) (*BulletRecord, error) {
	var b BulletRecord
	err := s.db.QueryRow(
		`SELECT id, intent_id, repo, position, status,
		        COALESCE(branch, ''), COALESCE(worktree, ''), COALESCE(commit_sha, ''), COALESCE(pr_url, ''),
		        COALESCE(blocked_reason, ''),
		        created_at, updated_at
		 FROM bullets WHERE id = ?`,
		bulletID,
	).Scan(
		&b.ID, &b.IntentID, &b.Repo, &b.Position, &b.Status,
		&b.Branch, &b.Worktree, &b.CommitSHA, &b.PRURL,
		&b.BlockedReason,
		&b.CreatedAt, &b.UpdatedAt,
	)
	if err != nil {
		return nil, err
	}
	return &b, nil
}

func (s *Store) ListIntentsForProject(project string) ([]IntentRecord, error) {
	rows, err := s.db.Query(
		`SELECT `+intentColumns+` FROM intents WHERE project = ? ORDER BY created_at DESC, id ASC`,
		project,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var list []IntentRecord
	for rows.Next() {
		i, err := scanIntent(rows)
		if err != nil {
			return nil, err
		}
		list = append(list, i)
	}
	return list, rows.Err()
}

// ListIntentsByStatus lists every intent in a given status, most recent first.
//
// This is how a plan awaiting approval (decision D2) is found: it is an intent
// like any other, distinguished only by Status == "proposed", so listing by
// status rather than adding a parallel table is what surfaces it.
func (s *Store) ListIntentsByStatus(status string) ([]IntentRecord, error) {
	rows, err := s.db.Query(
		`SELECT `+intentColumns+` FROM intents WHERE status = ? ORDER BY created_at DESC, id ASC`,
		status,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var list []IntentRecord
	for rows.Next() {
		i, err := scanIntent(rows)
		if err != nil {
			return nil, err
		}
		list = append(list, i)
	}
	return list, rows.Err()
}

// UpdateIntentStatus reports an error when no intent has that id. A silent
// no-op would let a caller believe it had moved an intent that does not exist.
func (s *Store) UpdateIntentStatus(intentID, status string) error {
	res, err := s.db.Exec(
		`UPDATE intents SET status = ?, updated_at = ? WHERE id = ?`,
		status, time.Now().UTC(), intentID,
	)
	if err != nil {
		return err
	}
	if err := requireOneRow(res, "intent", intentID); err != nil {
		return err
	}
	return s.recordTransition(ChannelIntent, intentID, map[string]interface{}{
		"transition": "status",
		"id":         intentID,
		"status":     status,
	})
}

// RecordShippingGateResult records the outcome of an intent's shipping gate.
// Unlike AdvanceBulletsForRun, this never touches any BulletRecord — a
// shipping-gate failure is evidence about the intent, not a bullet outcome, and
// no individual bullet's honestly-earned sealed status changes because of it.
func (s *Store) RecordShippingGateResult(intentID string, passed bool, reason string) error {
	status := "passed"
	if !passed {
		status = "failed"
	} else {
		reason = "" // a pass never carries a reason, mirroring BlockedReason's rule
	}
	res, err := s.db.Exec(
		`UPDATE intents SET shipping_gate_status = ?, shipping_gate_reason = ?, updated_at = ? WHERE id = ?`,
		status, reason, time.Now().UTC(), intentID,
	)
	if err != nil {
		return err
	}
	if err := requireOneRow(res, "intent", intentID); err != nil {
		return err
	}
	return s.recordTransition(ChannelIntent, intentID, map[string]interface{}{
		"transition":           "shipping_gate",
		"id":                   intentID,
		"shipping_gate_status": status,
	})
}

func (s *Store) CreateBullet(b *BulletRecord) error {
	now := time.Now().UTC()
	b.CreatedAt = now
	b.UpdatedAt = now
	_, err := s.db.Exec(
		`INSERT INTO bullets (id, intent_id, repo, position, status, branch, worktree, commit_sha, pr_url, created_at, updated_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		b.ID, b.IntentID, b.Repo, b.Position, b.Status, b.Branch, b.Worktree, b.CommitSHA, b.PRURL, b.CreatedAt, b.UpdatedAt,
	)
	if err != nil {
		return err
	}
	return s.recordTransition(ChannelBullet, b.ID, map[string]interface{}{
		"transition": "created",
		"id":         b.ID,
		"intent_id":  b.IntentID,
		"repo":       b.Repo,
		"position":   b.Position,
		"status":     b.Status,
	})
}

// ListBulletsForIntent returns an intent's bullets in merge order.
func (s *Store) ListBulletsForIntent(intentID string) ([]BulletRecord, error) {
	rows, err := s.db.Query(
		`SELECT id, intent_id, repo, position, status,
		        COALESCE(branch, ''), COALESCE(worktree, ''), COALESCE(commit_sha, ''), COALESCE(pr_url, ''),
		        COALESCE(blocked_reason, ''),
		        created_at, updated_at
		 FROM bullets WHERE intent_id = ? ORDER BY position ASC, created_at ASC, id ASC`,
		intentID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var list []BulletRecord
	for rows.Next() {
		var b BulletRecord
		if err := rows.Scan(
			&b.ID, &b.IntentID, &b.Repo, &b.Position, &b.Status,
			&b.Branch, &b.Worktree, &b.CommitSHA, &b.PRURL,
			&b.BlockedReason,
			&b.CreatedAt, &b.UpdatedAt,
		); err != nil {
			return nil, err
		}
		list = append(list, b)
	}
	return list, rows.Err()
}

// UpdateBulletStatus reports an error when no bullet has that id, for the same
// reason as UpdateIntentStatus.
func (s *Store) UpdateBulletStatus(bulletID, status string) error {
	res, err := s.db.Exec(
		`UPDATE bullets SET status = ?, updated_at = ? WHERE id = ?`,
		status, time.Now().UTC(), bulletID,
	)
	if err != nil {
		return err
	}
	if err := requireOneRow(res, "bullet", bulletID); err != nil {
		return err
	}
	return s.recordTransition(ChannelBullet, bulletID, map[string]interface{}{
		"transition": "status",
		"id":         bulletID,
		"status":     status,
	})
}

// AdvanceBulletsForRun moves every bullet the run carries to status, carrying
// reason alongside it, then re-derives the run's intent from those bullets.
// reason is only meaningful for "blocked" (BulletRecord.BlockedReason); every
// other status is expected to pass "", the value BlockedReason holds for a
// bullet that was never stuck.
//
// A bullet belongs to an intent and a run names the intent it serves, so "the
// bullets of a run" are the bullets of its intent. Advancing and re-deriving in
// one call is what stops the two records stating different things about the same
// work: there is no way to move a bullet through this method and leave the intent
// reading the bullets as they were.
//
// It is idempotent. A resumed run reaches its terminal path a second time, and a
// bullet already holding status and reason is skipped rather than rewritten —
// rewriting would bump updated_at and publish a transition event for a
// transition that did not happen.
func (s *Store) AdvanceBulletsForRun(runID, status, reason string) error {
	run, err := s.GetRun(runID)
	if err != nil {
		return fmt.Errorf("loading run %q to advance its bullets: %w", runID, err)
	}
	// Runs written before a dispatch persisted its intent carry no intent id.
	// Empty means "no intent was recorded", never "the intent is unknown but
	// exists", so there is nothing to advance and nothing to report.
	if run.IntentID == "" {
		return nil
	}

	bullets, err := s.ListBulletsForIntent(run.IntentID)
	if err != nil {
		return fmt.Errorf("listing the bullets of intent %q: %w", run.IntentID, err)
	}
	for _, b := range bullets {
		if b.Status == status && b.BlockedReason == reason {
			continue
		}
		if err := s.updateBulletStatusAndReason(b.ID, status, reason); err != nil {
			return fmt.Errorf("advancing bullet %q to %q: %w", b.ID, status, err)
		}
	}

	_, err = s.RecomputeIntentStatus(run.IntentID)
	return err
}

// updateBulletStatusAndReason is AdvanceBulletsForRun's write path: unlike
// UpdateBulletStatus, it also sets BlockedReason, since a run outcome is the
// only source of that field.
func (s *Store) updateBulletStatusAndReason(bulletID, status, reason string) error {
	res, err := s.db.Exec(
		`UPDATE bullets SET status = ?, blocked_reason = ?, updated_at = ? WHERE id = ?`,
		status, reason, time.Now().UTC(), bulletID,
	)
	if err != nil {
		return err
	}
	if err := requireOneRow(res, "bullet", bulletID); err != nil {
		return err
	}
	return s.recordTransition(ChannelBullet, bulletID, map[string]interface{}{
		"transition": "status",
		"id":         bulletID,
		"status":     status,
	})
}

// SealBulletForRun marks the bullet for (the intent behind runID, repo) as
// sealed, refusing unless it is currently green. A bullet is scoped to
// exactly one repository, so unlike AdvanceBulletsForRun this updates one
// bullet, not every bullet of the run's intent — sealing records that a human
// approved THIS repo's delivery (R3.5), not the run's gate outcome. On any
// refusal it writes nothing.
func (s *Store) SealBulletForRun(runID, repo string) error {
	run, err := s.GetRun(runID)
	if err != nil {
		return fmt.Errorf("loading run %q to seal its bullet: %w", runID, err)
	}
	if run.IntentID == "" {
		return fmt.Errorf("run %q has no intent; nothing to seal", runID)
	}

	bullets, err := s.ListBulletsForIntent(run.IntentID)
	if err != nil {
		return fmt.Errorf("listing the bullets of intent %q: %w", run.IntentID, err)
	}
	for _, b := range bullets {
		if b.Repo != repo {
			continue
		}
		if b.Status != "green" {
			return fmt.Errorf("bullet %q for repo %q is %q, not green — refusing to seal", b.ID, repo, b.Status)
		}
		return s.UpdateBulletStatus(b.ID, "sealed")
	}
	return fmt.Errorf("no bullet found for repo %q on intent %q", repo, run.IntentID)
}

// RecomputeIntentStatus re-reads an intent's status from its bullets and stores
// the answer, returning it.
//
// Intent status is derived, never assigned from a single run's outcome: an intent
// may span several bullets and several runs, so no one run knows whether the
// intent is complete. The store writes only when the derived status differs from
// the stored one, so a recompute that changes nothing announces nothing.
func (s *Store) RecomputeIntentStatus(intentID string) (string, error) {
	intent, err := s.GetIntent(intentID)
	if err != nil {
		return "", fmt.Errorf("loading intent %q to derive its status: %w", intentID, err)
	}
	bullets, err := s.ListBulletsForIntent(intentID)
	if err != nil {
		return "", fmt.Errorf("listing the bullets of intent %q: %w", intentID, err)
	}

	derived := DeriveIntentStatus(bullets)
	if derived == intent.Status {
		return derived, nil
	}
	if err := s.UpdateIntentStatus(intentID, derived); err != nil {
		return "", err
	}
	return derived, nil
}

// DeriveIntentStatus reads an intent's status from its bullets.
//
// An intent is satisfied only when every one of its bullets is merged, and merged
// is reachable only from observed pull-request state. Decision D6 says sergeant
// never merges, so this is what keeps "satisfied" out of reach of any automatic
// transition: there is no argument to this function that a run outcome alone can
// produce.
//
// The empty case is answered before the rule is applied. "Every bullet is merged"
// is vacuously true for an empty set, which would silently satisfy an intent that
// has had no work done against it.
func DeriveIntentStatus(bullets []BulletRecord) string {
	if len(bullets) == 0 {
		return "in_progress"
	}
	for _, b := range bullets {
		if b.Status != "merged" {
			return "in_progress"
		}
	}
	return "satisfied"
}

// AllBulletsSealedOrMerged reports whether every one of an intent's bullets has
// reached sealed or merged — the condition that makes the intent, as a whole, a
// candidate for its shipping gate. merged is accepted alongside sealed for
// BulletProgression's documented ordering (sealed -> merged), though as of this
// change nothing in the codebase ever writes "merged" to a bullet yet — no code
// path observes real PR merge state. Accepting it now costs nothing and avoids
// this predicate needing a second revision the day that path exists.
//
// The empty case is answered before the rule is applied — the opposite answer
// from DeriveIntentStatus's empty case, because the two functions answer
// different questions: "every bullet is sealed-or-merged" is vacuously true for
// an empty set, which would trigger a shipping gate for an intent that has had
// no bullets created against it at all.
func AllBulletsSealedOrMerged(bullets []BulletRecord) bool {
	if len(bullets) == 0 {
		return false
	}
	for _, b := range bullets {
		if b.Status != "sealed" && b.Status != "merged" {
			return false
		}
	}
	return true
}

func requireOneRow(res sql.Result, kind, id string) error {
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return fmt.Errorf("no %s with id %q", kind, id)
	}
	return nil
}

func (s *Store) ListRunsForProject(project string, limit int) ([]RunRecord, error) {
	rows, err := s.db.Query(
		`SELECT `+runColumns+` FROM runs WHERE project = ? ORDER BY created_at DESC LIMIT ?`,
		project, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var list []RunRecord
	for rows.Next() {
		r, err := scanRun(rows)
		if err != nil {
			return nil, err
		}
		list = append(list, r)
	}
	return list, rows.Err()
}

// createExportCursorTable holds internal/export.Runner's durable read
// position in the changes log. id = 1 is a singleton-row constraint: there is
// one export cursor for the whole store, matching changes' own single global
// sequence — the log is one ordered stream regardless of how many projects or
// targets read it, and per-target cursors are not needed until a second
// Target actually exists.
const createExportCursorTable = `
	CREATE TABLE IF NOT EXISTS export_cursor (
		id INTEGER PRIMARY KEY CHECK (id = 1),
		last_seq INTEGER NOT NULL DEFAULT 0
	);`

// LoadExportCursor reports the last change sequence number
// internal/export.Runner has successfully exported past. A store that has
// never saved a cursor reads back 0, the same starting point as an unread
// changes log.
func (s *Store) LoadExportCursor() (int64, error) {
	var seq int64
	err := s.db.QueryRow(`SELECT last_seq FROM export_cursor WHERE id = 1`).Scan(&seq)
	if err == sql.ErrNoRows {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	return seq, nil
}

// SaveExportCursor persists the last change sequence number
// internal/export.Runner has successfully exported past. It is INSERT OR
// REPLACE, not update-and-check, because the row is a singleton that may not
// exist yet on a store's first export.
func (s *Store) SaveExportCursor(seq int64) error {
	_, err := s.db.Exec(`INSERT OR REPLACE INTO export_cursor (id, last_seq) VALUES (1, ?)`, seq)
	return err
}
