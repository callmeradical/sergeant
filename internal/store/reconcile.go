package store

// ReconcileResult reports what ReconcileOrphanedRuns changed.
//
// It is a value type rather than a pair of ints so callers can check individual
// fields without coupling to the order of return values, and so the struct can
// gain new fields (e.g. a list of run IDs) without changing every call site.
type ReconcileResult struct {
	// RunsReconciled is the number of runs moved from running to interrupted.
	RunsReconciled int
	// PhasesReconciled is the number of phases moved from running to interrupted
	// across all reconciled runs.
	PhasesReconciled int
}

// ReconcileOrphanedRuns moves every run currently marked running to interrupted
// and reconciles their running phases in the same call.
//
// A freshly started coordinator is driving no runs. Its in-flight registry is
// empty by construction, so any run the store reports as running is, from this
// process's view, unowned. That is the whole inference, and it is sound precisely
// because it is made at startup and nowhere else.
//
// Rules:
//   - Only running runs are touched; all terminal statuses (passed, failed,
//     cancelled, timed_out, interrupted) are left exactly as they are.
//   - For each reconciled run, every phase whose status is running is moved to
//     interrupted. Phases in any other status are untouched.
//   - A change-sequence entry is appended for each run and each phase that
//     transitions, so an operator can see what was recovered.
//   - When nothing is reconciled, no change is appended and no log line is
//     written; a permanent "0 runs recovered" line at every start trains
//     operators to ignore the log.
//
// Reconciliation MUST NOT be called mid-life. Applied to a running coordinator
// it would reconcile a live run out from under itself. The server's Start method
// calls this once, before the listener accepts connections, and nowhere else.
func (s *Store) ReconcileOrphanedRuns() (ReconcileResult, error) {
	// Load every run that is still marked running. The query is deliberately
	// narrow: terminal statuses are not read, so no terminal run can be
	// accidentally touched even if the caller ignores the result.
	rows, err := s.db.Query(
		`SELECT `+runColumns+` FROM runs WHERE status = 'running' ORDER BY created_at ASC`,
	)
	if err != nil {
		return ReconcileResult{}, err
	}
	var orphans []RunRecord
	for rows.Next() {
		r, err := scanRun(rows)
		if err != nil {
			rows.Close()
			return ReconcileResult{}, err
		}
		orphans = append(orphans, r)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return ReconcileResult{}, err
	}

	if len(orphans) == 0 {
		// Nothing to do. Return immediately without touching the change sequence.
		return ReconcileResult{}, nil
	}

	var result ReconcileResult

	for _, run := range orphans {
		// Move the run itself.
		if err := s.reconcileRun(run.ID); err != nil {
			return result, err
		}
		result.RunsReconciled++

		// Move every running phase that belongs to this run.
		n, err := s.reconcileRunningPhasesOfRun(run.ID)
		if err != nil {
			return result, err
		}
		result.PhasesReconciled += n
	}

	return result, nil
}

// reconcileRun moves one run from running to interrupted and appends a change.
func (s *Store) reconcileRun(runID string) error {
	_, err := s.db.Exec(
		`UPDATE runs SET status = 'interrupted', updated_at = datetime('now') WHERE id = ? AND status = 'running'`,
		runID,
	)
	if err != nil {
		return err
	}
	// Record: nothing judged this run. The coordinator stopped; record the
	// interruption, not a verdict. "reconciled" in the payload tells an operator
	// reading the change log what caused the transition.
	return s.recordTransition(ChannelRun, runID, map[string]interface{}{
		"transition": "status",
		"id":         runID,
		"status":     "interrupted",
		"terminal":   true,
		"reconciled": true,
	})
}

// reconcileRunningPhasesOfRun moves every running phase of runID to interrupted,
// appends a change for each, and returns how many it moved.
//
// A phase stuck at running is neither passed nor re-run on resume — resume skips
// only phases holding a passed record. Leaving it would silently drop work.
func (s *Store) reconcileRunningPhasesOfRun(runID string) (int, error) {
	// Read the running phases before updating, so we can append individual
	// change records with their IDs. A bulk UPDATE with no read-back would
	// prevent per-phase change records, and a client following the sequence
	// would not know which phase moved.
	phRows, err := s.db.Query(
		`SELECT id FROM phases WHERE run_id = ? AND status = 'running' ORDER BY created_at ASC`,
		runID,
	)
	if err != nil {
		return 0, err
	}
	var phaseIDs []string
	for phRows.Next() {
		var id string
		if err := phRows.Scan(&id); err != nil {
			phRows.Close()
			return 0, err
		}
		phaseIDs = append(phaseIDs, id)
	}
	phRows.Close()
	if err := phRows.Err(); err != nil {
		return 0, err
	}

	for _, phaseID := range phaseIDs {
		if _, err := s.db.Exec(
			`UPDATE phases SET status = 'interrupted' WHERE id = ? AND status = 'running'`,
			phaseID,
		); err != nil {
			return len(phaseIDs), err
		}
		if err := s.recordTransition(ChannelPhase, phaseID, map[string]interface{}{
			"id":         phaseID,
			"run_id":     runID,
			"status":     "interrupted",
			"reconciled": true,
		}); err != nil {
			return len(phaseIDs), err
		}
	}

	return len(phaseIDs), nil
}
