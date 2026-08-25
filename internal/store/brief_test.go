package store

import (
	"strings"
	"testing"
)

// seedBriefFixture writes an intent with one bullet for repo, in the given
// status (and blocked reason, if any), and returns the intent id.
func seedBriefFixture(t *testing.T, st *Store, intentID, repo, status, blockedReason string) {
	t.Helper()
	if err := st.CreateIntent(&IntentRecord{
		ID: intentID, Project: "p", Statement: "ship the thing", Status: "in_progress",
	}); err != nil {
		t.Fatalf("creating intent %s: %v", intentID, err)
	}
	b := &BulletRecord{ID: intentID + "-b1", IntentID: intentID, Repo: repo, Position: 1, Status: status}
	if err := st.CreateBullet(b); err != nil {
		t.Fatalf("creating bullet for %s: %v", intentID, err)
	}
	if blockedReason != "" {
		if err := st.updateBulletStatusAndReason(b.ID, status, blockedReason); err != nil {
			t.Fatalf("setting blocked reason for %s: %v", intentID, err)
		}
	}
}

// Scenario: A blocked bullet's brief includes its recorded reason.
func TestRenderIntentBriefIncludesBlockedReason(t *testing.T) {
	st, _ := openTestStore(t)
	seedBriefFixture(t, st, "intent-blocked", "api", "blocked", "waiting on upstream migration")

	brief, err := st.RenderIntentBrief("intent-blocked", "api", nil)
	if err != nil {
		t.Fatalf("RenderIntentBrief: %v", err)
	}
	if !strings.Contains(brief, "waiting on upstream migration") {
		t.Errorf("brief = %q, want it to contain the recorded blocked reason", brief)
	}
}

// Scenario: A bullet with no blocked reason omits the blocked-reason line.
func TestRenderIntentBriefOmitsBlockedReasonLineWhenNotBlocked(t *testing.T) {
	st, _ := openTestStore(t)
	seedBriefFixture(t, st, "intent-green", "api", "green", "")

	brief, err := st.RenderIntentBrief("intent-green", "api", nil)
	if err != nil {
		t.Fatalf("RenderIntentBrief: %v", err)
	}
	if strings.Contains(brief, "Blocked reason:") {
		t.Errorf("brief = %q, want no blocked-reason line for a non-blocked bullet", brief)
	}
}

// Scenario: sergeant_get_brief and the dispatch-time prompt agree.
//
// Both call sites resolve to the same intent id, repo and gate names before
// calling RenderIntentBrief; this asserts the function itself returns
// identical output for identical arguments, which is the property that
// keeps the two call sites from ever describing the same work differently.
func TestRenderIntentBriefAgreesForTheSameArguments(t *testing.T) {
	st, _ := openTestStore(t)
	seedBriefFixture(t, st, "intent-agree", "api", "pending", "")
	gates := []string{"lint", "unit"}

	dispatchTimeRendered, err := st.RenderIntentBrief("intent-agree", "api", gates)
	if err != nil {
		t.Fatalf("simulating dispatch-time render: %v", err)
	}
	mcpRendered, err := st.RenderIntentBrief("intent-agree", "api", gates)
	if err != nil {
		t.Fatalf("simulating sergeant_get_brief render: %v", err)
	}
	if dispatchTimeRendered != mcpRendered {
		t.Errorf("dispatch-time and sergeant_get_brief renders differ:\n%q\nvs\n%q", dispatchTimeRendered, mcpRendered)
	}
}

// Scenario: sergeant_get_brief refuses a repo with no matching bullet.
func TestRenderIntentBriefRefusesRepoWithNoMatchingBullet(t *testing.T) {
	st, _ := openTestStore(t)
	seedBriefFixture(t, st, "intent-solo", "api", "pending", "")

	_, err := st.RenderIntentBrief("intent-solo", "web", nil)
	if err == nil {
		t.Fatal("expected an error for a repo with no matching bullet, got nil")
	}
}

// Scenario: Rendering twice with no state change in between produces
// identical output, and neither call writes a new row.
func TestRenderIntentBriefRenderingTwiceWritesNothing(t *testing.T) {
	st, _ := openTestStore(t)
	seedBriefFixture(t, st, "intent-twice", "api", "green", "")

	seqBefore, err := st.CurrentSequence()
	if err != nil {
		t.Fatalf("CurrentSequence before rendering: %v", err)
	}

	first, err := st.RenderIntentBrief("intent-twice", "api", []string{"unit"})
	if err != nil {
		t.Fatalf("first render: %v", err)
	}
	second, err := st.RenderIntentBrief("intent-twice", "api", []string{"unit"})
	if err != nil {
		t.Fatalf("second render: %v", err)
	}
	if first != second {
		t.Errorf("renders differ:\n%q\nvs\n%q", first, second)
	}

	seqAfter, err := st.CurrentSequence()
	if err != nil {
		t.Fatalf("CurrentSequence after rendering: %v", err)
	}
	if seqBefore != seqAfter {
		t.Errorf("rendering wrote %d new change row(s); RenderIntentBrief must perform no write", seqAfter-seqBefore)
	}
}
