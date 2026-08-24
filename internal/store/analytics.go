package store

import "encoding/json"

// AllRunsForAnalytics returns every run for project, or every run across
// every project when project is "" or "all". Unlike ListRecentRuns and
// ListRunsForProject, which cap their result to answer "what's active or
// recent", this exists to answer "how much has shipped, ever" — the same
// distinction RunsEligibleForCleanup draws for fleet cleanup. Ordered by
// created_at so output is deterministic.
func (s *Store) AllRunsForAnalytics(project string) ([]RunRecord, error) {
	query := `SELECT ` + runColumns + ` FROM runs`
	var args []interface{}
	if project != "" && project != "all" {
		query += ` WHERE project = ?`
		args = append(args, project)
	}
	query += ` ORDER BY created_at ASC`

	rows, err := s.db.Query(query, args...)
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

// AllBulletsForAnalytics returns every bullet whose intent belongs to
// project (every bullet, across every project, when project is "" or
// "all"). Bullets carry no project column of their own — only their intent
// does — so this joins through intents, the same relationship
// ListBulletsForIntent's callers already navigate via GetRun/GetIntent.
func (s *Store) AllBulletsForAnalytics(project string) ([]BulletRecord, error) {
	query := `SELECT b.id, b.intent_id, b.repo, b.position, b.status,
		COALESCE(b.branch,''), COALESCE(b.worktree,''), COALESCE(b.commit_sha,''),
		COALESCE(b.pr_url,''), COALESCE(b.blocked_reason,''), b.created_at, b.updated_at
		FROM bullets b JOIN intents i ON b.intent_id = i.id`
	var args []interface{}
	if project != "" && project != "all" {
		query += ` WHERE i.project = ?`
		args = append(args, project)
	}

	rows, err := s.db.Query(query, args...)
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

// WorkAnalytics is a point-in-time aggregate of all recorded work for a
// project (or every project). It is a pure read derived entirely from
// RunRecord, PhaseRecord payloads, and BulletRecord — nothing here is
// written or touched.
type WorkAnalytics struct {
	Project string `json:"project"`

	TotalRuns int            `json:"total_runs"`
	ByStatus  map[string]int `json:"by_status"`
	// ByType keys on RunRecord.Type; "" is the bucket for runs recorded
	// before decision O2 introduced work types.
	ByType map[string]int `json:"by_type"`
	// ByAgent, ByModel, and ByProvider key on the values
	// annotatePayloadWithProvenance (internal/runner/runner.go) writes into
	// a phase payload. "" is the unknown bucket for a run with no phase
	// carrying that information — the common case for every agent besides
	// goose today (R4.6). Every run lands in exactly one bucket of each map,
	// so each map's values sum to TotalRuns.
	ByAgent    map[string]int `json:"by_agent"`
	ByModel    map[string]int `json:"by_model"`
	ByProvider map[string]int `json:"by_provider"`

	BulletsTotal  int `json:"bullets_total"`
	BulletsMerged int `json:"bullets_merged"`
}

// runProvenance is the shape of the fields annotatePayloadWithProvenance
// adds to a phase payload. Unexported: this is a decoding helper local to
// the aggregation below, not a type other packages construct.
type runProvenance struct {
	Agent    string `json:"agent"`
	Model    string `json:"model"`
	Provider string `json:"provider"`
}

// provenanceForRun returns the agent/model/provider recorded on the first
// phase (in created_at order, as ListPhasesForRun already returns them)
// whose payload carries a non-empty "agent" field. A run with no such phase
// returns the zero value, which the caller counts under the "" bucket in
// each of ByAgent/ByModel/ByProvider.
func provenanceForRun(s *Store, runID string) (runProvenance, error) {
	phases, err := s.ListPhasesForRun(runID)
	if err != nil {
		return runProvenance{}, err
	}
	for _, p := range phases {
		if len(p.Payload) == 0 {
			continue
		}
		var prov runProvenance
		if err := json.Unmarshal(p.Payload, &prov); err != nil {
			continue
		}
		if prov.Agent != "" {
			return prov, nil
		}
	}
	return runProvenance{}, nil
}

// ComputeWorkAnalytics aggregates recorded history for project ("" or "all"
// for every project) into a WorkAnalytics. It is a pure read: no row is
// written or touched.
func (s *Store) ComputeWorkAnalytics(project string) (WorkAnalytics, error) {
	runs, err := s.AllRunsForAnalytics(project)
	if err != nil {
		return WorkAnalytics{}, err
	}

	wa := WorkAnalytics{
		Project:    project,
		ByStatus:   map[string]int{},
		ByType:     map[string]int{},
		ByAgent:    map[string]int{},
		ByModel:    map[string]int{},
		ByProvider: map[string]int{},
	}

	for _, r := range runs {
		wa.TotalRuns++
		wa.ByStatus[r.Status]++
		wa.ByType[r.Type]++

		prov, err := provenanceForRun(s, r.ID)
		if err != nil {
			return WorkAnalytics{}, err
		}
		wa.ByAgent[prov.Agent]++
		wa.ByModel[prov.Model]++
		wa.ByProvider[prov.Provider]++
	}

	bullets, err := s.AllBulletsForAnalytics(project)
	if err != nil {
		return WorkAnalytics{}, err
	}
	wa.BulletsTotal = len(bullets)
	for _, b := range bullets {
		if b.Status == "merged" {
			wa.BulletsMerged++
		}
	}

	return wa, nil
}
