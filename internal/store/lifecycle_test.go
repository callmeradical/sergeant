package store

import (
	"fmt"
	"strings"
	"testing"
	"time"
)

// seedIntentRun writes an intent, its bullets and a run pointing at that intent,
// which is the shape every terminal-run transition operates on.
func seedIntentRun(t *testing.T, st *Store, runID, intentID, intentStatus string, bulletStatuses ...string) {
	t.Helper()
	if err := st.CreateIntent(&IntentRecord{
		ID: intentID, Project: "p", Statement: "s", Status: intentStatus,
	}); err != nil {
		t.Fatalf("creating intent %s: %v", intentID, err)
	}
	for i, status := range bulletStatuses {
		if err := st.CreateBullet(&BulletRecord{
			ID: bulletID(intentID, i+1), IntentID: intentID, Repo: "api", Position: i + 1, Status: status,
		}); err != nil {
			t.Fatalf("creating bullet %d of %s: %v", i+1, intentID, err)
		}
	}
	if err := st.CreateRun(&RunRecord{
		ID: runID, Project: "p", TaskID: runID, IntentID: intentID, Status: "running",
	}); err != nil {
		t.Fatalf("creating run %s: %v", runID, err)
	}
}

func bulletID(intentID string, position int) string {
	return fmt.Sprintf("%s-b%d", intentID, position)
}

func bulletStatusesOf(t *testing.T, st *Store, intentID string) []string {
	t.Helper()
	bullets, err := st.ListBulletsForIntent(intentID)
	if err != nil {
		t.Fatalf("listing bullets of %s: %v", intentID, err)
	}
	out := make([]string, 0, len(bullets))
	for _, b := range bullets {
		out = append(out, b.Status)
	}
	return out
}

func intentStatusOf(t *testing.T, st *Store, intentID string) string {
	t.Helper()
	intent, err := st.GetIntent(intentID)
	if err != nil {
		t.Fatalf("loading intent %s: %v", intentID, err)
	}
	return intent.Status
}

// The defect this change fixes: a run reaching a terminal status left every one
// of its bullets in the state the dispatch wrote, forever.
func TestAdvanceBulletsForRunMovesEveryBulletOfThatRunsIntent(t *testing.T) {
	st, _ := openTestStore(t)
	seedIntentRun(t, st, "run-a", "intent-a", "in_progress", "pending", "pending", "pending")

	if err := st.AdvanceBulletsForRun("run-a", "green", ""); err != nil {
		t.Fatalf("advancing bullets: %v", err)
	}

	for i, got := range bulletStatusesOf(t, st, "intent-a") {
		if got != "green" {
			t.Errorf("bullet %d status = %q, want green", i+1, got)
		}
	}
}

// A resumed run reaches the terminal path a second time. Advancing to the status
// a bullet already holds must neither error nor rewrite the row: rewriting would
// bump updated_at and publish a transition event for a transition that did not
// happen.
func TestAdvanceBulletsForRunIsIdempotent(t *testing.T) {
	st, _ := openTestStore(t)
	seedIntentRun(t, st, "run-b", "intent-b", "in_progress", "pending", "pending")

	if err := st.AdvanceBulletsForRun("run-b", "green", ""); err != nil {
		t.Fatalf("first advance: %v", err)
	}
	first, err := st.ListBulletsForIntent("intent-b")
	if err != nil {
		t.Fatal(err)
	}
	seqAfterFirst, err := st.CurrentSequence()
	if err != nil {
		t.Fatal(err)
	}

	// The clock has to move, so an unwanted rewrite would be visible.
	time.Sleep(10 * time.Millisecond)

	if err := st.AdvanceBulletsForRun("run-b", "green", ""); err != nil {
		t.Fatalf("second advance returned an error: %v", err)
	}

	second, err := st.ListBulletsForIntent("intent-b")
	if err != nil {
		t.Fatal(err)
	}
	for i := range second {
		if second[i].Status != "green" {
			t.Errorf("bullet %d status = %q after a second advance, want green", i+1, second[i].Status)
		}
		if !second[i].UpdatedAt.Equal(first[i].UpdatedAt) {
			t.Errorf("bullet %d updated_at moved on a no-op advance: %v became %v",
				i+1, first[i].UpdatedAt, second[i].UpdatedAt)
		}
	}

	seqAfterSecond, err := st.CurrentSequence()
	if err != nil {
		t.Fatal(err)
	}
	if seqAfterSecond != seqAfterFirst {
		t.Errorf("a no-op advance appended %d change event(s); a transition that did not happen must not be announced",
			seqAfterSecond-seqAfterFirst)
	}
}

// Runs written before a dispatch persisted its intent carry an empty intent id.
// Empty means "no intent was recorded", so there is nothing to advance — and
// nothing to error about either.
func TestAdvanceBulletsForARunWithNoIntentIsANoOp(t *testing.T) {
	st, _ := openTestStore(t)
	if err := st.CreateRun(&RunRecord{ID: "run-c", Project: "p", TaskID: "run-c", Status: "running"}); err != nil {
		t.Fatal(err)
	}

	if err := st.AdvanceBulletsForRun("run-c", "green", ""); err != nil {
		t.Errorf("advancing a run with no intent = %v, want nil", err)
	}
}

// Advancing bullets for a run the store has never seen is a caller error, not a
// silent success: reporting nil would let executeRun believe it had moved work.
func TestAdvanceBulletsForAnUnknownRunIsAnError(t *testing.T) {
	st, _ := openTestStore(t)
	if err := st.AdvanceBulletsForRun("no-such-run", "green", ""); err == nil {
		t.Error("expected an error advancing the bullets of an unknown run")
	}
}

// The derivation is a pure reading of the bullets, so it is asserted without a
// database. "satisfied" is reachable from exactly one input: every bullet merged.
func TestDeriveIntentStatusReadsTheBullets(t *testing.T) {
	cases := []struct {
		name     string
		statuses []string
		want     string
	}{
		// An intent with no bullets has had no work done against it. The rule
		// "every bullet is merged" is vacuously true for an empty set, so the
		// empty case is answered before the rule is applied.
		{"no bullets at all", nil, "in_progress"},
		{"one pending bullet", []string{"pending"}, "in_progress"},
		{"every bullet green", []string{"green", "green"}, "in_progress"},
		{"every bullet sealed", []string{"sealed", "sealed"}, "in_progress"},
		{"one merged and one pending", []string{"merged", "pending"}, "in_progress"},
		{"one merged and one green", []string{"merged", "green"}, "in_progress"},
		{"one merged and one failed", []string{"merged", "failed"}, "in_progress"},
		{"every bullet merged", []string{"merged", "merged", "merged"}, "satisfied"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			bullets := make([]BulletRecord, 0, len(tc.statuses))
			for _, s := range tc.statuses {
				bullets = append(bullets, BulletRecord{Status: s})
			}
			if got := DeriveIntentStatus(bullets); got != tc.want {
				t.Errorf("DeriveIntentStatus(%v) = %q, want %q", tc.statuses, got, tc.want)
			}
		})
	}
}

// AllBulletsSealedOrMerged answers a different question than DeriveIntentStatus:
// whether an intent's bullets are all at least at sealed, the condition that
// makes the intent a candidate for its shipping gate. Asserted without a
// database, the same reasoning as TestDeriveIntentStatusReadsTheBullets.
//
// Scenario: "An intent with some bullets not yet sealed has no shipping-gate
// status" and "An intent with all bullets sealed evaluates its shipping gate"
// (specs/shipping-gate/spec.md).
func TestAllBulletsSealedOrMerged(t *testing.T) {
	cases := []struct {
		name     string
		statuses []string
		want     bool
	}{
		// Unlike DeriveIntentStatus, the empty case must be false: a vacuous
		// true here would make an intent with no bullets at all a candidate
		// for a shipping gate it never earned.
		{"no bullets at all", nil, false},
		{"mix of pending, red, green, and sealed", []string{"pending", "red", "green", "sealed"}, false},
		{"one bullet still green", []string{"sealed", "green"}, false},
		{"every bullet sealed", []string{"sealed", "sealed"}, true},
		{"sealed and merged mix", []string{"sealed", "merged"}, true},
		{"every bullet merged", []string{"merged", "merged"}, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			bullets := make([]BulletRecord, 0, len(tc.statuses))
			for _, s := range tc.statuses {
				bullets = append(bullets, BulletRecord{Status: s})
			}
			if got := AllBulletsSealedOrMerged(bullets); got != tc.want {
				t.Errorf("AllBulletsSealedOrMerged(%v) = %v, want %v", tc.statuses, got, tc.want)
			}
		})
	}
}

// Scenario: "A failed shipping gate records which check failed"
// (specs/shipping-gate/spec.md). The reason must name the check that failed,
// mirroring how BulletRecord.BlockedReason already carries a human-readable
// explanation.
func TestRecordShippingGateResultRecordsFailureReason(t *testing.T) {
	st, _ := openTestStore(t)
	const intentID = "intent-sg-fail"
	if err := st.CreateIntent(&IntentRecord{ID: intentID, Project: "p", Statement: "s", Status: "approved"}); err != nil {
		t.Fatalf("creating intent: %v", err)
	}

	if err := st.RecordShippingGateResult(intentID, false, `shipping gate "security" failed`); err != nil {
		t.Fatalf("RecordShippingGateResult: %v", err)
	}

	intent, err := st.GetIntent(intentID)
	if err != nil {
		t.Fatalf("loading intent: %v", err)
	}
	if intent.ShippingGateStatus != "failed" {
		t.Errorf("ShippingGateStatus = %q, want %q", intent.ShippingGateStatus, "failed")
	}
	if !strings.Contains(intent.ShippingGateReason, "security") {
		t.Errorf("ShippingGateReason = %q, want it to name the failed check", intent.ShippingGateReason)
	}
}

// Scenario: "A passing shipping gate records no reason" (specs/shipping-gate/
// spec.md). A pass must overwrite any previously stored reason with empty,
// matching BlockedReason's "empty unless the status warrants one" rule.
func TestRecordShippingGateResultPassRecordsNoReason(t *testing.T) {
	st, _ := openTestStore(t)
	const intentID = "intent-sg-pass"
	if err := st.CreateIntent(&IntentRecord{ID: intentID, Project: "p", Statement: "s", Status: "approved"}); err != nil {
		t.Fatalf("creating intent: %v", err)
	}

	if err := st.RecordShippingGateResult(intentID, false, "stale failure reason"); err != nil {
		t.Fatalf("RecordShippingGateResult(fail): %v", err)
	}
	if err := st.RecordShippingGateResult(intentID, true, "ignored"); err != nil {
		t.Fatalf("RecordShippingGateResult(pass): %v", err)
	}

	intent, err := st.GetIntent(intentID)
	if err != nil {
		t.Fatalf("loading intent: %v", err)
	}
	if intent.ShippingGateStatus != "passed" {
		t.Errorf("ShippingGateStatus = %q, want %q", intent.ShippingGateStatus, "passed")
	}
	if intent.ShippingGateReason != "" {
		t.Errorf("ShippingGateReason = %q, want empty for a pass, even though a prior failure had stored one", intent.ShippingGateReason)
	}
}

// Intent status is a reading of the bullets, so recomputing must write whatever
// they currently say — in both directions.
func TestRecomputeIntentStatusWritesTheDerivedStatus(t *testing.T) {
	st, _ := openTestStore(t)
	seedIntentRun(t, st, "run-d", "intent-d", "in_progress", "merged", "merged")

	got, err := st.RecomputeIntentStatus("intent-d")
	if err != nil {
		t.Fatalf("recomputing: %v", err)
	}
	if got != "satisfied" {
		t.Errorf("RecomputeIntentStatus returned %q, want satisfied", got)
	}
	if stored := intentStatusOf(t, st, "intent-d"); stored != "satisfied" {
		t.Errorf("stored intent status = %q, want satisfied", stored)
	}

	// A bullet that leaves merged takes the intent back with it. The status is a
	// reading, not a latch.
	if err := st.UpdateBulletStatus(bulletID("intent-d", 2), "green"); err != nil {
		t.Fatal(err)
	}
	got, err = st.RecomputeIntentStatus("intent-d")
	if err != nil {
		t.Fatalf("recomputing: %v", err)
	}
	if got != "in_progress" {
		t.Errorf("RecomputeIntentStatus returned %q, want in_progress", got)
	}
	if stored := intentStatusOf(t, st, "intent-d"); stored != "in_progress" {
		t.Errorf("stored intent status = %q, want in_progress", stored)
	}
}

func TestRecomputeIntentStatusOnAnIntentWithNoBulletsIsInProgress(t *testing.T) {
	st, _ := openTestStore(t)
	if err := st.CreateIntent(&IntentRecord{
		ID: "intent-e", Project: "p", Statement: "s", Status: "in_progress",
	}); err != nil {
		t.Fatal(err)
	}

	got, err := st.RecomputeIntentStatus("intent-e")
	if err != nil {
		t.Fatalf("recomputing: %v", err)
	}
	if got != "in_progress" {
		t.Errorf("an intent with no bullets derived %q, want in_progress", got)
	}
	if stored := intentStatusOf(t, st, "intent-e"); stored != "in_progress" {
		t.Errorf("stored intent status = %q, want in_progress", stored)
	}
}

// Advancing bullets re-derives the intent from them, so the two can never state
// different things about the same work.
func TestAdvanceBulletsForRunRederivesTheIntent(t *testing.T) {
	st, _ := openTestStore(t)
	seedIntentRun(t, st, "run-f", "intent-f", "satisfied", "merged", "merged")

	if err := st.AdvanceBulletsForRun("run-f", "green", ""); err != nil {
		t.Fatalf("advancing bullets: %v", err)
	}
	if stored := intentStatusOf(t, st, "intent-f"); stored != "in_progress" {
		t.Errorf("intent status = %q after its bullets left merged, want in_progress", stored)
	}
}

func TestRecomputeIntentStatusOnAnUnknownIntentIsAnError(t *testing.T) {
	st, _ := openTestStore(t)
	if _, err := st.RecomputeIntentStatus("no-such-intent"); err == nil {
		t.Error("expected an error recomputing an unknown intent")
	}
}
