package store

import "testing"

// SetBulletPRURL is handleCreatePR's write path for persisting a change
// request's identity onto the bullet itself (specs/change-request-merge/
// spec.md: "A successfully opened change request is readable from the
// bullet afterward").
func TestSetBulletPRURLIsReadableFromGetBullet(t *testing.T) {
	st, _ := openTestStore(t)

	const intentID = "intent-pr-1"
	if err := st.CreateIntent(&IntentRecord{ID: intentID, Project: "p", Statement: "s", Status: "approved"}); err != nil {
		t.Fatal(err)
	}
	const bulletID = "bullet-pr-1"
	if err := st.CreateBullet(&BulletRecord{ID: bulletID, IntentID: intentID, Repo: "svc", Position: 1, Status: "sealed"}); err != nil {
		t.Fatal(err)
	}

	const url = "https://github.com/example/repo/pull/7"
	if err := st.SetBulletPRURL(bulletID, url); err != nil {
		t.Fatalf("SetBulletPRURL: %v", err)
	}

	got, err := st.GetBullet(bulletID)
	if err != nil {
		t.Fatal(err)
	}
	if got.PRURL != url {
		t.Errorf("GetBullet.PRURL = %q, want %q", got.PRURL, url)
	}
}

// SetBulletPRURL reports an error for an id that names no bullet, the same
// convention UpdateBulletStatus follows — a silent no-op would let a caller
// believe it had recorded a URL that was never written.
func TestSetBulletPRURLOnUnknownBulletIsAnError(t *testing.T) {
	st, _ := openTestStore(t)
	if err := st.SetBulletPRURL("no-such-bullet", "https://example.com/pr/1"); err == nil {
		t.Error("SetBulletPRURL on an unknown bullet id = nil error, want an error")
	}
}
