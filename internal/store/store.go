package store

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/callmeradical/sergeant/internal/naming"

	_ "modernc.org/sqlite"
)

type Store struct {
	db *sql.DB
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
	// Slug is a short, speakable label for the run (adverb-adjective-noun). It is
	// a display and speech label only; ID remains the run's identity.
	Slug      string    `json:"slug"`
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
	CreatedAt  time.Time       `json:"created_at"`
}

// IntentRecord is the primary durable object. An intent may span repositories;
// the ordering between them lives in its bullets' Position values.
type IntentRecord struct {
	ID        string    `json:"id"`
	Project   string    `json:"project"`
	Statement string    `json:"statement"`
	Status    string    `json:"status"` // proposed, approved, in_progress, satisfied, abandoned
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
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
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

// BulletStatuses is the full set of BulletRecord.Status values, in lifecycle
// order: a bullet is created pending, records red then green evidence (D3), is
// sealed into a PR, and is merged by a human (D6). failed is the terminal
// alternative and sorts last because it can be reached from any earlier state.
//
// This exists as code rather than only as a comment because the dashboard renders
// the lifecycle as the tail of the workflow graph. A hand-copied list in the UI
// would be free to invent a status the store never writes.
//
// A fresh slice is returned on every call so no caller can mutate it.
func BulletStatuses() []string {
	return []string{"pending", "red", "green", "sealed", "merged", "failed"}
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
	` + createIntentsTable + createBulletsTable
	if _, err := s.db.Exec(schema); err != nil {
		return err
	}
	if err := s.migrateAddTables(); err != nil {
		return err
	}
	if err := s.migrateAddColumns(); err != nil {
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
		{"bullets", "branch", "ALTER TABLE bullets ADD COLUMN branch TEXT NOT NULL DEFAULT ''"},
		{"bullets", "worktree", "ALTER TABLE bullets ADD COLUMN worktree TEXT NOT NULL DEFAULT ''"},
		{"bullets", "commit_sha", "ALTER TABLE bullets ADD COLUMN commit_sha TEXT NOT NULL DEFAULT ''"},
		{"bullets", "pr_url", "ALTER TABLE bullets ADD COLUMN pr_url TEXT NOT NULL DEFAULT ''"},
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

// terminalRunStatuses are the states after which a slug may be reused. A slug is
// a speech label, so it only has to be unambiguous while the run is live.
var terminalRunStatuses = map[string]bool{"passed": true, "failed": true, "cancelled": true}

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

func (s *Store) CreateRun(r *RunRecord) error {
	if err := s.assignSlug(r); err != nil {
		return err
	}
	now := time.Now().UTC()
	r.CreatedAt = now
	r.UpdatedAt = now
	_, err := s.db.Exec(
		`INSERT INTO runs (id, project, task_id, status, brief, change_id, slug, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		r.ID, r.Project, r.TaskID, r.Status, r.Brief, r.ChangeID, r.Slug, r.CreatedAt, r.UpdatedAt,
	)
	return err
}

func (s *Store) UpdateRunStatus(runID, status string) error {
	_, err := s.db.Exec(
		`UPDATE runs SET status = ?, updated_at = ? WHERE id = ?`,
		status, time.Now().UTC(), runID,
	)
	return err
}

func (s *Store) RecordPhase(p *PhaseRecord) error {
	p.CreatedAt = time.Now().UTC()
	payloadStr := ""
	if len(p.Payload) > 0 {
		payloadStr = string(p.Payload)
	}
	_, err := s.db.Exec(
		`INSERT OR REPLACE INTO phases (id, run_id, repo, name, kind, status, error, duration_ms, payload, created_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		p.ID, p.RunID, p.Repo, p.Name, p.Kind, p.Status, p.Error, p.DurationMs, payloadStr, p.CreatedAt,
	)
	if err != nil {
		return err
	}

	// Phase activity is run activity. Clients poll for changes to runs.updated_at
	// to decide whether to refetch details; without this the run appears frozen at
	// its first phase for its entire lifetime, and a mid-run gate failure is never
	// surfaced. This must stay in sync with any other writer of run state.
	_, err = s.db.Exec(`UPDATE runs SET updated_at = ? WHERE id = ?`, p.CreatedAt, p.RunID)
	return err
}

func (s *Store) RecordEnvelope(e *EnvelopeRecord) error {
	e.CreatedAt = time.Now().UTC()
	artBytes, _ := json.Marshal(e.Artifacts)
	dataStr := string(e.Data)
	_, err := s.db.Exec(
		`INSERT OR REPLACE INTO envelopes (id, run_id, repo, stage, summary, artifacts, data, created_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		e.ID, e.RunID, e.Repo, e.Stage, e.Summary, string(artBytes), dataStr, e.CreatedAt,
	)
	return err
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

func (s *Store) GetLatestEnvelope(runID, repo string) (*EnvelopeRecord, error) {
	row := s.db.QueryRow(
		`SELECT id, run_id, repo, stage, summary, artifacts, data, created_at FROM envelopes 
		 WHERE run_id = ? AND repo = ? ORDER BY created_at DESC LIMIT 1`,
		runID, repo,
	)
	var e EnvelopeRecord
	var artStr, dataStr string
	err := row.Scan(&e.ID, &e.RunID, &e.Repo, &e.Stage, &e.Summary, &artStr, &dataStr, &e.CreatedAt)
	if err != nil {
		return nil, err
	}
	_ = json.Unmarshal([]byte(artStr), &e.Artifacts)
	e.Data = safeRawJSON(dataStr)
	return &e, nil
}

func (s *Store) ListRecentRuns(limit int) ([]RunRecord, error) {
	rows, err := s.db.Query(
		`SELECT id, project, task_id, status, COALESCE(brief, ''), COALESCE(change_id, ''), COALESCE(slug, ''), created_at, updated_at FROM runs ORDER BY created_at DESC LIMIT ?`,
		limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var list []RunRecord
	for rows.Next() {
		var r RunRecord
		if err := rows.Scan(&r.ID, &r.Project, &r.TaskID, &r.Status, &r.Brief, &r.ChangeID, &r.Slug, &r.CreatedAt, &r.UpdatedAt); err != nil {
			return nil, err
		}
		list = append(list, r)
	}
	return list, nil
}

// GetRun loads one run by id. ErrNoRows distinguishes "no such run" from a real
// failure, so a caller can answer 404 rather than 500.
func (s *Store) GetRun(runID string) (*RunRecord, error) {
	var r RunRecord
	err := s.db.QueryRow(
		`SELECT id, project, task_id, status, COALESCE(brief, ''), COALESCE(change_id, ''), COALESCE(slug, ''), created_at, updated_at FROM runs WHERE id = ?`,
		runID,
	).Scan(&r.ID, &r.Project, &r.TaskID, &r.Status, &r.Brief, &r.ChangeID, &r.Slug, &r.CreatedAt, &r.UpdatedAt)
	if err != nil {
		return nil, err
	}
	return &r, nil
}

func (s *Store) ListPhasesForRun(runID string) ([]PhaseRecord, error) {
	rows, err := s.db.Query(
		`SELECT id, run_id, repo, name, kind, status, error, duration_ms, payload, created_at FROM phases WHERE run_id = ? ORDER BY created_at ASC`,
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
		if err := rows.Scan(&p.ID, &p.RunID, &p.Repo, &p.Name, &p.Kind, &p.Status, &errStr, &p.DurationMs, &payloadStr, &p.CreatedAt); err != nil {
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
		`SELECT id, run_id, repo, stage, summary, artifacts, data, created_at FROM envelopes WHERE run_id = ? ORDER BY created_at ASC`,
		runID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var list []EnvelopeRecord
	for rows.Next() {
		var e EnvelopeRecord
		var artStr string
		var dataStr string
		if err := rows.Scan(&e.ID, &e.RunID, &e.Repo, &e.Stage, &e.Summary, &artStr, &dataStr, &e.CreatedAt); err != nil {
			return nil, err
		}
		_ = json.Unmarshal([]byte(artStr), &e.Artifacts)
		e.Data = safeRawJSON(dataStr)
		list = append(list, e)
	}
	return list, nil
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
	_, err = s.db.Exec(`DELETE FROM runs WHERE id = ?`, runID)
	return err
}

func (s *Store) CreateIntent(i *IntentRecord) error {
	now := time.Now().UTC()
	i.CreatedAt = now
	i.UpdatedAt = now
	_, err := s.db.Exec(
		`INSERT INTO intents (id, project, statement, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)`,
		i.ID, i.Project, i.Statement, i.Status, i.CreatedAt, i.UpdatedAt,
	)
	return err
}

func (s *Store) GetIntent(intentID string) (*IntentRecord, error) {
	row := s.db.QueryRow(
		`SELECT id, project, COALESCE(statement, ''), status, created_at, updated_at FROM intents WHERE id = ?`,
		intentID,
	)
	var i IntentRecord
	if err := row.Scan(&i.ID, &i.Project, &i.Statement, &i.Status, &i.CreatedAt, &i.UpdatedAt); err != nil {
		return nil, err
	}
	return &i, nil
}

func (s *Store) ListIntentsForProject(project string) ([]IntentRecord, error) {
	rows, err := s.db.Query(
		`SELECT id, project, COALESCE(statement, ''), status, created_at, updated_at FROM intents WHERE project = ? ORDER BY created_at DESC, id ASC`,
		project,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var list []IntentRecord
	for rows.Next() {
		var i IntentRecord
		if err := rows.Scan(&i.ID, &i.Project, &i.Statement, &i.Status, &i.CreatedAt, &i.UpdatedAt); err != nil {
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
	return requireOneRow(res, "intent", intentID)
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
	return err
}

// ListBulletsForIntent returns an intent's bullets in merge order.
func (s *Store) ListBulletsForIntent(intentID string) ([]BulletRecord, error) {
	rows, err := s.db.Query(
		`SELECT id, intent_id, repo, position, status,
		        COALESCE(branch, ''), COALESCE(worktree, ''), COALESCE(commit_sha, ''), COALESCE(pr_url, ''),
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
	return requireOneRow(res, "bullet", bulletID)
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
		`SELECT id, project, task_id, status, COALESCE(brief, ''), COALESCE(change_id, ''), COALESCE(slug, ''), created_at, updated_at FROM runs WHERE project = ? ORDER BY created_at DESC LIMIT ?`,
		project, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var list []RunRecord
	for rows.Next() {
		var r RunRecord
		if err := rows.Scan(&r.ID, &r.Project, &r.TaskID, &r.Status, &r.Brief, &r.ChangeID, &r.Slug, &r.CreatedAt, &r.UpdatedAt); err != nil {
			return nil, err
		}
		list = append(list, r)
	}
	return list, nil
}
