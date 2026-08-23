package store

import (
	"errors"
	"fmt"
	"io/fs"
	"path/filepath"
	"strings"
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
		done <- st.DeliverEnvelope(envID, consumer, true, func() error {
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
	err := st.DeliverEnvelope(envID, consumer, true, func() error {
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

	if err := st.DeliverEnvelope(envID, consumer, true, func() error { return nil }); err != nil {
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
	err := st.DeliverEnvelope(envID, consumer, true, func() error {
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
	_ = st.DeliverEnvelope(envID, consumer, true, func() error {
		calls++
		return fmt.Errorf("permanent failure attempt %d", calls)
	})

	if calls != wantCalls {
		t.Errorf("expected attempt function to be called %d times, got %d", wantCalls, calls)
	}
}

// TestDeliveryRetryExhaustionIsDeadLetter covers scenario s-6 (renamed from
// TestDeliveryRetryExhaustionIsFailed): after all attempts fail the final state
// is dead_letter (not failed) and an error is returned (critical=true).
func TestDeliveryRetryExhaustionIsDeadLetter(t *testing.T) {
	st, envID := openDeliveryTestStore(t)

	const consumer = "/fleet/run-del-1/exhausted"

	lastErr := errors.New("always broken")
	err := st.DeliverEnvelope(envID, consumer, true, func() error { return lastErr })
	if err == nil {
		t.Fatal("expected DeliverEnvelope to return an error after exhausting retries, got nil")
	}

	history, err2 := st.ListDeliveryHistory(envID, consumer)
	if err2 != nil {
		t.Fatalf("ListDeliveryHistory: %v", err2)
	}

	// The last row must be dead_letter, not failed.
	if len(history) == 0 {
		t.Fatal("expected history rows, got none")
	}
	last := history[len(history)-1]
	if last.State != "dead_letter" {
		t.Errorf("expected last state=dead_letter, got %q (history: %v)", last.State, stateList(history))
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
	if err := st.DeliverEnvelope(envID, consumer, true, attemptFn); err != nil {
		t.Fatalf("first DeliverEnvelope: %v", err)
	}
	if calls != 1 {
		t.Errorf("expected 1 call after first delivery, got %d", calls)
	}

	// Second delivery: should be a no-op; attemptFn must NOT be called again.
	if err := st.DeliverEnvelope(envID, consumer, true, attemptFn); err != nil {
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
	if err := st.DeliverEnvelope(envID, consumer, true, func() error { return nil }); err != nil {
		t.Fatalf("first DeliverEnvelope: %v", err)
	}

	// Second call: the key must resolve to the same idempotency key so the second
	// attempt is suppressed. Neither caller supplied a key.
	secondCalled := false
	if err := st.DeliverEnvelope(envID, consumer, true, func() error {
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
	err := st.DeliverEnvelope(envID, consumer, true, func() error {
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
	if err := st.DeliverEnvelope(envID, consumer, true, func() error {
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
// only a raw, unclassified message. The final state is now dead_letter (not
// failed) because exhausted retries produce a dead-letter row (R5.5).
func TestDeliveryErrorIsClassified(t *testing.T) {
	st, envID := openDeliveryTestStore(t)

	const consumer = "/fleet/run-del-1/error-class"

	err := st.DeliverEnvelope(envID, consumer, true, func() error {
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
	if last.State != "dead_letter" {
		t.Fatalf("expected final state dead_letter, got %q", last.State)
	}
	if last.ErrorClass != "filesystem" {
		t.Errorf("expected error_class %q for a *fs.PathError, got %q", "filesystem", last.ErrorClass)
	}
}

// TestDeliveryUnknownErrorIsClassifiedUnknown covers the default branch of the
// classification: an error type the taxonomy does not recognise is "unknown",
// not left blank — a blank class would be indistinguishable from "no failure
// occurred". The final state is now dead_letter (R5.5).
func TestDeliveryUnknownErrorIsClassifiedUnknown(t *testing.T) {
	st, envID := openDeliveryTestStore(t)

	const consumer = "/fleet/run-del-1/unknown-class"

	err := st.DeliverEnvelope(envID, consumer, true, func() error {
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

// ---------------------------------------------------------------------------
// R5.5 dead-lettering scenarios
// ---------------------------------------------------------------------------

// TestDeadLetterExhaustedRetriesProducesDeadLetterNotFailed covers spec scenario
// s-1: exhausting retries produces dead_letter, not failed.
func TestDeadLetterExhaustedRetriesProducesDeadLetterNotFailed(t *testing.T) {
	st, envID := openDeliveryTestStore(t)
	const consumer = "/fleet/run-del-1/dl-s1"

	err := st.DeliverEnvelope(envID, consumer, true, func() error {
		return errors.New("permanent failure")
	})
	if err == nil {
		t.Fatal("expected error from critical dead-lettered delivery, got nil")
	}

	history, herr := st.ListDeliveryHistory(envID, consumer)
	if herr != nil {
		t.Fatalf("ListDeliveryHistory: %v", herr)
	}
	if len(history) == 0 {
		t.Fatal("expected history rows, got none")
	}
	last := history[len(history)-1]
	if last.State != deliveryStateDeadLetter {
		t.Errorf("s-1: expected final state %q, got %q (history: %v)", deliveryStateDeadLetter, last.State, stateList(history))
	}
	// Confirm no failed rows.
	for _, r := range history {
		if r.State == deliveryStateFailed {
			t.Errorf("s-1: unexpected failed row in history (history: %v)", stateList(history))
		}
	}
}

// TestDeadLetterRecordNamesEnvelopeReasonAndRecoveryInstructions covers spec
// scenario s-2: dead-letter row has envelope_id, error (reason), and non-empty
// recovery instructions.
func TestDeadLetterRecordNamesEnvelopeReasonAndRecoveryInstructions(t *testing.T) {
	st, envID := openDeliveryTestStore(t)
	const consumer = "/fleet/run-del-1/dl-s2"

	_ = st.DeliverEnvelope(envID, consumer, true, func() error {
		return errors.New("bang")
	})

	history, herr := st.ListDeliveryHistory(envID, consumer)
	if herr != nil {
		t.Fatalf("ListDeliveryHistory: %v", herr)
	}
	var dl *DeliveryRecord
	for i := range history {
		if history[i].State == deliveryStateDeadLetter {
			dl = &history[i]
		}
	}
	if dl == nil {
		t.Fatalf("s-2: no dead_letter row in history: %v", stateList(history))
	}
	if dl.EnvelopeID != envID {
		t.Errorf("s-2: dead_letter row EnvelopeID = %q, want %q", dl.EnvelopeID, envID)
	}
	if dl.Error == "" {
		t.Error("s-2: dead_letter row Error is empty, want the failure reason")
	}
	if dl.RecoveryInstructions == "" {
		t.Error("s-2: dead_letter row RecoveryInstructions is empty, want non-empty guidance")
	}
}

// TestDeadLetterAttemptHistoryIsRetained covers spec scenario s-3: prior attempt
// rows survive dead-lettering (the dead_letter row is an addition, not a replacement).
func TestDeadLetterAttemptHistoryIsRetained(t *testing.T) {
	st, envID := openDeliveryTestStore(t)
	const consumer = "/fleet/run-del-1/dl-s3"

	_ = st.DeliverEnvelope(envID, consumer, true, func() error {
		return errors.New("always fails")
	})

	history, herr := st.ListDeliveryHistory(envID, consumer)
	if herr != nil {
		t.Fatalf("ListDeliveryHistory: %v", herr)
	}
	// Expect at minimum: pending, retrying, retrying, dead_letter (4 rows for 3 attempts).
	if len(history) < 4 {
		t.Fatalf("s-3: expected at least 4 history rows, got %d: %v", len(history), stateList(history))
	}
	if history[0].State != deliveryStatePending {
		t.Errorf("s-3: first row should be pending, got %q", history[0].State)
	}
	var retryCount int
	for _, r := range history {
		if r.State == deliveryStateRetrying {
			retryCount++
		}
	}
	if retryCount < 2 {
		t.Errorf("s-3: expected at least 2 retrying rows, got %d (history: %v)", retryCount, stateList(history))
	}
}

// TestDeadLetterCriticalFailsCaller covers spec scenario s-4: a critical dead
// letter returns an error to its caller.
func TestDeadLetterCriticalFailsCaller(t *testing.T) {
	st, envID := openDeliveryTestStore(t)
	const consumer = "/fleet/run-del-1/dl-s4"

	err := st.DeliverEnvelope(envID, consumer, true /*critical*/, func() error {
		return errors.New("critical failure")
	})
	if err == nil {
		t.Error("s-4: expected error from critical dead-lettered delivery, got nil")
	}
}

// TestDeadLetterNonCriticalDoesNotFailCallerButIsRecorded covers spec scenario
// s-5: a non-critical dead letter returns nil to its caller, but the dead-letter
// record still exists and is readable.
func TestDeadLetterNonCriticalDoesNotFailCallerButIsRecorded(t *testing.T) {
	st, envID := openDeliveryTestStore(t)
	const consumer = "/fleet/run-del-1/dl-s5"

	err := st.DeliverEnvelope(envID, consumer, false /*non-critical*/, func() error {
		return errors.New("non-critical failure")
	})
	if err != nil {
		t.Errorf("s-5: expected nil from non-critical dead-lettered delivery, got %v", err)
	}

	// The dead-letter record must still exist.
	history, herr := st.ListDeliveryHistory(envID, consumer)
	if herr != nil {
		t.Fatalf("ListDeliveryHistory: %v", herr)
	}
	var hasDL bool
	for _, r := range history {
		if r.State == deliveryStateDeadLetter {
			hasDL = true
		}
	}
	if !hasDL {
		t.Errorf("s-5: expected dead_letter row to exist even though caller got nil (history: %v)", stateList(history))
	}
}

// TestDeadLetterCanBeReplayed covers spec scenario s-6: a dead-lettered delivery
// can be replayed, and the delivery's latest state becomes delivered.
func TestDeadLetterCanBeReplayed(t *testing.T) {
	st, envID := openDeliveryTestStore(t)
	const consumer = "/fleet/run-del-1/dl-s6"

	// First exhaust all attempts.
	_ = st.DeliverEnvelope(envID, consumer, true, func() error {
		return errors.New("always fails")
	})

	// Confirm it is dead-lettered.
	history, herr := st.ListDeliveryHistory(envID, consumer)
	if herr != nil {
		t.Fatalf("ListDeliveryHistory after exhaustion: %v", herr)
	}
	last := history[len(history)-1]
	if last.State != deliveryStateDeadLetter {
		t.Fatalf("s-6: expected dead_letter before replay, got %q", last.State)
	}

	// Replay successfully.
	if err := st.ReplayDelivery(envID, consumer, func() error { return nil }); err != nil {
		t.Fatalf("s-6: ReplayDelivery returned unexpected error: %v", err)
	}

	// Latest state must now be delivered.
	history2, herr2 := st.ListDeliveryHistory(envID, consumer)
	if herr2 != nil {
		t.Fatalf("ListDeliveryHistory after replay: %v", herr2)
	}
	last2 := history2[len(history2)-1]
	if last2.State != deliveryStateDelivered {
		t.Errorf("s-6: expected delivered after successful replay, got %q (history: %v)", last2.State, stateList(history2))
	}
}

// TestDeadLetterReplayRefusedWhenNotDeadLetter covers spec scenario s-7:
// replaying a delivery whose latest state is not dead_letter is refused with
// an error and no new row is written.
func TestDeadLetterReplayRefusedWhenNotDeadLetter(t *testing.T) {
	st, envID := openDeliveryTestStore(t)
	const consumer = "/fleet/run-del-1/dl-s7"

	// Deliver successfully so latest state is delivered.
	if err := st.DeliverEnvelope(envID, consumer, true, func() error { return nil }); err != nil {
		t.Fatalf("DeliverEnvelope: %v", err)
	}

	rowsBefore, herr := st.ListDeliveryHistory(envID, consumer)
	if herr != nil {
		t.Fatalf("ListDeliveryHistory before replay attempt: %v", herr)
	}

	called := false
	err := st.ReplayDelivery(envID, consumer, func() error {
		called = true
		return nil
	})
	if err == nil {
		t.Error("s-7: expected error when replaying a non-dead-letter delivery, got nil")
	}
	if called {
		t.Error("s-7: attempt function must not be called when replay is refused")
	}

	// No new rows must have been written.
	rowsAfter, herr2 := st.ListDeliveryHistory(envID, consumer)
	if herr2 != nil {
		t.Fatalf("ListDeliveryHistory after refused replay: %v", herr2)
	}
	if len(rowsAfter) != len(rowsBefore) {
		t.Errorf("s-7: row count changed after refused replay: before=%d after=%d (history: %v)",
			len(rowsBefore), len(rowsAfter), stateList(rowsAfter))
	}
}

// TestDeadLetterAlreadyResolvedIsNotReplayedTwice covers spec scenario s-8:
// replaying a dead letter that has already been delivered by a prior replay is
// a no-op — the wrapped function is NOT called again.
func TestDeadLetterAlreadyResolvedIsNotReplayedTwice(t *testing.T) {
	st, envID := openDeliveryTestStore(t)
	const consumer = "/fleet/run-del-1/dl-s8"

	// Exhaust retries to produce dead_letter.
	_ = st.DeliverEnvelope(envID, consumer, true, func() error {
		return errors.New("always fails")
	})

	// First replay succeeds.
	calls := 0
	if err := st.ReplayDelivery(envID, consumer, func() error {
		calls++
		return nil
	}); err != nil {
		t.Fatalf("s-8: first ReplayDelivery returned error: %v", err)
	}
	if calls != 1 {
		t.Fatalf("s-8: expected 1 call on first replay, got %d", calls)
	}

	// Second replay: the delivery is already delivered, must not call the function.
	if err := st.ReplayDelivery(envID, consumer, func() error {
		calls++
		return nil
	}); err != nil {
		t.Fatalf("s-8: second ReplayDelivery returned unexpected error: %v", err)
	}
	if calls != 1 {
		t.Errorf("s-8: attempt function was called on second replay (already delivered): calls=%d", calls)
	}
}

// TestDeadLetterCanBeQuarantinedWithReason covers spec scenario s-9: a
// dead-lettered delivery can be quarantined with a reason, and the reason reads
// back from the delivery history.
func TestDeadLetterCanBeQuarantinedWithReason(t *testing.T) {
	st, envID := openDeliveryTestStore(t)
	const consumer = "/fleet/run-del-1/dl-s9"
	const reason = "poison message: schema mismatch, will never succeed"

	// Exhaust retries.
	_ = st.DeliverEnvelope(envID, consumer, true, func() error {
		return errors.New("always fails")
	})

	// Quarantine.
	if err := st.QuarantineDelivery(envID, consumer, reason); err != nil {
		t.Fatalf("s-9: QuarantineDelivery returned error: %v", err)
	}

	// Latest state must be quarantined and reason must be readable.
	history, herr := st.ListDeliveryHistory(envID, consumer)
	if herr != nil {
		t.Fatalf("ListDeliveryHistory: %v", herr)
	}
	last := history[len(history)-1]
	if last.State != deliveryStateQuarantined {
		t.Errorf("s-9: expected latest state quarantined, got %q (history: %v)", last.State, stateList(history))
	}
	if last.Error != reason {
		t.Errorf("s-9: quarantine reason mismatch: got %q, want %q", last.Error, reason)
	}
	if last.ErrorClass != errorClassQuarantined {
		t.Errorf("s-9: quarantine error_class mismatch: got %q, want %q", last.ErrorClass, errorClassQuarantined)
	}
}

// TestDeadLetterQuarantineRefusedWhenNotDeadLetter covers spec scenario s-10:
// quarantining a delivery whose latest state is not dead_letter is refused with
// an error and no new row is written.
func TestDeadLetterQuarantineRefusedWhenNotDeadLetter(t *testing.T) {
	st, envID := openDeliveryTestStore(t)
	const consumer = "/fleet/run-del-1/dl-s10"

	// Deliver successfully.
	if err := st.DeliverEnvelope(envID, consumer, true, func() error { return nil }); err != nil {
		t.Fatalf("DeliverEnvelope: %v", err)
	}

	rowsBefore, herr := st.ListDeliveryHistory(envID, consumer)
	if herr != nil {
		t.Fatalf("ListDeliveryHistory before quarantine attempt: %v", herr)
	}

	err := st.QuarantineDelivery(envID, consumer, "some reason")
	if err == nil {
		t.Error("s-10: expected error when quarantining a non-dead-letter delivery, got nil")
	}

	// No new rows must have been written.
	rowsAfter, herr2 := st.ListDeliveryHistory(envID, consumer)
	if herr2 != nil {
		t.Fatalf("ListDeliveryHistory after refused quarantine: %v", herr2)
	}
	if len(rowsAfter) != len(rowsBefore) {
		t.Errorf("s-10: row count changed after refused quarantine: before=%d after=%d (history: %v)",
			len(rowsBefore), len(rowsAfter), stateList(rowsAfter))
	}
}

// TestDeadLetterQuarantinedDeliveryRefusesReplay covers spec scenario s-11:
// replaying a quarantined delivery is refused with an error naming the quarantine,
// and no new row is written.
func TestDeadLetterQuarantinedDeliveryRefusesReplay(t *testing.T) {
	st, envID := openDeliveryTestStore(t)
	const consumer = "/fleet/run-del-1/dl-s11"
	const reason = "operator decided not to retry"

	// Exhaust retries, then quarantine.
	_ = st.DeliverEnvelope(envID, consumer, true, func() error {
		return errors.New("always fails")
	})
	if err := st.QuarantineDelivery(envID, consumer, reason); err != nil {
		t.Fatalf("QuarantineDelivery: %v", err)
	}

	rowsBefore, herr := st.ListDeliveryHistory(envID, consumer)
	if herr != nil {
		t.Fatalf("ListDeliveryHistory before replay attempt: %v", herr)
	}

	called := false
	err := st.ReplayDelivery(envID, consumer, func() error {
		called = true
		return nil
	})
	if err == nil {
		t.Error("s-11: expected error when replaying a quarantined delivery, got nil")
	}
	// The error must mention quarantine.
	if err != nil && !strings.Contains(err.Error(), "quarantine") {
		t.Errorf("s-11: expected error to mention quarantine, got: %v", err)
	}
	if called {
		t.Error("s-11: attempt function must not be called when replay is refused for quarantined delivery")
	}

	// No new rows must have been written.
	rowsAfter, herr2 := st.ListDeliveryHistory(envID, consumer)
	if herr2 != nil {
		t.Fatalf("ListDeliveryHistory after refused replay: %v", herr2)
	}
	if len(rowsAfter) != len(rowsBefore) {
		t.Errorf("s-11: row count changed after refused replay: before=%d after=%d (history: %v)",
			len(rowsBefore), len(rowsAfter), stateList(rowsAfter))
	}
}
