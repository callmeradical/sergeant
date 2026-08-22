package store

import (
	"database/sql"
	"encoding/json"
	"path/filepath"
	"testing"
	"time"
)

// Requirement: clients follow state by ordered sequence rather than polling.
//
// Decision D10 adopts the subscribe/snapshot/replay model from AHP. These tests
// pin the half of it that lives in the store: an append-only sequence that
// strictly increases, never reuses a value, and can be read from a cursor.

func changeStore(t *testing.T) (*Store, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "changes.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s, path
}

// appendN appends n changes on one channel and returns their sequence numbers.
func appendN(t *testing.T, s *Store, channel string, n int) []int64 {
	t.Helper()
	var seqs []int64
	for i := 0; i < n; i++ {
		seq, err := s.AppendChange(channel, "e", map[string]int{"i": i})
		if err != nil {
			t.Fatalf("appending change %d: %v", i, err)
		}
		seqs = append(seqs, seq)
	}
	return seqs
}

// Scenario: Sequence numbers strictly increase.
func TestChangeSequenceNumbersStrictlyIncrease(t *testing.T) {
	s, _ := changeStore(t)

	seqs := appendN(t, s, ChannelRun, 5)

	for i := 1; i < len(seqs); i++ {
		if seqs[i] <= seqs[i-1] {
			t.Errorf("change %d was assigned seq %d, which is not greater than the previous %d; seqs=%v",
				i, seqs[i], seqs[i-1], seqs)
		}
	}

	// The same order must be observable on read, not only on write.
	got, err := s.ListChangesSince(0, 100)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != len(seqs) {
		t.Fatalf("read back %d changes, want %d", len(got), len(seqs))
	}
	for i := 1; i < len(got); i++ {
		if got[i].Seq <= got[i-1].Seq {
			t.Errorf("read order is not ascending at %d: %d then %d", i, got[i-1].Seq, got[i].Seq)
		}
	}
}

// Scenario: Sequence numbers strictly increase — "the sequence must not reuse a
// value after a delete".
//
// The delete is issued against the database file directly rather than through a
// store method. The guarantee being asserted is a property of the schema
// (INTEGER PRIMARY KEY AUTOINCREMENT), so the test must not be able to satisfy
// itself through application code that happens to keep a counter.
func TestASequenceNumberIsNotReusedAfterADelete(t *testing.T) {
	s, path := changeStore(t)

	before := appendN(t, s, ChannelRun, 3)
	highest := before[len(before)-1]

	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`DELETE FROM changes`); err != nil {
		db.Close()
		t.Fatalf("deleting the change history: %v", err)
	}
	db.Close()

	after, err := s.AppendChange(ChannelRun, "e", map[string]string{"after": "delete"})
	if err != nil {
		t.Fatal(err)
	}
	if after <= highest {
		t.Errorf("after deleting the history a change was assigned seq %d, reusing or regressing below %d; replay would be ambiguous",
			after, highest)
	}

	// The reported current sequence must not regress either. A client told the
	// current sequence is 1 when 4 has already been assigned would wait for
	// changes that can never arrive.
	current, err := s.CurrentSequence()
	if err != nil {
		t.Fatal(err)
	}
	if current < after {
		t.Errorf("CurrentSequence() = %d after seq %d was assigned; it must never name a sequence below one already assigned",
			current, after)
	}
}

// Scenario: A subscription from a sequence excludes that sequence.
func TestASubscriptionFromASequenceExcludesThatSequenceAndEverythingBefore(t *testing.T) {
	s, _ := changeStore(t)

	seqs := appendN(t, s, ChannelRun, 4)
	from := seqs[1]

	got, err := s.ListChangesSince(from, 100)
	if err != nil {
		t.Fatal(err)
	}

	if len(got) != 2 {
		t.Fatalf("subscribing from %d yielded %d changes, want the 2 after it; got=%+v", from, len(got), got)
	}
	for _, c := range got {
		if c.Seq <= from {
			t.Errorf("subscribing from %d delivered seq %d, which is at or before it", from, c.Seq)
		}
	}
	if got[0].Seq != seqs[2] || got[1].Seq != seqs[3] {
		t.Errorf("subscribing from %d delivered %d then %d, want %d then %d",
			from, got[0].Seq, got[1].Seq, seqs[2], seqs[3])
	}
}

// Scenario: An unknown sequence yields a snapshot, not an error.
//
// The store answers the question the stream handler asks: can everything after
// this cursor still be replayed? A "no" is what makes the handler send a
// snapshot instead of failing.
func TestReplayIsRefusedForASequenceTheStoreCannotHonour(t *testing.T) {
	s, path := changeStore(t)
	seqs := appendN(t, s, ChannelRun, 3)
	current := seqs[len(seqs)-1]

	ok, err := s.CanReplayFrom(current - 1)
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Errorf("CanReplayFrom(%d) = false, but every change after it is still held", current-1)
	}

	// Never assigned: ahead of the current maximum.
	ok, err = s.CanReplayFrom(current + 99)
	if err != nil {
		t.Fatal(err)
	}
	if ok {
		t.Errorf("CanReplayFrom(%d) = true, but that sequence has never been assigned", current+99)
	}

	// A client that has seen nothing cannot be caught up by replay: the log holds
	// transitions, not the state of entities recorded before it existed.
	ok, err = s.CanReplayFrom(0)
	if err != nil {
		t.Fatal(err)
	}
	if ok {
		t.Error("CanReplayFrom(0) = true, but a client that has seen nothing needs a snapshot")
	}

	// No longer held: the history below the cursor has been pruned away.
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`DELETE FROM changes WHERE seq <= ?`, seqs[1]); err != nil {
		db.Close()
		t.Fatal(err)
	}
	db.Close()

	ok, err = s.CanReplayFrom(seqs[0] - 1)
	if err != nil {
		t.Fatal(err)
	}
	if ok {
		t.Errorf("CanReplayFrom(%d) = true, but the changes between it and the oldest retained row are gone",
			seqs[0]-1)
	}
}

// A subscriber learns that something was appended without polling the database.
// This is what lets the stream handler and an MCP wait react immediately instead
// of inventing an interval.
func TestASubscriberIsNotifiedWhenAChangeIsAppended(t *testing.T) {
	s, _ := changeStore(t)

	notify, unsubscribe := s.SubscribeChanges()
	defer unsubscribe()

	seq, err := s.AppendChange(ChannelRun, "sgt-1", map[string]string{"status": "running"})
	if err != nil {
		t.Fatal(err)
	}

	select {
	case <-notify:
	case <-time.After(2 * time.Second):
		t.Fatalf("no notification after appending seq %d", seq)
	}

	// Unsubscribing must stop delivery rather than leaving a channel to fill.
	unsubscribe()
	if _, err := s.AppendChange(ChannelRun, "sgt-1", map[string]string{"status": "passed"}); err != nil {
		t.Fatal(err)
	}
}

// Every run transition is appended. Without this a client that follows the
// sequence never learns a run finished, which is the whole point of the stream.
func TestEveryRunTransitionIsAppendedToTheSequence(t *testing.T) {
	s, _ := changeStore(t)

	run := &RunRecord{ID: "sgt-1", Project: "p", TaskID: "sgt-1", Status: "running"}
	if err := s.CreateRun(run); err != nil {
		t.Fatal(err)
	}
	afterCreate := changesOnChannel(t, s, ChannelRun)
	if len(afterCreate) != 1 {
		t.Fatalf("creating a run appended %d run changes, want 1: %+v", len(afterCreate), afterCreate)
	}
	if afterCreate[0].EntityID != "sgt-1" {
		t.Errorf("run change names entity %q, want sgt-1", afterCreate[0].EntityID)
	}

	if err := s.UpdateRunStatus("sgt-1", "passed"); err != nil {
		t.Fatal(err)
	}
	afterUpdate := changesOnChannel(t, s, ChannelRun)
	if len(afterUpdate) != 2 {
		t.Fatalf("a status transition appended %d run changes in total, want 2: %+v", len(afterUpdate), afterUpdate)
	}

	var payload struct {
		Status string `json:"status"`
	}
	if err := json.Unmarshal(afterUpdate[1].Payload, &payload); err != nil {
		t.Fatalf("decoding the transition payload: %v", err)
	}
	if payload.Status != "passed" {
		t.Errorf("transition payload status = %q, want passed", payload.Status)
	}
}

// Every intent and bullet transition is appended, for the same reason: decision
// D8 makes the intent the dashboard's primary noun, so a client that cannot see
// an intent move cannot render it.
func TestEveryIntentAndBulletTransitionIsAppendedToTheSequence(t *testing.T) {
	s, _ := changeStore(t)

	if err := s.CreateIntent(&IntentRecord{ID: "i1", Project: "p", Statement: "do it", Status: "in_progress"}); err != nil {
		t.Fatal(err)
	}
	if err := s.CreateBullet(&BulletRecord{ID: "i1-b1", IntentID: "i1", Repo: "svc", Position: 1, Status: "pending"}); err != nil {
		t.Fatal(err)
	}
	if err := s.UpdateIntentStatus("i1", "satisfied"); err != nil {
		t.Fatal(err)
	}
	if err := s.UpdateBulletStatus("i1-b1", "green"); err != nil {
		t.Fatal(err)
	}

	if got := changesOnChannel(t, s, ChannelIntent); len(got) != 2 {
		t.Errorf("intent channel holds %d changes, want 2 (created, satisfied): %+v", len(got), got)
	}
	if got := changesOnChannel(t, s, ChannelBullet); len(got) != 2 {
		t.Errorf("bullet channel holds %d changes, want 2 (created, green): %+v", len(got), got)
	}
}

// A phase record already bumps runs.updated_at, so it is a run transition. It
// gets its own channel so a client can refresh one run's detail without
// re-reading the whole list — the incremental update the polling loop could not
// express.
func TestAPhaseRecordIsAppendedToTheSequence(t *testing.T) {
	s, _ := changeStore(t)

	if err := s.CreateRun(&RunRecord{ID: "sgt-1", Project: "p", TaskID: "sgt-1", Status: "running"}); err != nil {
		t.Fatal(err)
	}
	if err := s.RecordPhase(&PhaseRecord{ID: "p1", RunID: "sgt-1", Repo: "svc", Name: "build", Kind: "agent", Status: "passed"}); err != nil {
		t.Fatal(err)
	}

	got := changesOnChannel(t, s, ChannelPhase)
	if len(got) != 1 {
		t.Fatalf("phase channel holds %d changes, want 1: %+v", len(got), got)
	}
	var payload struct {
		RunID  string `json:"run_id"`
		Name   string `json:"name"`
		Status string `json:"status"`
	}
	if err := json.Unmarshal(got[0].Payload, &payload); err != nil {
		t.Fatal(err)
	}
	if payload.RunID != "sgt-1" {
		t.Errorf("phase change payload run_id = %q, want sgt-1; a client cannot tell which run to refresh", payload.RunID)
	}
	if payload.Name != "build" || payload.Status != "passed" {
		t.Errorf("phase change payload = %+v, want build/passed", payload)
	}
}

// A refused idempotency key changed nothing, so it must append nothing. A change
// row for a write that did not happen would make a repeat look like a transition.
func TestADeduplicatedRunInsertAppendsNothing(t *testing.T) {
	s, _ := changeStore(t)

	first := &RunRecord{ID: "sgt-1", Project: "p", TaskID: "sgt-1", Status: "running", RequestID: "k"}
	if err := s.CreateRun(first); err != nil {
		t.Fatal(err)
	}
	before := changesOnChannel(t, s, ChannelRun)

	repeat := &RunRecord{ID: "sgt-2", Project: "p", TaskID: "sgt-2", Status: "running", RequestID: "k"}
	if err := s.CreateRun(repeat); err == nil {
		t.Fatal("a repeated request id was accepted; expected ErrDuplicateRequestID")
	}

	after := changesOnChannel(t, s, ChannelRun)
	if len(after) != len(before) {
		t.Errorf("a refused duplicate appended %d change(s); it changed nothing and must append nothing",
			len(after)-len(before))
	}
}

// A statement that matched nothing changed nothing. Announcing it would tell
// every subscriber that a run it cannot read had moved, which is the kind of
// claim the dashboard is forbidden to make.
func TestAStatementThatMatchedNoRunAppendsNothing(t *testing.T) {
	s, _ := changeStore(t)

	if err := s.UpdateRunStatus("sgt-ghost", "passed"); err != nil {
		t.Fatalf("relabelling an absent run returned %v; the contract is a silent no-op", err)
	}
	if err := s.DeleteRun("sgt-ghost"); err != nil {
		t.Fatal(err)
	}

	if got := changesOnChannel(t, s, ChannelRun); len(got) != 0 {
		t.Errorf("statements against an absent run appended %d changes, want 0: %+v", len(got), got)
	}
}

func changesOnChannel(t *testing.T, s *Store, channel string) []ChangeRecord {
	t.Helper()
	all, err := s.ListChangesSince(0, 1000)
	if err != nil {
		t.Fatal(err)
	}
	var out []ChangeRecord
	for _, c := range all {
		if c.Channel == channel {
			out = append(out, c)
		}
	}
	return out
}

// A wait needs one answer to "has this run finished?", and the store is the only
// place that knows. Two copies of the list would let an MCP wait block forever on
// a status the store considers terminal.
func TestTerminalRunStatusesAreNamedOnce(t *testing.T) {
	for _, status := range []string{"passed", "failed", "cancelled", "timed_out"} {
		if !IsTerminalRunStatus(status) {
			t.Errorf("IsTerminalRunStatus(%q) = false; a wait would block forever on it", status)
		}
	}
	for _, status := range []string{"running", "", "queued"} {
		if IsTerminalRunStatus(status) {
			t.Errorf("IsTerminalRunStatus(%q) = true; a wait would report an unfinished run as finished", status)
		}
	}
}
