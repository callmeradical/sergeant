package store

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite"
)

type Store struct {
	db *sql.DB
}

type RunRecord struct {
	ID        string    `json:"id"`
	Project   string    `json:"project"`
	TaskID    string    `json:"task_id"`
	Brief     string    `json:"brief"`
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

func (s *Store) migrate() error {
	schema := `
	CREATE TABLE IF NOT EXISTS runs (
		id TEXT PRIMARY KEY,
		project TEXT NOT NULL,
		task_id TEXT NOT NULL,
		status TEXT NOT NULL,
		brief TEXT NOT NULL DEFAULT '',
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
	`
	if _, err := s.db.Exec(schema); err != nil {
		return err
	}
	return s.migrateAddColumns()
}

// migrateAddColumns brings pre-existing databases up to the current schema.
// CREATE TABLE IF NOT EXISTS is a no-op on an existing table, so new columns
// must be added explicitly or every query naming them fails.
func (s *Store) migrateAddColumns() error {
	wanted := []struct{ table, column, ddl string }{
		{"runs", "brief", "ALTER TABLE runs ADD COLUMN brief TEXT NOT NULL DEFAULT ''"},
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

func (s *Store) CreateRun(r *RunRecord) error {
	now := time.Now().UTC()
	r.CreatedAt = now
	r.UpdatedAt = now
	_, err := s.db.Exec(
		`INSERT INTO runs (id, project, task_id, status, brief, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)`,
		r.ID, r.Project, r.TaskID, r.Status, r.Brief, r.CreatedAt, r.UpdatedAt,
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
		`SELECT id, project, task_id, status, COALESCE(brief, ''), created_at, updated_at FROM runs ORDER BY created_at DESC LIMIT ?`,
		limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var list []RunRecord
	for rows.Next() {
		var r RunRecord
		if err := rows.Scan(&r.ID, &r.Project, &r.TaskID, &r.Status, &r.Brief, &r.CreatedAt, &r.UpdatedAt); err != nil {
			return nil, err
		}
		list = append(list, r)
	}
	return list, nil
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

func (s *Store) ListRunsForProject(project string, limit int) ([]RunRecord, error) {
	rows, err := s.db.Query(
		`SELECT id, project, task_id, status, COALESCE(brief, ''), created_at, updated_at FROM runs WHERE project = ? ORDER BY created_at DESC LIMIT ?`,
		project, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var list []RunRecord
	for rows.Next() {
		var r RunRecord
		if err := rows.Scan(&r.ID, &r.Project, &r.TaskID, &r.Status, &r.Brief, &r.CreatedAt, &r.UpdatedAt); err != nil {
			return nil, err
		}
		list = append(list, r)
	}
	return list, nil
}
