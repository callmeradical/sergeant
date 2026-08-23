package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io/fs"
	"time"
)

// createDeliveriesTable is the DDL for the deliveries table.
//
// It follows the same const + migrateAddTables PRAGMA-guarded pattern as
// createIntentsTable, createBulletsTable, and createChangesTable: the DDL is
// expressed as a named const so the same SQL is used by the initial schema and
// by the migration path that brings an older database up to the current set of
// tables.
//
// Design decisions captured here:
//
//   - Every state transition is an INSERT, never an UPDATE. The rows are the
//     delivery history (R5.3 append-only requirement), so a delivery that took
//     three tries retains its pending and retrying rows alongside the delivered
//     one. The current state is the row with the latest created_at.
//
//   - idempotency_key is UNIQUE. A delivery for an (envelope_id, consumer) pair
//     that already reached a terminal success state is refused at the INSERT
//     level — the check-then-insert path would allow a race; the unique index
//     does not.
//
//   - consumer is TEXT, not an enum. New consumer kinds (new call sites) must
//     not require a schema change.
//
//   - next_attempt_at and error are nullable so they do not carry a misleading
//     non-empty value for terminal rows.
const createDeliveriesTable = `
	CREATE TABLE IF NOT EXISTS deliveries (
		id TEXT NOT NULL,
		envelope_id TEXT NOT NULL REFERENCES envelopes(id),
		consumer TEXT NOT NULL,
		state TEXT NOT NULL,
		attempt INTEGER NOT NULL DEFAULT 1,
		next_attempt_at DATETIME,
		error TEXT NOT NULL DEFAULT '',
		error_class TEXT NOT NULL DEFAULT '',
		idempotency_key TEXT NOT NULL,
		created_at DATETIME NOT NULL,
		updated_at DATETIME NOT NULL
	);
	CREATE UNIQUE INDEX IF NOT EXISTS idx_deliveries_idempotency_key_terminal
		ON deliveries (idempotency_key)
		WHERE state IN ('delivered', 'acknowledged');`

// DeliveryRecord is one row in the deliveries table.
//
// Because every state transition is an INSERT (not an UPDATE), one delivery
// chain — say pending → retrying → delivered — consists of three rows that all
// share the same idempotency_key. ListDeliveryHistory returns them in created_at
// order so callers can read the full history.
type DeliveryRecord struct {
	ID                   string    `json:"id"`
	EnvelopeID           string    `json:"envelope_id"`
	Consumer             string    `json:"consumer"`
	State                string    `json:"state"`
	Attempt              int       `json:"attempt"`
	NextAttemptAt        time.Time `json:"next_attempt_at,omitempty"`
	Error                string    `json:"error,omitempty"`
	ErrorClass           string    `json:"error_class,omitempty"`
	RecoveryInstructions string    `json:"recovery_instructions,omitempty"`
	IdempotencyKey       string    `json:"idempotency_key"`
	CreatedAt            time.Time `json:"created_at"`
	UpdatedAt            time.Time `json:"updated_at"`
}

// deliveryMaxAttempts is the fixed retry ceiling for DeliverEnvelope.
//
// Three total attempts. This is an independent constant, not a reuse of
// config.Project's R2.4 retry resolution: that value is per-project and
// YAML-configurable, and this delivery path never calls into config. A
// project that configures its R2.4 retries to something other than 2 now has
// two retry ceilings that can diverge; that is an accepted tradeoff for now
// because unifying them would make the store package depend on config for a
// single integer, not because the two are actually the same mechanism.
const deliveryMaxAttempts = 3

// Delivery error classes. A delivery failure is classified from the Go error
// value returned by the wrapped attempt so an operator reading delivery
// history can distinguish failure kinds without parsing free-text messages
// (R5.4: "error classification"). Both current call sites (SaveEnvelope,
// InjectHandoffToWorktree) fail only via filesystem operations or context
// cancellation, so the taxonomy is deliberately small; it grows as new
// failure kinds are actually observed rather than being guessed in advance.
const (
	errorClassFilesystem  = "filesystem"
	errorClassCancelled   = "cancelled"
	errorClassUnknown     = "unknown"
	errorClassQuarantined = "quarantined"
)

// classifyDeliveryError derives an error class from err. It returns "" for a
// nil error (no failure to classify).
func classifyDeliveryError(err error) string {
	if err == nil {
		return ""
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return errorClassCancelled
	}
	var pathErr *fs.PathError
	if errors.As(err, &pathErr) || errors.Is(err, fs.ErrNotExist) || errors.Is(err, fs.ErrPermission) {
		return errorClassFilesystem
	}
	return errorClassUnknown
}

// deliveryStates is the full set of valid delivery state values, matching R5.4.
const (
	deliveryStatePending      = "pending"
	deliveryStateRetrying     = "retrying"
	deliveryStateDelivered    = "delivered"
	deliveryStateFailed       = "failed"
	deliveryStateLeased       = "leased"
	deliveryStateAcknowledged = "acknowledged"
	deliveryStateDeadLetter   = "dead_letter"
	deliveryStateQuarantined  = "quarantined"
)

// deliveryID generates a store record ID for a delivery row using the same
// <scope>-<unix-nano> convention as other records in this store.
func deliveryID(envelopeID string) string {
	return fmt.Sprintf("del-%s-%d", envelopeID, time.Now().UnixNano())
}

// insertDeliveryRow writes one row to the deliveries table. It is the only
// writer; no code in this package issues an UPDATE on deliveries.
//
// nextAttemptAt is the zero time for a row that has no pending future attempt
// (pending's first attempt is immediate; delivered and failed are terminal).
// For a retrying row it is set to the time the retry is scheduled for — "now"
// today, because both current call sites retry immediately in-process with no
// backoff clock (see DeliverEnvelope's doc comment); the column exists so a
// future backoff strategy has somewhere to record a real future time without
// a schema change.
//
// failureErr is the live error value, not its message, so classifyDeliveryError
// can inspect its real type (e.g. *fs.PathError) rather than a string that has
// already lost that information. It is nil for a row that records no failure.
//
// recoveryInstr is the human-readable recovery instructions string; it is
// empty for non-terminal rows and non-empty for dead_letter rows.
func (s *Store) insertDeliveryRow(envelopeID, consumer, state string, attempt int, failureErr error, nextAttemptAt time.Time, recoveryInstr string) error {
	key := deliveryIdempotencyKey(envelopeID, consumer)
	now := time.Now().UTC()
	id := deliveryID(envelopeID)
	var nextAttemptCol interface{}
	if !nextAttemptAt.IsZero() {
		nextAttemptCol = nextAttemptAt
	}
	errMsg := ""
	if failureErr != nil {
		errMsg = failureErr.Error()
	}
	_, err := s.db.Exec(
		`INSERT INTO deliveries
		 (id, envelope_id, consumer, state, attempt, next_attempt_at, error, error_class, recovery_instructions, idempotency_key, created_at, updated_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, envelopeID, consumer, state, attempt, nextAttemptCol, errMsg, classifyDeliveryError(failureErr), recoveryInstr, key, now, now,
	)
	return err
}

// insertDeliveryRowQuarantined writes a quarantined row. Unlike insertDeliveryRow,
// it takes explicit error text and error class (rather than deriving from a Go
// error), because the quarantine reason is operator-supplied text, not a Go error.
func (s *Store) insertDeliveryRowQuarantined(envelopeID, consumer, reason string) error {
	key := deliveryIdempotencyKey(envelopeID, consumer)
	now := time.Now().UTC()
	id := deliveryID(envelopeID)
	_, err := s.db.Exec(
		`INSERT INTO deliveries
		 (id, envelope_id, consumer, state, attempt, next_attempt_at, error, error_class, recovery_instructions, idempotency_key, created_at, updated_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, envelopeID, consumer, deliveryStateQuarantined, 0, nil, reason, errorClassQuarantined, "", key, now, now,
	)
	return err
}

// deliveryIdempotencyKey derives the idempotency key from the pair (envelopeID,
// consumer). It is a pure function, not a caller-supplied string, so it cannot
// drift from the pair it describes.
func deliveryIdempotencyKey(envelopeID, consumer string) string {
	return envelopeID + ":" + consumer
}

// isAlreadyTerminalSuccess reports whether a row for this idempotency key has
// already reached a terminal success state (delivered or acknowledged). When true,
// DeliverEnvelope skips the attempt entirely and returns nil — the delivery
// already happened, and retrying it would risk duplicating its downstream effect.
func (s *Store) isAlreadyTerminalSuccess(envelopeID, consumer string) (bool, error) {
	key := deliveryIdempotencyKey(envelopeID, consumer)
	var count int
	err := s.db.QueryRow(
		`SELECT COUNT(*) FROM deliveries
		 WHERE idempotency_key = ? AND state IN ('delivered', 'acknowledged')`,
		key,
	).Scan(&count)
	if err != nil && err != sql.ErrNoRows {
		return false, err
	}
	return count > 0, nil
}

// latestDeliveryState returns the state of the most recent row for the given
// (envelopeID, consumer) pair, or "" if no row exists.
func (s *Store) latestDeliveryState(envelopeID, consumer string) (string, error) {
	key := deliveryIdempotencyKey(envelopeID, consumer)
	var state string
	err := s.db.QueryRow(
		`SELECT state FROM deliveries
		 WHERE idempotency_key = ?
		 ORDER BY created_at DESC, id DESC
		 LIMIT 1`,
		key,
	).Scan(&state)
	if err == sql.ErrNoRows {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	return state, nil
}

// hasDeadLetterRow reports whether any row in the delivery history for the
// given (envelopeID, consumer) pair has state dead_letter. Used by ReplayDelivery
// to distinguish the idempotency case (previously dead-lettered, now delivered)
// from the refusal case (never dead-lettered, in some other terminal state).
func (s *Store) hasDeadLetterRow(envelopeID, consumer string) (bool, error) {
	key := deliveryIdempotencyKey(envelopeID, consumer)
	var count int
	err := s.db.QueryRow(
		`SELECT COUNT(*) FROM deliveries WHERE idempotency_key = ? AND state = ?`,
		key, deliveryStateDeadLetter,
	).Scan(&count)
	if err != nil && err != sql.ErrNoRows {
		return false, err
	}
	return count > 0, nil
}

// recoveryInstructions builds a generic, human-readable recovery instruction
// string from the data available at dead-letter time. It is derived, not
// authored per call site, because neither current call site (a file write, a
// directory copy) has a more specific remediation than "inspect, replay, or
// quarantine".
func recoveryInstructions(consumer string, attempts int, class string) string {
	return fmt.Sprintf(
		"Delivery to consumer %q failed after %d attempt(s) with error class %q. "+
			"Inspect the delivery history, then replay or quarantine this dead letter.",
		consumer, attempts, class,
	)
}

// deliverRetryLoop runs the core insert-and-retry loop shared by DeliverEnvelope
// and ReplayDelivery. It starts from startAttempt (1 for a fresh delivery, or the
// next attempt number after the last dead_letter for a replay) and runs up to
// deliveryMaxAttempts total attempts. On success it inserts a delivered row and
// returns nil. On exhaustion it inserts a dead_letter row and returns (lastErr,
// true); the caller decides whether to surface the error based on the critical flag.
//
// It does NOT insert the initial pending row — the caller is responsible for that,
// because for a replay the pending row was already written by the original
// delivery and must not be re-written.
func (s *Store) deliverRetryLoop(envelopeID, consumer string, startAttempt int, attempt func() error) (lastErr error, exhausted bool) {
	for attemptNum := startAttempt; attemptNum <= startAttempt+deliveryMaxAttempts-1; attemptNum++ {
		lastErr = attempt()
		if lastErr == nil {
			// Success: record delivered and return.
			if err := s.insertDeliveryRow(envelopeID, consumer, deliveryStateDelivered, attemptNum, nil, time.Time{}, ""); err != nil {
				// Return a wrapped store error as the "last error" so the caller
				// propagates it; exhausted=false because we didn't exhaust retries.
				return fmt.Errorf("recording delivered delivery for envelope %q consumer %q: %w", envelopeID, consumer, err), false
			}
			return nil, false
		}

		// Failure below the ceiling: record retrying with the next attempt number.
		localMax := startAttempt + deliveryMaxAttempts - 1
		if attemptNum < localMax {
			if err := s.insertDeliveryRow(envelopeID, consumer, deliveryStateRetrying, attemptNum+1, lastErr, time.Now().UTC(), ""); err != nil {
				return fmt.Errorf("recording retrying delivery for envelope %q consumer %q attempt %d: %w", envelopeID, consumer, attemptNum, err), false
			}
			continue
		}

		// Ceiling reached: record dead_letter.
		class := classifyDeliveryError(lastErr)
		instr := recoveryInstructions(consumer, attemptNum, class)
		if err := s.insertDeliveryRowWithInstr(envelopeID, consumer, deliveryStateDeadLetter, attemptNum, lastErr, time.Time{}, instr); err != nil {
			return fmt.Errorf("recording dead_letter delivery for envelope %q consumer %q: %w", envelopeID, consumer, err), false
		}
		return lastErr, true
	}
	// Should be unreachable (loop always returns from inside), but be safe.
	return lastErr, true
}

// insertDeliveryRowWithInstr is like insertDeliveryRow but accepts an explicit
// recovery_instructions string (used for dead_letter rows where the instructions
// are derived before the call).
func (s *Store) insertDeliveryRowWithInstr(envelopeID, consumer, state string, attempt int, failureErr error, nextAttemptAt time.Time, recoveryInstr string) error {
	return s.insertDeliveryRow(envelopeID, consumer, state, attempt, failureErr, nextAttemptAt, recoveryInstr)
}

// DeliverEnvelope delivers an envelope to a consumer with bounded retry and
// idempotency.
//
// The idempotency key is derived from (envelopeID, consumer) — callers do not
// supply one. If a row for this key already reports delivered or acknowledged,
// the attempt function is not called and nil is returned.
//
// Otherwise:
//  1. A pending row is inserted before the first attempt.
//  2. attempt() is called. On success a delivered row is inserted and nil is
//     returned.
//  3. On failure a retrying row is inserted (incrementing the attempt count) and
//     attempt() is called again, up to deliveryMaxAttempts total attempts.
//  4. If every attempt fails a dead_letter row is inserted. If critical is true,
//     the final error is returned. If critical is false, nil is returned — the
//     dead-letter record still exists and is inspectable, but the caller's phase
//     proceeds.
//
// Every state transition is an INSERT, never an UPDATE. The rows are the delivery
// history: a delivery that took three tries must show pending, retrying, retrying,
// delivered — not just its final state.
func (s *Store) DeliverEnvelope(envelopeID, consumer string, critical bool, attempt func() error) error {
	// Idempotency check: skip the attempt when a terminal success row already
	// exists for this (envelope, consumer) pair.
	already, err := s.isAlreadyTerminalSuccess(envelopeID, consumer)
	if err != nil {
		return fmt.Errorf("delivery idempotency check for envelope %q consumer %q: %w", envelopeID, consumer, err)
	}
	if already {
		return nil
	}

	// Insert the pending row before the first attempt so the record exists even
	// if the process exits mid-delivery (R5.3 durability before acknowledgement).
	if err := s.insertDeliveryRow(envelopeID, consumer, deliveryStatePending, 1, nil, time.Time{}, ""); err != nil {
		return fmt.Errorf("recording pending delivery for envelope %q consumer %q: %w", envelopeID, consumer, err)
	}

	lastErr, exhausted := s.deliverRetryLoop(envelopeID, consumer, 1, attempt)
	if !exhausted {
		// Either success (lastErr==nil) or a store-write error (lastErr!=nil).
		return lastErr
	}
	// Retries exhausted — dead_letter row already written.
	if critical {
		return lastErr
	}
	return nil
}

// ReplayDelivery replays a dead-lettered delivery. It is permitted only when the
// latest delivery row for (envelopeID, consumer) is in the dead_letter state.
//
// On success, the delivery reaches the delivered state and the full replay
// history (new pending, retrying, delivered rows) is appended to the existing
// history. A replay that fails again produces a new dead_letter row; the history
// shows multiple dead-letter episodes.
//
// ReplayDelivery refuses (returns an error, writes nothing) if:
//   - The latest state is not dead_letter and the history never had a dead_letter
//     row (i.e. the delivery was never dead-lettered at all)
//   - The latest state is quarantined
//
// ReplayDelivery is a no-op (returns nil, writes nothing, does not call attempt)
// if the delivery was previously dead-lettered and has since been resolved to
// delivered by a prior replay — the same idempotency guarantee that DeliverEnvelope
// gives for an already-delivered envelope.
func (s *Store) ReplayDelivery(envelopeID, consumer string, attempt func() error) error {
	latest, err := s.latestDeliveryState(envelopeID, consumer)
	if err != nil {
		return fmt.Errorf("checking latest delivery state for replay of envelope %q consumer %q: %w", envelopeID, consumer, err)
	}
	switch latest {
	case deliveryStateDeadLetter:
		// Permitted — fall through.
	case deliveryStateQuarantined:
		return fmt.Errorf("cannot replay delivery for envelope %q consumer %q: delivery is quarantined", envelopeID, consumer)
	case deliveryStateDelivered, deliveryStateAcknowledged:
		// The delivery is in a terminal success state. If it was ever dead-lettered,
		// this is the idempotency case (s-8): a prior replay already resolved it,
		// so we do nothing and return nil. If it was never dead-lettered, this is
		// s-7: replay is only meaningful for dead-lettered deliveries.
		hadDeadLetter, dlErr := s.hasDeadLetterRow(envelopeID, consumer)
		if dlErr != nil {
			return fmt.Errorf("checking dead_letter history for replay of envelope %q consumer %q: %w", envelopeID, consumer, dlErr)
		}
		if hadDeadLetter {
			// Idempotency: already resolved by a prior replay — do nothing.
			return nil
		}
		return fmt.Errorf("cannot replay delivery for envelope %q consumer %q: latest state is %q, not dead_letter", envelopeID, consumer, latest)
	case "":
		return fmt.Errorf("cannot replay delivery for envelope %q consumer %q: no delivery record found", envelopeID, consumer)
	default:
		return fmt.Errorf("cannot replay delivery for envelope %q consumer %q: latest state is %q, not dead_letter", envelopeID, consumer, latest)
	}

	// Count existing attempts to determine the next attempt number.
	history, err := s.ListDeliveryHistory(envelopeID, consumer)
	if err != nil {
		return fmt.Errorf("reading delivery history for replay of envelope %q consumer %q: %w", envelopeID, consumer, err)
	}
	// The next attempt number starts after the highest attempt seen so far.
	maxAttempt := 0
	for _, r := range history {
		if r.Attempt > maxAttempt {
			maxAttempt = r.Attempt
		}
	}
	startAttempt := maxAttempt + 1

	// Insert a pending row for the replay before the first attempt.
	if err := s.insertDeliveryRow(envelopeID, consumer, deliveryStatePending, startAttempt, nil, time.Time{}, ""); err != nil {
		return fmt.Errorf("recording pending replay for envelope %q consumer %q: %w", envelopeID, consumer, err)
	}

	lastErr, _ := s.deliverRetryLoop(envelopeID, consumer, startAttempt, attempt)
	return lastErr
}

// QuarantineDelivery records an operator's decision not to retry a dead-lettered
// delivery. It is permitted only when the latest delivery row for (envelopeID,
// consumer) is in the dead_letter state. It inserts a quarantined row carrying
// the operator-supplied reason.
//
// After quarantine, ReplayDelivery will refuse the delivery.
// There is no UnquarantineDelivery — reversing a quarantine is a separate
// explicit action not provided by this package.
func (s *Store) QuarantineDelivery(envelopeID, consumer, reason string) error {
	latest, err := s.latestDeliveryState(envelopeID, consumer)
	if err != nil {
		return fmt.Errorf("checking latest delivery state for quarantine of envelope %q consumer %q: %w", envelopeID, consumer, err)
	}
	if latest != deliveryStateDeadLetter {
		if latest == "" {
			return fmt.Errorf("cannot quarantine delivery for envelope %q consumer %q: no delivery record found", envelopeID, consumer)
		}
		return fmt.Errorf("cannot quarantine delivery for envelope %q consumer %q: latest state is %q, not dead_letter", envelopeID, consumer, latest)
	}

	if err := s.insertDeliveryRowQuarantined(envelopeID, consumer, reason); err != nil {
		return fmt.Errorf("recording quarantine for envelope %q consumer %q: %w", envelopeID, consumer, err)
	}
	return nil
}

// ListDeliveryHistory returns all delivery rows for the (envelopeID, consumer)
// pair, ordered by created_at ascending. Because every state transition is an
// INSERT, the result is the full history of the delivery chain.
func (s *Store) ListDeliveryHistory(envelopeID, consumer string) ([]DeliveryRecord, error) {
	key := deliveryIdempotencyKey(envelopeID, consumer)
	rows, err := s.db.Query(
		// next_attempt_at is deliberately NOT wrapped in COALESCE: the
		// modernc/sqlite driver returns a COALESCE'd DATETIME using Go's
		// time.Time.String() format ("2006-01-02 15:04:05.999999999 -0700 MST"),
		// which parseSQLiteTime's format list does not include, so every row
		// silently parsed back as the zero time regardless of what was stored —
		// exactly the bug this column exists to not have. Selected plain, the
		// driver returns the stored text as-is (or a true NULL), matching the
		// same pattern already used for envelopes.occurred_at/published_at.
		`SELECT id, envelope_id, consumer, state, attempt,
		        next_attempt_at, COALESCE(error, ''), COALESCE(error_class, ''),
		        COALESCE(recovery_instructions, ''),
		        idempotency_key, created_at, updated_at
		 FROM deliveries
		 WHERE idempotency_key = ?
		 ORDER BY created_at ASC, id ASC`,
		key,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var list []DeliveryRecord
	for rows.Next() {
		var r DeliveryRecord
		var nextAttemptStr sql.NullString
		var createdStr, updatedStr string
		if err := rows.Scan(
			&r.ID, &r.EnvelopeID, &r.Consumer, &r.State, &r.Attempt,
			&nextAttemptStr, &r.Error, &r.ErrorClass,
			&r.RecoveryInstructions,
			&r.IdempotencyKey, &createdStr, &updatedStr,
		); err != nil {
			return nil, err
		}
		if nextAttemptStr.Valid {
			r.NextAttemptAt = parseSQLiteTime(nextAttemptStr.String)
		}
		r.CreatedAt = parseSQLiteTime(createdStr)
		r.UpdatedAt = parseSQLiteTime(updatedStr)
		list = append(list, r)
	}
	return list, rows.Err()
}
