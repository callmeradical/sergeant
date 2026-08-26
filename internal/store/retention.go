package store

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"time"
)

// createRetentionRollupsTable is the DDL for the retention_rollups table,
// following the same const + migrateAddTables pattern as createDeliveriesTable
// and createArtifactsTable: one definition shared by the initial schema and
// the migration path for an already-existing database.
//
// One row per project — a running total "as of computed_through" that each
// rotation pass updates in place (INSERT ... ON CONFLICT DO UPDATE), not an
// appended history of rollups (design.md's rejected alternative: an unbounded
// rollup history just moves the unbounded-growth problem this change exists
// to solve).
const createRetentionRollupsTable = `
	CREATE TABLE IF NOT EXISTS retention_rollups (
	  project              TEXT PRIMARY KEY,
	  computed_through     DATETIME NOT NULL,
	  run_count            INTEGER NOT NULL DEFAULT 0,
	  passed_count         INTEGER NOT NULL DEFAULT 0,
	  failed_count         INTEGER NOT NULL DEFAULT 0,
	  bullet_total         INTEGER NOT NULL DEFAULT 0,
	  bullet_merged        INTEGER NOT NULL DEFAULT 0,
	  by_work_type_json    TEXT NOT NULL DEFAULT '{}',
	  by_provenance_json   TEXT NOT NULL DEFAULT '{}'
	);`

// RetentionRollup is one project's running total of everything rotation has
// folded away so far. ComputeWorkAnalytics adds it into its raw-row counts so
// an operator's historical totals stay accurate after the detailed rows are
// gone.
type RetentionRollup struct {
	Project         string
	ComputedThrough time.Time
	RunCount        int
	PassedCount     int
	FailedCount     int
	// BulletTotal/BulletMerged record the bullet counts of rotated runs'
	// intents at the moment each run rotated. Rotation never deletes bullets
	// or intents (a bullet is shared by its intent across every run that ever
	// served it), so these are kept for the record but are deliberately NOT
	// folded into ComputeWorkAnalytics' bullet totals — AllBulletsForAnalytics
	// already counts every live bullet directly, and adding these on top
	// would double-count.
	BulletTotal  int
	BulletMerged int
	// ByWorkType mirrors WorkAnalytics.ByType's breakdown shape.
	ByWorkType map[string]int
	// ByAgent, ByModel, ByProvider mirror WorkAnalytics' breakdowns of the
	// same name, folded from provenanceForRun at rotation time (before that
	// run's phases, which carry the provenance, are deleted).
	ByAgent    map[string]int
	ByModel    map[string]int
	ByProvider map[string]int
}

// retentionProvenanceJSON is the shape by_provenance_json is marshaled as —
// unexported, an internal encoding detail of this file only.
type retentionProvenanceJSON struct {
	ByAgent    map[string]int `json:"by_agent"`
	ByModel    map[string]int `json:"by_model"`
	ByProvider map[string]int `json:"by_provider"`
}

// GetRetentionRollup loads project's rollup row. The bool return distinguishes
// "no rollup yet" from a real zero-valued rollup — a project that has never
// had anything rotated has no row at all, not a row full of zeros that would
// be indistinguishable from a project whose rotated history was genuinely
// empty.
func (s *Store) GetRetentionRollup(project string) (*RetentionRollup, bool, error) {
	var rec RetentionRollup
	var computedStr, workTypeJSON, provenanceJSON string
	err := s.db.QueryRow(
		`SELECT project, computed_through, run_count, passed_count, failed_count,
		        bullet_total, bullet_merged, by_work_type_json, by_provenance_json
		 FROM retention_rollups WHERE project = ?`,
		project,
	).Scan(
		&rec.Project, &computedStr, &rec.RunCount, &rec.PassedCount, &rec.FailedCount,
		&rec.BulletTotal, &rec.BulletMerged, &workTypeJSON, &provenanceJSON,
	)
	if err == sql.ErrNoRows {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	rec.ComputedThrough = parseSQLiteTime(computedStr)

	rec.ByWorkType = map[string]int{}
	if err := json.Unmarshal([]byte(workTypeJSON), &rec.ByWorkType); err != nil {
		return nil, false, fmt.Errorf("decoding retention rollup for project %q: %w", project, err)
	}
	var prov retentionProvenanceJSON
	if err := json.Unmarshal([]byte(provenanceJSON), &prov); err != nil {
		return nil, false, fmt.Errorf("decoding retention rollup for project %q: %w", project, err)
	}
	rec.ByAgent = nonNilCounts(prov.ByAgent)
	rec.ByModel = nonNilCounts(prov.ByModel)
	rec.ByProvider = nonNilCounts(prov.ByProvider)

	return &rec, true, nil
}

// nonNilCounts returns m, or a fresh empty map when m is nil — so a caller
// can always range over the result without a nil check.
func nonNilCounts(m map[string]int) map[string]int {
	if m == nil {
		return map[string]int{}
	}
	return m
}

// upsertRetentionRollup writes r's current totals, creating the row on a
// project's first rotation pass and updating it in place on every pass after.
func (s *Store) upsertRetentionRollup(r *RetentionRollup) error {
	workTypeJSON, err := json.Marshal(nonNilCounts(r.ByWorkType))
	if err != nil {
		return err
	}
	provJSON, err := json.Marshal(retentionProvenanceJSON{
		ByAgent:    nonNilCounts(r.ByAgent),
		ByModel:    nonNilCounts(r.ByModel),
		ByProvider: nonNilCounts(r.ByProvider),
	})
	if err != nil {
		return err
	}
	_, err = s.db.Exec(
		`INSERT INTO retention_rollups
		   (project, computed_through, run_count, passed_count, failed_count,
		    bullet_total, bullet_merged, by_work_type_json, by_provenance_json)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
		 ON CONFLICT(project) DO UPDATE SET
		   computed_through   = excluded.computed_through,
		   run_count          = excluded.run_count,
		   passed_count       = excluded.passed_count,
		   failed_count       = excluded.failed_count,
		   bullet_total       = excluded.bullet_total,
		   bullet_merged      = excluded.bullet_merged,
		   by_work_type_json  = excluded.by_work_type_json,
		   by_provenance_json = excluded.by_provenance_json`,
		r.Project, r.ComputedThrough, r.RunCount, r.PassedCount, r.FailedCount,
		r.BulletTotal, r.BulletMerged, string(workTypeJSON), string(provJSON),
	)
	return err
}

// retentionRollupsFor returns the rollups ComputeWorkAnalytics should fold
// into its totals for project: project's single rollup for a named project,
// or every project's rollup summed in when project is "" or "all" — the same
// scoping convention AllRunsForAnalytics already draws.
func (s *Store) retentionRollupsFor(project string) ([]RetentionRollup, error) {
	if project != "" && project != "all" {
		r, found, err := s.GetRetentionRollup(project)
		if err != nil {
			return nil, err
		}
		if !found {
			return nil, nil
		}
		return []RetentionRollup{*r}, nil
	}

	rows, err := s.db.Query(`SELECT project FROM retention_rollups ORDER BY project ASC`)
	if err != nil {
		return nil, err
	}
	var projects []string
	for rows.Next() {
		var p string
		if err := rows.Scan(&p); err != nil {
			rows.Close()
			return nil, err
		}
		projects = append(projects, p)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, err
	}
	rows.Close()

	var all []RetentionRollup
	for _, p := range projects {
		r, found, err := s.GetRetentionRollup(p)
		if err != nil {
			return nil, err
		}
		if found {
			all = append(all, *r)
		}
	}
	return all, nil
}

// intentFullyMerged reports whether every bullet of intentID has reached
// merged. A run with no intent (intentID == "") has nothing to check and is
// reported eligible — RunRecord.IntentID's own documented "no intent was
// recorded" reading. Unlike DeriveIntentStatus, an intent with zero bullets
// answers true here: RotateProject's eligibility rule is "every bullet, if
// any, at merged" (design.md), a different question than DeriveIntentStatus's
// "has this intent's work been satisfied."
func (s *Store) intentFullyMerged(intentID string) (bool, error) {
	if intentID == "" {
		return true, nil
	}
	bullets, err := s.ListBulletsForIntent(intentID)
	if err != nil {
		return false, err
	}
	for _, b := range bullets {
		if b.Status != "merged" {
			return false, nil
		}
	}
	return true, nil
}

// RotateProject folds every eligible run for project into its rollup row,
// then deletes those runs' deliveries, envelopes, phases, and the run rows
// themselves. Returns how many runs were rotated.
//
// A run is eligible when: its status is terminal (rotationEligibleStatusesSQL,
// the same list RunsEligibleForCleanup uses), it was created before cutoff,
// and — if it names an intent — every one of that intent's bullets has
// reached merged. A run that is not yet terminal, or whose intent has an
// unmerged bullet, is left untouched, mirroring R6.5's "cleanup refuses to
// remove active or diagnostically incomplete" evidence, extended from
// worktrees to rows.
//
// Bullets and intents are never deleted here: a bullet is shared by its
// intent across every run that ever served it, so deleting one on this run's
// say-so could hide evidence a sibling run still needs.
func (s *Store) RotateProject(project string, cutoff time.Time) (int, error) {
	rows, err := s.db.Query(
		`SELECT `+runColumns+` FROM runs
		 WHERE project = ? AND status IN (`+rotationEligibleStatusesSQL+`)
		   AND created_at < ?
		 ORDER BY created_at ASC`,
		project, cutoff,
	)
	if err != nil {
		return 0, err
	}
	var candidates []RunRecord
	for rows.Next() {
		r, err := scanRun(rows)
		if err != nil {
			rows.Close()
			return 0, err
		}
		candidates = append(candidates, r)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return 0, err
	}
	rows.Close()

	rotated := 0
	for _, r := range candidates {
		eligible, err := s.intentFullyMerged(r.IntentID)
		if err != nil {
			return rotated, fmt.Errorf("checking intent eligibility for run %q: %w", r.ID, err)
		}
		if !eligible {
			continue
		}
		if err := s.rotateOneRun(project, r); err != nil {
			return rotated, fmt.Errorf("rotating run %q: %w", r.ID, err)
		}
		rotated++
	}
	return rotated, nil
}

// rotateOneRun folds run's contribution into project's rollup, then deletes
// its deliveries, envelopes, phases, and its own row — children before the
// parent they reference.
func (s *Store) rotateOneRun(project string, run RunRecord) error {
	prov, err := provenanceForRun(s, run.ID)
	if err != nil {
		return err
	}
	if err := s.foldRunIntoRollup(project, run, prov); err != nil {
		return err
	}

	if _, err := s.db.Exec(
		`DELETE FROM deliveries WHERE envelope_id IN (SELECT id FROM envelopes WHERE run_id = ?)`,
		run.ID,
	); err != nil {
		return err
	}
	if _, err := s.db.Exec(`DELETE FROM envelopes WHERE run_id = ?`, run.ID); err != nil {
		return err
	}
	if _, err := s.db.Exec(`DELETE FROM phases WHERE run_id = ?`, run.ID); err != nil {
		return err
	}
	if _, err := s.db.Exec(`DELETE FROM runs WHERE id = ?`, run.ID); err != nil {
		return err
	}
	return nil
}

// foldRunIntoRollup adds run's contribution to project's rollup row —
// "parse, add counts, re-marshal" (design.md), not a new aggregation shape.
func (s *Store) foldRunIntoRollup(project string, run RunRecord, prov runProvenance) error {
	current, found, err := s.GetRetentionRollup(project)
	if err != nil {
		return err
	}
	if !found {
		current = &RetentionRollup{
			Project:    project,
			ByWorkType: map[string]int{},
			ByAgent:    map[string]int{},
			ByModel:    map[string]int{},
			ByProvider: map[string]int{},
		}
	}

	current.RunCount++
	switch run.Status {
	case "passed":
		current.PassedCount++
	case "failed":
		current.FailedCount++
	}
	current.ByWorkType[run.Type]++
	current.ByAgent[prov.Agent]++
	current.ByModel[prov.Model]++
	current.ByProvider[prov.Provider]++
	current.ComputedThrough = time.Now().UTC()

	if run.IntentID != "" {
		bullets, err := s.ListBulletsForIntent(run.IntentID)
		if err != nil {
			return err
		}
		current.BulletTotal += len(bullets)
		for _, b := range bullets {
			if b.Status == "merged" {
				current.BulletMerged++
			}
		}
	}

	return s.upsertRetentionRollup(current)
}

// RotateArtifacts deletes artifact rows (and their durable files) whose
// captured_at is before cutoff, independent of whether their parent run has
// itself rotated — artifacts have their own, typically shorter, horizon
// (proposal.md). Returns how many artifacts were rotated.
//
// Guarded by hasTable("artifacts"), the same check migrateAddTables already
// uses: a database that predates pipeline-artifacts has no artifacts table
// yet, and this is then a no-op rather than a query error.
func (s *Store) RotateArtifacts(cutoff time.Time) (int, error) {
	has, err := s.hasTable("artifacts")
	if err != nil {
		return 0, err
	}
	if !has {
		return 0, nil
	}

	rows, err := s.db.Query(`SELECT id, path FROM artifacts WHERE captured_at < ?`, cutoff)
	if err != nil {
		return 0, err
	}
	type candidate struct{ id, path string }
	var list []candidate
	for rows.Next() {
		var c candidate
		if err := rows.Scan(&c.id, &c.path); err != nil {
			rows.Close()
			return 0, err
		}
		list = append(list, c)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return 0, err
	}
	rows.Close()

	rotated := 0
	for _, c := range list {
		if c.path != "" {
			if err := os.Remove(c.path); err != nil && !os.IsNotExist(err) {
				return rotated, fmt.Errorf("removing artifact file %s: %w", c.path, err)
			}
		}
		if _, err := s.db.Exec(`DELETE FROM artifacts WHERE id = ?`, c.id); err != nil {
			return rotated, err
		}
		rotated++
	}
	return rotated, nil
}
