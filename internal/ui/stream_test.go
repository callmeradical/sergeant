package ui

import (
	"bufio"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/callmeradical/sergeant/internal/store"
)

// Requirement: clients follow state by ordered sequence rather than polling.
//
// These tests exercise the wire, not the internals: a real HTTP connection to
// GET /api/stream, read as Server-Sent Events. The dashboard is the only
// consumer that matters and it sees exactly this.

// ---- fixture -----------------------------------------------------------------

// streamFixture returns a live server, its store, and the database path. The
// path is returned so a test can prune change history directly: the store
// deliberately exposes no prune, and "a sequence the server no longer holds" is
// a state the schema permits whether or not application code creates it.
func streamFixture(t *testing.T) (*httptest.Server, *store.Store, string) {
	t.Helper()
	base := t.TempDir()
	t.Setenv("SERGEANT_FLEET_DIR", filepath.Join(base, "fleet"))

	dbPath := filepath.Join(base, "t.db")
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	srv := httptest.NewServer(NewServer(st, 0).Handler())
	t.Cleanup(srv.Close)
	return srv, st, dbPath
}

type sseEvent struct {
	Event string
	ID    string
	Data  string
}

// openStream subscribes to /api/stream and decodes the response as SSE. The
// returned channel yields complete events; the cancel func closes the request.
func openStream(t *testing.T, srv *httptest.Server, query string) (<-chan sseEvent, func()) {
	t.Helper()

	ctx, cancel := context.WithCancel(context.Background())
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, srv.URL+"/api/stream"+query, nil)
	if err != nil {
		cancel()
		t.Fatal(err)
	}
	res, err := srv.Client().Do(req)
	if err != nil {
		cancel()
		t.Fatalf("subscribing to /api/stream%s: %v", query, err)
	}
	if res.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(res.Body)
		res.Body.Close()
		cancel()
		t.Fatalf("GET /api/stream%s = %d, want 200; body=%s", query, res.StatusCode, body)
	}
	if ct := res.Header.Get("Content-Type"); !strings.HasPrefix(ct, "text/event-stream") {
		res.Body.Close()
		cancel()
		t.Fatalf("Content-Type = %q, want text/event-stream", ct)
	}

	events := make(chan sseEvent, 256)
	go func() {
		defer close(events)
		defer res.Body.Close()
		sc := bufio.NewScanner(res.Body)
		sc.Buffer(make([]byte, 0, 64*1024), 8*1024*1024)
		var ev sseEvent
		for sc.Scan() {
			line := sc.Text()
			switch {
			case line == "":
				if ev.Event != "" || ev.Data != "" {
					events <- ev
				}
				ev = sseEvent{}
			case strings.HasPrefix(line, ":"):
				// A comment. Heartbeats keep an idle connection open and carry no
				// state, so they are deliberately not surfaced as events.
			case strings.HasPrefix(line, "event:"):
				ev.Event = strings.TrimSpace(strings.TrimPrefix(line, "event:"))
			case strings.HasPrefix(line, "id:"):
				ev.ID = strings.TrimSpace(strings.TrimPrefix(line, "id:"))
			case strings.HasPrefix(line, "data:"):
				ev.Data = strings.TrimSpace(strings.TrimPrefix(line, "data:"))
			}
		}
	}()

	stop := func() {
		cancel()
		for range events { //nolint:revive // drain so the reader goroutine exits
		}
	}
	t.Cleanup(stop)
	return events, stop
}

func nextEvent(t *testing.T, events <-chan sseEvent) sseEvent {
	t.Helper()
	select {
	case ev, ok := <-events:
		if !ok {
			t.Fatal("the stream closed before delivering another event")
		}
		return ev
	case <-time.After(10 * time.Second):
		t.Fatal("timed out waiting for a stream event")
	}
	return sseEvent{}
}

// appendRunChanges appends n run changes and returns their sequence numbers.
func appendRunChanges(t *testing.T, st *store.Store, n int) []int64 {
	t.Helper()
	var seqs []int64
	for i := 0; i < n; i++ {
		seq, err := st.AppendChange(store.ChannelRun, fmt.Sprintf("sgt-%d", i), map[string]int{"i": i})
		if err != nil {
			t.Fatal(err)
		}
		seqs = append(seqs, seq)
	}
	return seqs
}

// ---- scenarios ---------------------------------------------------------------

// Scenario: A subscription from a sequence excludes that sequence.
func TestStreamFromASequenceReplaysOnlyWhatFollowsIt(t *testing.T) {
	srv, st, _ := streamFixture(t)
	seqs := appendRunChanges(t, st, 4)
	from := seqs[1]

	events, _ := openStream(t, srv, fmt.Sprintf("?from=%d", from))

	for _, want := range []int64{seqs[2], seqs[3]} {
		ev := nextEvent(t, events)
		if ev.Event != "change" {
			t.Fatalf("event = %q, want change; a replayable cursor must not be answered with %q (data=%s)",
				ev.Event, ev.Event, ev.Data)
		}
		var c store.ChangeRecord
		if err := json.Unmarshal([]byte(ev.Data), &c); err != nil {
			t.Fatalf("decoding change event %s: %v", ev.Data, err)
		}
		if c.Seq != want {
			t.Fatalf("replay delivered seq %d, want %d; from=%d", c.Seq, want, from)
		}
		if c.Seq <= from {
			t.Errorf("replay delivered seq %d, which is at or before the requested %d", c.Seq, from)
		}
		if ev.ID != fmt.Sprintf("%d", c.Seq) {
			t.Errorf("event id = %q, want %d; without it a reconnect cannot resume", ev.ID, c.Seq)
		}
	}
}

// Scenario: An unknown sequence yields a snapshot, not an error.
func TestStreamAnswersASequenceAheadOfTheMaximumWithASnapshot(t *testing.T) {
	srv, st, _ := streamFixture(t)
	seqs := appendRunChanges(t, st, 3)
	current := seqs[len(seqs)-1]

	events, _ := openStream(t, srv, fmt.Sprintf("?from=%d", current+500))

	ev := nextEvent(t, events)
	if ev.Event != "snapshot" {
		t.Fatalf("event = %q, want snapshot; a sequence the server never assigned must not be an error (data=%s)",
			ev.Event, ev.Data)
	}
	var snap struct {
		Seq  int64             `json:"seq"`
		Runs []store.RunRecord `json:"runs"`
	}
	if err := json.Unmarshal([]byte(ev.Data), &snap); err != nil {
		t.Fatalf("decoding snapshot %s: %v", ev.Data, err)
	}
	if snap.Seq != current {
		t.Errorf("snapshot carries seq %d, want the current %d", snap.Seq, current)
	}
	if snap.Runs == nil {
		t.Error("snapshot carries no runs array; a client cannot apply an absent snapshot wholesale")
	}
}

// Scenario: An unknown sequence yields a snapshot — the pruned-history case.
//
// A client returning after the rows it needs were deleted must be caught up, not
// silently handed an incomplete replay.
func TestStreamAnswersAPrunedSequenceWithASnapshot(t *testing.T) {
	srv, st, dbPath := streamFixture(t)
	seqs := appendRunChanges(t, st, 3)

	// Prune everything below the newest row, then resume from before the gap.
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`DELETE FROM changes WHERE seq < ?`, seqs[2]); err != nil {
		db.Close()
		t.Fatal(err)
	}
	db.Close()

	events, _ := openStream(t, srv, "?from=1")
	ev := nextEvent(t, events)
	if ev.Event != "snapshot" {
		t.Fatalf("event = %q, want snapshot; the changes between the cursor and the oldest retained row are gone (data=%s)",
			ev.Event, ev.Data)
	}
}

// A client that has seen nothing gets a snapshot. The log holds transitions, so
// replaying it from zero would not describe a run recorded before it existed.
func TestStreamWithoutAFromSendsASnapshot(t *testing.T) {
	srv, st, _ := streamFixture(t)
	run := &store.RunRecord{ID: "sgt-known", Project: "p", TaskID: "sgt-known", Status: "running"}
	if err := st.CreateRun(run); err != nil {
		t.Fatal(err)
	}

	events, _ := openStream(t, srv, "")

	ev := nextEvent(t, events)
	if ev.Event != "snapshot" {
		t.Fatalf("event = %q, want snapshot (data=%s)", ev.Event, ev.Data)
	}
	var snap struct {
		Seq  int64             `json:"seq"`
		Runs []store.RunRecord `json:"runs"`
	}
	if err := json.Unmarshal([]byte(ev.Data), &snap); err != nil {
		t.Fatal(err)
	}
	var found bool
	for _, r := range snap.Runs {
		if r.ID == "sgt-known" {
			found = true
		}
	}
	if !found {
		t.Errorf("snapshot omits the stored run; runs=%+v", snap.Runs)
	}
	if snap.Seq <= 0 {
		t.Errorf("snapshot carries seq %d; a client cannot resume from it", snap.Seq)
	}
}

// The stream is a live feed, not a one-shot replay: a change appended while a
// client is connected reaches it without the client asking again.
func TestStreamDeliversChangesAppendedWhileConnected(t *testing.T) {
	srv, st, _ := streamFixture(t)
	if err := st.CreateRun(&store.RunRecord{ID: "sgt-live", Project: "p", TaskID: "sgt-live", Status: "running"}); err != nil {
		t.Fatal(err)
	}

	events, _ := openStream(t, srv, "")
	snap := nextEvent(t, events)
	if snap.Event != "snapshot" {
		t.Fatalf("first event = %q, want snapshot", snap.Event)
	}

	if err := st.UpdateRunStatus("sgt-live", "passed"); err != nil {
		t.Fatal(err)
	}

	ev := nextEvent(t, events)
	if ev.Event != "change" {
		t.Fatalf("event = %q, want change (data=%s)", ev.Event, ev.Data)
	}
	var c store.ChangeRecord
	if err := json.Unmarshal([]byte(ev.Data), &c); err != nil {
		t.Fatal(err)
	}
	if c.Channel != store.ChannelRun || c.EntityID != "sgt-live" {
		t.Errorf("change = %s/%s, want run/sgt-live", c.Channel, c.EntityID)
	}
}

// A reconnecting EventSource sends Last-Event-ID rather than a new ?from. It must
// be honoured, or every reconnect would replay from the sequence the page loaded
// with and re-deliver everything since.
func TestStreamHonoursLastEventIDOverTheQueryString(t *testing.T) {
	srv, st, _ := streamFixture(t)
	seqs := appendRunChanges(t, st, 4)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, srv.URL+"/api/stream?from=1", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Last-Event-ID", fmt.Sprintf("%d", seqs[2]))
	res, err := srv.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()

	sc := bufio.NewScanner(res.Body)
	var firstData string
	for sc.Scan() {
		if strings.HasPrefix(sc.Text(), "data:") {
			firstData = strings.TrimSpace(strings.TrimPrefix(sc.Text(), "data:"))
			break
		}
	}
	var c store.ChangeRecord
	if err := json.Unmarshal([]byte(firstData), &c); err != nil {
		t.Fatalf("decoding %q: %v", firstData, err)
	}
	if c.Seq != seqs[3] {
		t.Errorf("first replayed seq = %d, want %d; Last-Event-ID was ignored in favour of ?from=1",
			c.Seq, seqs[3])
	}
}

// The records a dispatch writes must all reach a subscriber. Task 1 made a
// dispatch persist an intent and one bullet per target repository; a stream that
// carried only the run would leave the dashboard's primary noun (decision D8)
// invisible until something re-read the world.
func TestADispatchAppearsOnTheStreamAsARunAnIntentAndItsBullets(t *testing.T) {
	mux, _, repoPaths, _ := dispatchFixtureRepos(t, "alpha", "beta")
	const changeID = "add-stripe-webhooks"
	for _, p := range repoPaths {
		if err := os.MkdirAll(filepath.Join(p, "openspec", "changes", changeID), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	live := httptest.NewServer(mux)
	t.Cleanup(live.Close)

	// Subscribe first, so the dispatch's transitions arrive as changes rather than
	// having to be recovered from a snapshot. The store is empty, so the
	// subscription opens with a snapshot of nothing at sequence zero.
	events, _ := openStream(t, live, "")
	if opening := nextEvent(t, events); opening.Event != "snapshot" {
		t.Fatalf("first event = %q, want snapshot (data=%s)", opening.Event, opening.Data)
	}

	res := postDispatch(t, mux, dispatchBody(t, map[string]interface{}{
		"project": "o3", "brief": "add stripe webhooks", "change_id": changeID,
		"repos": []string{"alpha", "beta"},
	}))
	if res.Code != http.StatusOK {
		t.Fatalf("dispatch = %d, want 200; body=%s", res.Code, res.Body.String())
	}

	seen := map[string]int{}
	var lastSeq int64
	// Bounded: the run also records phases and a terminal status, so this reads
	// until it has the four domain transitions rather than until the stream idles.
	for i := 0; i < 40; i++ {
		ev := nextEvent(t, events)
		if ev.Event != "change" {
			t.Fatalf("event = %q, want change (data=%s)", ev.Event, ev.Data)
		}
		var c store.ChangeRecord
		if err := json.Unmarshal([]byte(ev.Data), &c); err != nil {
			t.Fatal(err)
		}
		if c.Seq <= lastSeq {
			t.Fatalf("seq %d arrived after %d; the stream is not ascending", c.Seq, lastSeq)
		}
		lastSeq = c.Seq
		seen[c.Channel]++
		if seen[store.ChannelRun] >= 1 && seen[store.ChannelIntent] >= 1 && seen[store.ChannelBullet] >= 2 {
			break
		}
	}

	if seen[store.ChannelRun] < 1 {
		t.Errorf("the stream carried no run change; channels seen = %v", seen)
	}
	if seen[store.ChannelIntent] < 1 {
		t.Errorf("the stream carried no intent change; channels seen = %v", seen)
	}
	if seen[store.ChannelBullet] < 2 {
		t.Errorf("the stream carried %d bullet changes for 2 target repositories; channels seen = %v",
			seen[store.ChannelBullet], seen)
	}
}

// ---- the dashboard -----------------------------------------------------------

// Scenario: An idle dashboard issues no repeated re-reads.
//
// setInterval(..., 2000) guaranteed thirty full re-reads of the run list per
// minute per connected browser. The assertion is on the embedded asset because
// that is what is actually served.
func TestTheDashboardDoesNotPollOnATimer(t *testing.T) {
	src := embeddedIndex(t)

	if strings.Contains(src, "setInterval(") {
		t.Error("index.html still calls setInterval; an idle dashboard would keep re-reading the run list")
	}
	if !strings.Contains(src, "new EventSource(") {
		t.Error("index.html does not open an EventSource; it cannot follow the sequenced stream")
	}
	if !strings.Contains(src, "/api/stream") {
		t.Error("index.html does not reference /api/stream")
	}
}

// The stream invalidates the view; the existing key-diff render path still draws
// it. This executes the subscription logic from the embedded asset under node, so
// the assertion is about the shipped JavaScript rather than about a description
// of it.
func TestTheDashboardAppliesStreamEventsThroughTheExistingRenderPath(t *testing.T) {
	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("node is not installed; cannot execute the embedded UI stream logic")
	}
	src := embeddedIndex(t)

	parts := []string{
		extractJSFunction(t, src, "scheduleRefresh"),
		extractJSFunction(t, src, "onStreamSnapshot"),
		extractJSFunction(t, src, "onStreamChange"),
		extractJSFunction(t, src, "subscribeToStream"),
	}

	harness := strings.Join(parts, "\n\n") + `

let lastSeq = 0;
let stream = null;
let refreshTimer = null;

const calls = { runs: 0, fleet: 0, intervals: 0, connectionErrors: 0 };
function fetchRuns() { calls.runs++; }
function fetchFleet() { calls.fleet++; }
function setConnectionError(isError) { if (isError) calls.connectionErrors++; }

globalThis.setInterval = () => { calls.intervals++; return 0; };
let pending = null;
globalThis.setTimeout = (fn) => { pending = fn; return 1; };
globalThis.clearTimeout = () => { pending = null; };

const opened = [];
class EventSource {
  constructor(url) { this.url = url; this.handlers = {}; this.closed = false; opened.push(this); }
  addEventListener(name, fn) { (this.handlers[name] = this.handlers[name] || []).push(fn); }
  close() { this.closed = true; }
  emit(name, payload) {
    (this.handlers[name] || []).forEach(fn => fn({ data: JSON.stringify(payload) }));
  }
}
globalThis.EventSource = EventSource;

subscribeToStream();
const es = opened[0];
es.emit('snapshot', { seq: 7, runs: [] });
es.emit('change', { seq: 8, channel: 'run', entity_id: 'sgt-1', payload: {} });
es.emit('change', { seq: 9, channel: 'phase', entity_id: 'p1', payload: { run_id: 'sgt-1' } });
if (pending) pending();

process.stdout.write(JSON.stringify({
  url: es.url,
  opened: opened.length,
  lastSeq: lastSeq,
  calls: calls
}));
`

	dir := t.TempDir()
	script := filepath.Join(dir, "stream.mjs")
	if err := os.WriteFile(script, []byte(harness), 0o644); err != nil {
		t.Fatal(err)
	}
	out, err := exec.Command(node, script).Output()
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			t.Fatalf("node failed: %v\n%s", err, ee.Stderr)
		}
		t.Fatalf("node failed: %v", err)
	}

	var got struct {
		URL     string `json:"url"`
		Opened  int    `json:"opened"`
		LastSeq int64  `json:"lastSeq"`
		Calls   struct {
			Runs      int `json:"runs"`
			Fleet     int `json:"fleet"`
			Intervals int `json:"intervals"`
		} `json:"calls"`
	}
	if err := json.Unmarshal(out, &got); err != nil {
		t.Fatalf("decoding harness output %s: %v", out, err)
	}

	if got.Opened != 1 {
		t.Errorf("opened %d EventSources, want 1", got.Opened)
	}
	if !strings.HasPrefix(got.URL, "/api/stream") {
		t.Errorf("subscribed to %q, want /api/stream", got.URL)
	}
	if got.Calls.Intervals != 0 {
		t.Errorf("the subscription armed %d intervals; following the stream must retire the polling loop",
			got.Calls.Intervals)
	}
	if got.LastSeq != 9 {
		t.Errorf("lastSeq = %d after applying seq 9, want 9; a reconnect would ask for the wrong cursor",
			got.LastSeq)
	}
	// Three events in one burst must not cause three full re-reads.
	if got.Calls.Runs != 1 || got.Calls.Fleet != 1 {
		t.Errorf("a burst of 3 events caused %d run re-reads and %d fleet re-reads, want 1 and 1",
			got.Calls.Runs, got.Calls.Fleet)
	}
}

func embeddedIndex(t *testing.T) string {
	t.Helper()
	raw, err := staticFS.ReadFile("static/index.html")
	if err != nil {
		t.Fatalf("read embedded index.html: %v", err)
	}
	return string(raw)
}
