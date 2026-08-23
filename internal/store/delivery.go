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
	ID             string    `json:"id"`
	EnvelopeID     string    `json:"envelope_id"`
	Consumer       string    `json:"consumer"`
	State          string    `json:"state"`
	Attempt        int       `json:"attempt"`
	NextAttemptAt  time.Time `json:"next_attempt_at,omitempty"`
	Error          string    `json:"error,omitempty"`
	ErrorClass     string    `json:"error_class,omitempty"`
	IdempotencyKey string    `json:"idempotency_key"`
	CreatedAt      time.Time `json:"created_at"`
	UpdatedAt      time.Time `json:"updated_at"`
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
	errorClassFilesystem = "filesystem"
	errorClassCancelled  = "cancelled"
	errorClassUnknown    = "unknown"
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
func (s *Store) insertDeliveryRow(envelopeID, consumer, state string, attempt int, failureErr error, nextAttemptAt time.Time) error {
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
		 (id, envelope_id, consumer, state, attempt, next_attempt_at, error, error_class, idempotency_key, created_at, updated_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, envelopeID, consumer, state, attempt, nextAttemptCol, errMsg, classifyDeliveryError(failureErr), key, now, now,
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
//  4. If every attempt fails a failed row is inserted and the final error is
//     returned.
//
// Every state transition is an INSERT, never an UPDATE. The rows are the delivery
// history: a delivery that took three tries must show pending, retrying, retrying,
// delivered — not just its final state.
func (s *Store) DeliverEnvelope(envelopeID, consumer string, attempt func() error) error {
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
	if err := s.insertDeliveryRow(envelopeID, consumer, deliveryStatePending, 1, nil, time.Time{}); err != nil {
		return fmt.Errorf("recording pending delivery for envelope %q consumer %q: %w", envelopeID, consumer, err)
	}

	var lastErr error
	for attemptNum := 1; attemptNum <= deliveryMaxAttempts; attemptNum++ {
		lastErr = attempt()
		if lastErr == nil {
			// Success: record delivered and return.
			if err := s.insertDeliveryRow(envelopeID, consumer, deliveryStateDelivered, attemptNum, nil, time.Time{}); err != nil {
				return fmt.Errorf("recording delivered delivery for envelope %q consumer %q: %w", envelopeID, consumer, err)
			}
			return nil
		}

		// Failure below the ceiling: record retrying with the next attempt number,
		// then loop. next_attempt_at is "now" because the retry happens
		// immediately in-process, with no backoff clock — see the doc comment
		// on insertDeliveryRow.
		if attemptNum < deliveryMaxAttempts {
			if err := s.insertDeliveryRow(envelopeID, consumer, deliveryStateRetrying, attemptNum+1, lastErr, time.Now().UTC()); err != nil {
				return fmt.Errorf("recording retrying delivery for envelope %q consumer %q attempt %d: %w", envelopeID, consumer, attemptNum, err)
			}
			continue
		}

		// Ceiling reached: record failed and return the error.
		if err := s.insertDeliveryRow(envelopeID, consumer, deliveryStateFailed, attemptNum, lastErr, time.Time{}); err != nil {
			return fmt.Errorf("recording failed delivery for envelope %q consumer %q: %w", envelopeID, consumer, err)
		}
	}

	return lastErr
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
