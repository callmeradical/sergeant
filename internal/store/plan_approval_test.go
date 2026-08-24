package store

import "testing"

// Decision D2: a plan awaiting approval is a bullet naming a repository but not
// yet authorized to start. It must sort before "pending" so the dashboard's
// lifecycle rendering shows it as the state before work begins, not after.
func TestBulletStatusesIncludesProposedBeforePending(t *testing.T) {
	statuses := BulletStatuses()
	if len(statuses) == 0 || statuses[0] != "proposed" {
		t.Fatalf("BulletStatuses() = %v, want \"proposed\" first", statuses)
	}
	proposedIdx, pendingIdx := -1, -1
	for i, s := range statuses {
		switch s {
		case "proposed":
			proposedIdx = i
		case "pending":
			pendingIdx = i
		}
	}
	if proposedIdx == -1 {
		t.Fatalf("BulletStatuses() = %v, missing \"proposed\"", statuses)
	}
	if pendingIdx == -1 {
		t.Fatalf("BulletStatuses() = %v, missing \"pending\"", statuses)
	}
	if proposedIdx >= pendingIdx {
		t.Errorf("\"proposed\" is at index %d, \"pending\" at %d; proposed must come first", proposedIdx, pendingIdx)
	}
}

// A fresh slice must be returned on every call, matching every other caller of
// this function, so a caller mutating its copy cannot corrupt another's.
func TestBulletStatusesReturnsAFreshSliceEachCall(t *testing.T) {
	a := BulletStatuses()
	a[0] = "corrupted"
	b := BulletStatuses()
	if b[0] != "proposed" {
		t.Errorf("BulletStatuses() second call = %v, want unaffected by mutation of the first", b)
	}
}

// ListIntentsByStatus is how a plan awaiting approval is found: an intent like
// any other, distinguished only by its status.
func TestListIntentsByStatusReturnsOnlyMatchingIntents(t *testing.T) {
	st, _ := openTestStore(t)

	proposed1 := &IntentRecord{ID: "intent-proposed-1", Project: "payments", Statement: "first plan", Status: "proposed"}
	proposed2 := &IntentRecord{ID: "intent-proposed-2", Project: "payments", Statement: "second plan", Status: "proposed"}
	inProgress := &IntentRecord{ID: "intent-active", Project: "payments", Statement: "already running", Status: "in_progress"}
	abandoned := &IntentRecord{ID: "intent-abandoned", Project: "payments", Statement: "rejected plan", Status: "abandoned"}
	for _, i := range []*IntentRecord{proposed1, proposed2, inProgress, abandoned} {
		if err := st.CreateIntent(i); err != nil {
			t.Fatalf("failed to create intent %s: %v", i.ID, err)
		}
	}

	got, err := st.ListIntentsByStatus("proposed")
	if err != nil {
		t.Fatalf("ListIntentsByStatus failed: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("got %d proposed intents, want 2: %+v", len(got), got)
	}
	ids := map[string]bool{}
	for _, i := range got {
		ids[i.ID] = true
		if i.Status != "proposed" {
			t.Errorf("intent %s status = %q, want proposed", i.ID, i.Status)
		}
	}
	if !ids["intent-proposed-1"] || !ids["intent-proposed-2"] {
		t.Errorf("ListIntentsByStatus(\"proposed\") = %+v, missing an expected intent", got)
	}

	none, err := st.ListIntentsByStatus("satisfied")
	if err != nil {
		t.Fatalf("ListIntentsByStatus failed: %v", err)
	}
	if len(none) != 0 {
		t.Errorf("ListIntentsByStatus(\"satisfied\") = %+v, want empty", none)
	}
}
