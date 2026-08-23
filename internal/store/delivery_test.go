package store

import (
	"errors"
	"fmt"
	"io/fs"
	"path/filepath"
	"testing"
)

// openDeliveryTestStore opens a store and pre-records an envelope so the
// deliveries foreign key to envelopes.id is satisfiable.
func openDeliveryTestStore(t *testing.T) (*Store, string /*envelopeID*/) {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "delivery.db")
	st, err := Open(dbPath)
	if err != nil {
		t.Fatalf("opening store: %v", err)
	}
	t.Cleanup(func() { st.Close() })

	// A run is required before an envelope can be inserted.
	run := &RunRecord{
		ID:      "run-del-1",
		Project: "test",
		TaskID:  "task-del-1",
		Status:  "running",
	}
	if err := st.CreateRun(run); err != nil {
		t.Fatalf("creating run: %v", err)
	}

	envID := "env-del-1"
	env := &EnvelopeRecord{
		ID:            envID,
		RunID:         "run-del-1",
		Repo:          "test-repo",
		Stage:         "build",
		Summary:       "test envelope",
		Type:          "phase.completed",
		SchemaVersion: "1",
		Producer:      "sergeant/test",
		CorrelationID: "run-del-1",
	}
	if err := st.RecordEnvelope(env); err != nil {
		t.Fatalf("recording envelope: %v", err)
	}
	return st, envID
}

// TestDeliveryPendingRowExistsBeforeOutcomeKnown covers scenario s-1:
// a pending row is written before the underlying attempt is made.
func TestDeliveryPendingRowExistsBeforeOutcomeKnown(t *testing.T) {
	st, envID := openDeliveryTestStore(t)

	const consumer = "/fleet/run-del-1/test-repo"

	// Use a channel to pause the attempt so we can inspect the history
	// while the attempt is still in flight.
	pause := make(chan struct{})
	resume := make(chan struct{})

	// Run DeliverEnvelope in a goroutine; the attempt func blocks until we
	// read from resume, letting us read the store mid-delivery.
	done := make(chan error, 1)
	go func() {
		done <- st.DeliverEnvelope(envID, consumer, func() error {
			close(pause) // signal that we are inside the attempt
			<-resume     // wait for the test to read the DB
			return nil
		})
	}()

	// Wait until we are inside the attempt.
	<-pause

	history, err := st.ListDeliveryHistory(envID, consumer)
	if err != nil {
		t.Fatalf("ListDeliveryHistory: %v", err)
	}

	// At least one row must exist and its state must be pending.
	if len(history) == 0 {
		t.Fatal("expected at least one delivery history row before attempt completed, got none")
	}
	if history[0].State != "pending" {
		t.Errorf("expected first row state to be pending, got %q", history[0].State)
	}

	// Let the attempt finish.
	close(resume)
	if err := <-done; err != nil {
		t.Fatalf("DeliverEnvelope returned unexpected error: %v", err)
	}
}

// TestDeliveryHistoryRetainedNotOverwritten covers scenario s-2:
// all state rows are readable afterward (append-only).
func TestDeliveryHistoryRetainedNotOverwritten(t *testing.T) {
	st, envID := openDeliveryTestStore(t)

	const consumer = "/fleet/run-del-1/test-repo"

	calls := 0
	deliverErr := errors.New("transient failure")
	// Fail once, then succeed.
	err := st.DeliverEnvelope(envID, consumer, func() error {
		calls++
		if calls == 1 {
			return deliverErr
		}
		return nil
	})
	if err != nil {
		t.Fatalf("DeliverEnvelope returned unexpected error: %v", err)
	}

	history, err := st.ListDeliveryHistory(envID, consumer)
	if err != nil {
		t.Fatalf("ListDeliveryHistory: %v", err)
	}

	// We expect: pending, retrying, delivered — three distinct rows.
	if len(history) < 3 {
		t.Fatalf("expected at least 3 history rows (pending, retrying, delivered), got %d: %v", len(history), stateList(history))
	}

	// First row must be pending.
	if history[0].State != "pending" {
		t.Errorf("row 0: expected state=pending, got %q", history[0].State)
	}

	// Verify that there is a retrying row.
	found := map[string]bool{}
	for _, r := range history {
		found[r.State] = true
	}
	if !found["retrying"] {
		t.Errorf("expected a retrying row in history, states were: %v", stateList(history))
	}
	if !found["delivered"] {
		t.Errorf("expected a delivered row in history, states were: %v", stateList(history))
	}
	if !found["pending"] {
		t.Errorf("expected a pending row in history, states were: %v", stateList(history))
	}
}

// TestDeliveryConsumerIsRecorded covers scenario s-3:
// the consumer identity is persisted on the delivery record.
func TestDeliveryConsumerIsRecorded(t *testing.T) {
	st, envID := openDeliveryTestStore(t)

	const consumer = "/fleet/run-del-1/target-repo"

	if err := st.DeliverEnvelope(envID, consumer, func() error { return nil }); err != nil {
		t.Fatalf("DeliverEnvelope: %v", err)
	}

	history, err := st.ListDeliveryHistory(envID, consumer)
	if err != nil {
		t.Fatalf("ListDeliveryHistory: %v", err)
	}
	if len(history) == 0 {
		t.Fatal("expected history rows, got none")
	}
	for _, r := range history {
		if r.Consumer != consumer {
			t.Errorf("row %q: expected consumer %q, got %q", r.State, consumer, r.Consumer)
		}
	}
}

// TestDeliveryAttemptCountIncrementsWithRetry covers scenario s-4:
// the retried row's attempt number is greater than the first.
func TestDeliveryAttemptCountIncrementsWithRetry(t *testing.T) {
	st, envID := openDeliveryTestStore(t)

	const consumer = "/fleet/run-del-1/downstream"

	calls := 0
	err := st.DeliverEnvelope(envID, consumer, func() error {
		calls++
		if calls == 1 {
			return errors.New("fail once")
		}
		return nil
	})
	if err != nil {
		t.Fatalf("DeliverEnvelope: %v", err)
	}

	history, err := st.ListDeliveryHistory(envID, consumer)
	if err != nil {
		t.Fatalf("ListDeliveryHistory: %v", err)
	}

	// Find the retrying row. Its attempt must be 2.
	var retryAttempt int
	for _, r := range history {
		if r.State == "retrying" {
			retryAttempt = r.Attempt
		}
	}
	if retryAttempt != 2 {
		t.Errorf("expected retrying row to have attempt=2, got attempt=%d (history: %v)", retryAttempt, stateList(history))
	}
}

// TestDeliveryRetriesUpToBound covers scenario s-5:
// when every attempt fails the delivery is attempted exactly maxAttempts times.
func TestDeliveryRetriesUpToBound(t *testing.T) {
	st, envID := openDeliveryTestStore(t)

	const consumer = "/fleet/run-del-1/always-fails"
	const wantCalls = 3 // bound defined by the spec (3 total attempts)

	calls := 0
	_ = st.DeliverEnvelope(envID, consumer, func() error {
		calls++
		return fmt.Errorf("permanent failure attempt %d", calls)
	})

	if calls != wantCalls {
		t.Errorf("expected attempt function to be called %d times, got %d", wantCalls, calls)
	}
}

// TestDeliveryRetryExhaustionIsFailed covers scenario s-6:
// after all attempts fail the final state is failed and an error is returned.
func TestDeliveryRetryExhaustionIsFailed(t *testing.T) {
	st, envID := openDeliveryTestStore(t)

	const consumer = "/fleet/run-del-1/exhausted"

	lastErr := errors.New("always broken")
	err := st.DeliverEnvelope(envID, consumer, func() error { return lastErr })
	if err == nil {
		t.Fatal("expected DeliverEnvelope to return an error after exhausting retries, got nil")
	}

	history, err2 := st.ListDeliveryHistory(envID, consumer)
	if err2 != nil {
		t.Fatalf("ListDeliveryHistory: %v", err2)
	}

	// The last row must be failed.
	if len(history) == 0 {
		t.Fatal("expected history rows, got none")
	}
	last := history[len(history)-1]
	if last.State != "failed" {
		t.Errorf("expected last state=failed, got %q (history: %v)", last.State, stateList(history))
	}
}

// TestDeliveryIdempotencyAfterSuccess covers scenario s-7:
// a second DeliverEnvelope call for an already-delivered key is a no-op.
func TestDeliveryIdempotencyAfterSuccess(t *testing.T) {
	st, envID := openDeliveryTestStore(t)

	const consumer = "/fleet/run-del-1/idempotent"

	calls := 0
	attemptFn := func() error {
		calls++
		return nil
	}

	// First delivery: should succeed and call attemptFn once.
	if err := st.DeliverEnvelope(envID, consumer, attemptFn); err != nil {
		t.Fatalf("first DeliverEnvelope: %v", err)
	}
	if calls != 1 {
		t.Errorf("expected 1 call after first delivery, got %d", calls)
	}

	// Second delivery: should be a no-op; attemptFn must NOT be called again.
	if err := st.DeliverEnvelope(envID, consumer, attemptFn); err != nil {
		t.Fatalf("second DeliverEnvelope: %v", err)
	}
	if calls != 1 {
		t.Errorf("expected still 1 call after second delivery (no-op), got %d", calls)
	}
}

// TestDeliveryIdempotencyKeyIsDerived covers scenario s-8:
// two separate callers for the same (envelopeID, consumer) share one key without
// either caller passing one explicitly.
func TestDeliveryIdempotencyKeyIsDerived(t *testing.T) {
	st, envID := openDeliveryTestStore(t)

	const consumer = "/fleet/run-del-1/derived-key"

	// First call delivers successfully.
	if err := st.DeliverEnvelope(envID, consumer, func() error { return nil }); err != nil {
		t.Fatalf("first DeliverEnvelope: %v", err)
	}

	// Second call: the key must resolve to the same idempotency key so the second
	// attempt is suppressed. Neither caller supplied a key.
	secondCalled := false
	if err := st.DeliverEnvelope(envID, consumer, func() error {
		secondCalled = true
		return nil
	}); err != nil {
		t.Fatalf("second DeliverEnvelope: %v", err)
	}

	if secondCalled {
		t.Error("attempt function was called on second delivery — idempotency key was not derived or not checked")
	}

	// Confirm the history shows one delivery chain (not two independent chains).
	history, err := st.ListDeliveryHistory(envID, consumer)
	if err != nil {
		t.Fatalf("ListDeliveryHistory: %v", err)
	}
	// Exactly one chain: pending + delivered (two rows), not four.
	var deliveredCount int
	for _, r := range history {
		if r.State == "delivered" {
			deliveredCount++
		}
	}
	if deliveredCount != 1 {
		t.Errorf("expected exactly one delivered row, got %d (history: %v)", deliveredCount, stateList(history))
	}
}

// TestDeliveryThreeAttemptsShowsFullHistory verifies that a delivery that fails
// twice then succeeds produces the correct history: pending, retrying (attempt 2),
// retrying (attempt 3 ... wait, per spec: on fail attempt 1 → retrying, on fail
// attempt 2 → retrying, on success attempt 3 → delivered).
func TestDeliveryThreeAttemptsShowsFullHistory(t *testing.T) {
	st, envID := openDeliveryTestStore(t)

	const consumer = "/fleet/run-del-1/three-tries"

	calls := 0
	err := st.DeliverEnvelope(envID, consumer, func() error {
		calls++
		if calls < 3 {
			return fmt.Errorf("fail attempt %d", calls)
		}
		return nil
	})
	if err != nil {
		t.Fatalf("DeliverEnvelope: %v", err)
	}
	if calls != 3 {
		t.Errorf("expected 3 calls, got %d", calls)
	}

	history, err := st.ListDeliveryHistory(envID, consumer)
	if err != nil {
		t.Fatalf("ListDeliveryHistory: %v", err)
	}

	// Expected sequence: pending (attempt 1), retrying (attempt 2),
	// retrying (attempt 3... no — on the third try it succeeds, so:
	// pending (before try 1), retrying (after try 1 fails),
	// retrying (after try 2 fails), delivered (after try 3 succeeds).
	// That is 4 rows total, but implementations may vary.
	// The mandatory invariants are:
	// 1. First row is pending.
	// 2. There are at least 2 retrying rows.
	// 3. Last row is delivered.
	// 4. Attempt numbers increase.
	if len(history) < 4 {
		t.Fatalf("expected at least 4 rows (pending, retrying, retrying, delivered), got %d: %v",
			len(history), stateList(history))
	}
	if history[0].State != "pending" {
		t.Errorf("row 0: expected pending, got %q", history[0].State)
	}
	last := history[len(history)-1]
	if last.State != "delivered" {
		t.Errorf("last row: expected delivered, got %q", last.State)
	}

	// Count retrying rows.
	var retryCount int
	for _, r := range history {
		if r.State == "retrying" {
			retryCount++
		}
	}
	if retryCount < 2 {
		t.Errorf("expected at least 2 retrying rows, got %d (history: %v)", retryCount, stateList(history))
	}

	// Verify attempt numbers are monotonically non-decreasing.
	prev := 0
	for i, r := range history {
		if r.Attempt < prev {
			t.Errorf("row %d: attempt %d < previous attempt %d (not monotonic)", i, r.Attempt, prev)
		}
		prev = r.Attempt
	}
}

// stateList is a formatting helper for test failure messages.
func stateList(history []DeliveryRecord) []string {
	out := make([]string, len(history))
	for i, r := range history {
		out[i] = fmt.Sprintf("%s(attempt=%d)", r.State, r.Attempt)
	}
	return out
}

// TestDeliveryRetryingRowSetsNextAttemptAt covers the R5.4 "lease/next-attempt
// timestamps" requirement: a retrying row must record when its next attempt
// is scheduled, not leave the column NULL. Regression for Review 007, which
// found next_attempt_at was declared in the schema but never populated by any
// state, including retrying, so no test caught it.
func TestDeliveryRetryingRowSetsNextAttemptAt(t *testing.T) {
	st, envID := openDeliveryTestStore(t)

	const consumer = "/fleet/run-del-1/next-attempt"

	calls := 0
	if err := st.DeliverEnvelope(envID, consumer, func() error {
		calls++
		if calls == 1 {
			return errors.New("fail once")
		}
		return nil
	}); err != nil {
		t.Fatalf("DeliverEnvelope: %v", err)
	}

	history, err := st.ListDeliveryHistory(envID, consumer)
	if err != nil {
		t.Fatal(err)
	}
	var sawRetrying bool
	for _, r := range history {
		if r.State != "retrying" {
			continue
		}
		sawRetrying = true
		if r.NextAttemptAt.IsZero() {
			t.Errorf("retrying row has zero NextAttemptAt, want it set")
		}
	}
	if !sawRetrying {
		t.Fatal("expected a retrying row in history, found none")
	}
}

// TestDeliveryErrorIsClassified covers the R5.4 "error classification"
// requirement. Regression for Review 007, which found the error column held
// only a raw, unclassified message.
func TestDeliveryErrorIsClassified(t *testing.T) {
	st, envID := openDeliveryTestStore(t)

	const consumer = "/fleet/run-del-1/error-class"

	err := st.DeliverEnvelope(envID, consumer, func() error {
		return &fs.PathError{Op: "open", Path: "/does/not/exist", Err: fs.ErrNotExist}
	})
	if err == nil {
		t.Fatal("expected DeliverEnvelope to return an error")
	}

	history, herr := st.ListDeliveryHistory(envID, consumer)
	if herr != nil {
		t.Fatal(herr)
	}
	last := history[len(history)-1]
	if last.State != "failed" {
		t.Fatalf("expected final state failed, got %q", last.State)
	}
	if last.ErrorClass != "filesystem" {
		t.Errorf("expected error_class %q for a *fs.PathError, got %q", "filesystem", last.ErrorClass)
	}
}

// TestDeliveryUnknownErrorIsClassifiedUnknown covers the default branch of the
// classification: an error type the taxonomy does not recognise is "unknown",
// not left blank — a blank class would be indistinguishable from "no failure
// occurred".
func TestDeliveryUnknownErrorIsClassifiedUnknown(t *testing.T) {
	st, envID := openDeliveryTestStore(t)

	const consumer = "/fleet/run-del-1/unknown-class"

	err := st.DeliverEnvelope(envID, consumer, func() error {
		return errors.New("something unclassifiable")
	})
	if err == nil {
		t.Fatal("expected DeliverEnvelope to return an error")
	}

	history, herr := st.ListDeliveryHistory(envID, consumer)
	if herr != nil {
		t.Fatal(herr)
	}
	last := history[len(history)-1]
	if last.ErrorClass != "unknown" {
		t.Errorf("expected error_class %q for a generic error, got %q", "unknown", last.ErrorClass)
	}
}
