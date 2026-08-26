package store

import (
	"database/sql"
	"time"
)

// createArtifactsTable is the DDL for the artifacts table, following the same
// const + migrateAddTables pattern as createDeliveriesTable: the DDL is a
// named const so the initial schema and the migration path for an
// already-existing database share exactly one definition.
//
// dropped_count/dropped_reason default to 0/'' for every row that represents
// a real captured file. They are non-zero only on the one synthetic row
// captureArtifacts writes per phase to report artifacts it could not keep
// (over the count/byte cap, or a copy failure) — see internal/runner's
// captureArtifacts. That row carries no filename/content_type/path of its
// own; it exists purely so a drop is never silent.
const createArtifactsTable = `
	CREATE TABLE IF NOT EXISTS artifacts (
		id             TEXT PRIMARY KEY,
		run_id         TEXT NOT NULL,
		phase_id       TEXT NOT NULL,
		repo           TEXT NOT NULL,
		filename       TEXT NOT NULL DEFAULT '',
		content_type   TEXT NOT NULL DEFAULT '',
		size_bytes     INTEGER NOT NULL DEFAULT 0,
		path           TEXT NOT NULL DEFAULT '',
		captured_at    DATETIME NOT NULL,
		dropped_count  INTEGER NOT NULL DEFAULT 0,
		dropped_reason TEXT NOT NULL DEFAULT ''
	);`

// ArtifactRecord is one captured file (or one drop notice) produced by a
// gate/agent phase's command writing into $SERGEANT_ARTIFACT_DIR. Path is a
// filesystem path outside the run's worktree, durable across that worktree's
// later reclaim by automated-fleet-cleanup — see internal/runner's
// captureArtifacts, the only writer of this table.
type ArtifactRecord struct {
	ID            string    `json:"id"`
	RunID         string    `json:"run_id"`
	PhaseID       string    `json:"phase_id"`
	Repo          string    `json:"repo"`
	Filename      string    `json:"filename"`
	ContentType   string    `json:"content_type"`
	SizeBytes     int64     `json:"size_bytes"`
	Path          string    `json:"path"`
	CapturedAt    time.Time `json:"captured_at"`
	DroppedCount  int       `json:"dropped_count,omitempty"`
	DroppedReason string    `json:"dropped_reason,omitempty"`
}

// RecordArtifact writes one artifacts row. Every capture (or drop notice) is
// its own INSERT — there is no update path, matching the append-only shape
// PhaseRecord and DeliveryRecord already use for evidence rows.
func (s *Store) RecordArtifact(a *ArtifactRecord) error {
	_, err := s.db.Exec(
		`INSERT INTO artifacts
		 (id, run_id, phase_id, repo, filename, content_type, size_bytes, path, captured_at, dropped_count, dropped_reason)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		a.ID, a.RunID, a.PhaseID, a.Repo, a.Filename, a.ContentType, a.SizeBytes, a.Path, a.CapturedAt, a.DroppedCount, a.DroppedReason,
	)
	return err
}

// scanArtifactRow reads one artifacts row from r, sharing one implementation
// between ListArtifactsForRun and GetArtifact the same way scanDeliveryRow
// does for deliveries.
func scanArtifactRow(r rowScanner) (ArtifactRecord, error) {
	var rec ArtifactRecord
	var capturedStr string
	if err := r.Scan(
		&rec.ID, &rec.RunID, &rec.PhaseID, &rec.Repo,
		&rec.Filename, &rec.ContentType, &rec.SizeBytes, &rec.Path,
		&capturedStr, &rec.DroppedCount, &rec.DroppedReason,
	); err != nil {
		return ArtifactRecord{}, err
	}
	rec.CapturedAt = parseSQLiteTime(capturedStr)
	return rec, nil
}

// ListArtifactsForRun returns every artifact (and drop notice) captured
// during runID, ordered by captured_at then id ascending. It returns an
// empty, non-nil slice for a run with none, so a JSON caller serialises []
// rather than null.
func (s *Store) ListArtifactsForRun(runID string) ([]*ArtifactRecord, error) {
	rows, err := s.db.Query(
		`SELECT id, run_id, phase_id, repo, filename, content_type, size_bytes, path, captured_at, dropped_count, dropped_reason
		 FROM artifacts WHERE run_id = ? ORDER BY captured_at ASC, id ASC`,
		runID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	list := []*ArtifactRecord{}
	for rows.Next() {
		r, err := scanArtifactRow(rows)
		if err != nil {
			return nil, err
		}
		list = append(list, &r)
	}
	return list, rows.Err()
}

// GetArtifact looks up one artifact by id. The bool return distinguishes "no
// such artifact" from a real query error, so a caller like
// handleArtifactContent can answer 404 for the former without misreporting
// the latter as one.
func (s *Store) GetArtifact(id string) (*ArtifactRecord, bool, error) {
	r, err := scanArtifactRow(s.db.QueryRow(
		`SELECT id, run_id, phase_id, repo, filename, content_type, size_bytes, path, captured_at, dropped_count, dropped_reason
		 FROM artifacts WHERE id = ?`, id,
	))
	if err == sql.ErrNoRows {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	return &r, true, nil
}
