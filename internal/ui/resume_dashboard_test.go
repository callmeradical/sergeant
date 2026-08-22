package ui

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/callmeradical/sergeant/internal/store"
)

// Change: resume-is-reachable-from-the-dashboard.
//
// POST /api/run-resume already exists and already refuses the wrong statuses.
// These tests cover the part that was missing: the dashboard offering the action
// for exactly the runs the server will accept, and refusing to maintain its own
// copy of that rule.

// servedRun is a run as the dashboard receives it. Only the fields these
// scenarios assert on are decoded; the rest of the record is unchanged.
type servedRun struct {
	ID        string `json:"id"`
	Status    string `json:"status"`
	Resumable bool   `json:"resumable"`
}

func getRecorded(t *testing.T, mux http.Handler, path string) *httptest.ResponseRecorder {
	t.Helper()
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
	return w
}

func servedRuns(t *testing.T, mux http.Handler) map[string]servedRun {
	t.Helper()
	w := getRecorded(t, mux, "/api/runs")
	if w.Code != http.StatusOK {
		t.Fatalf("GET /api/runs = %d, want 200; body=%s", w.Code, w.Body.String())
	}
	var list []servedRun
	if err := json.Unmarshal(w.Body.Bytes(), &list); err != nil {
		t.Fatalf("decoding the run list %s: %v", w.Body.String(), err)
	}
	byID := map[string]servedRun{}
	for _, r := range list {
		byID[r.ID] = r
	}
	return byID
}

// Scenario: the condition comes from the server, not a second list in the client.
//
// The expectation is derived from ResumableStatuses rather than restated, so
// adding a status to the endpoint's rule without serving it fails here instead of
// silently leaving the dashboard behind.
func TestServedRunPayloadSaysWhetherARunMayBeResumed(t *testing.T) {
	mux, st, _ := dispatchFixture(t)

	want := map[string]bool{"passed": false, "running": false}
	for _, s := range ResumableStatuses {
		want[s] = true
	}

	for status := range want {
		id := "sgt-" + status
		if err := st.CreateRun(&store.RunRecord{
			ID: id, Project: "o3", TaskID: id, Brief: "b", Status: status,
		}); err != nil {
			t.Fatal(err)
		}
	}

	got := servedRuns(t, mux)
	for status, resumable := range want {
		id := "sgt-" + status
		run, ok := got[id]
		if !ok {
			t.Fatalf("GET /api/runs did not serve run %s", id)
		}
		if run.Resumable != resumable {
			t.Errorf("a %s run is served resumable=%v, want %v; the endpoint's rule is %v",
				status, run.Resumable, resumable, ResumableStatuses)
		}
	}
}

// The stream snapshot claims to hold what GET /api/runs would have returned. A
// client that applied a snapshot and then rendered the drawer would otherwise
// hold runs with no resumable answer at all.
func TestTheStreamSnapshotCarriesTheSameResumableAnswerAsTheRunList(t *testing.T) {
	srv, st, _ := streamFixture(t)

	if err := st.CreateRun(&store.RunRecord{
		ID: "sgt-orphan", Project: "o3", TaskID: "sgt-orphan", Brief: "b", Status: "failed",
	}); err != nil {
		t.Fatal(err)
	}

	events, _ := openStream(t, srv, "")
	ev := nextEvent(t, events)
	if ev.Event != "snapshot" {
		t.Fatalf("first event = %q, want snapshot", ev.Event)
	}

	var snap struct {
		Runs []servedRun `json:"runs"`
	}
	if err := json.Unmarshal([]byte(ev.Data), &snap); err != nil {
		t.Fatalf("decoding the snapshot %s: %v", ev.Data, err)
	}
	if len(snap.Runs) != 1 {
		t.Fatalf("snapshot carried %d runs, want 1", len(snap.Runs))
	}
	if !snap.Runs[0].Resumable {
		t.Errorf("the snapshot serves a failed run as resumable=false; the endpoint accepts %v",
			ResumableStatuses)
	}
}

// Scenario: phases already passed are named before resuming.
//
// The names come from the same server-side derivation the endpoint reports after
// resuming, so what the operator is told beforehand and what happens afterwards
// cannot disagree.
func TestRunDetailsNamesThePhasesAResumeWouldSkip(t *testing.T) {
	mux, st, _ := dispatchFixture(t)

	if err := st.CreateRun(&store.RunRecord{
		ID: "sgt-skip", Project: "o3", TaskID: "sgt-skip", Brief: "b", Status: "failed",
	}); err != nil {
		t.Fatal(err)
	}
	for _, p := range []store.PhaseRecord{
		{ID: "p1", RunID: "sgt-skip", Repo: "svc", Name: "build", Kind: "agent", Status: "passed"},
		{ID: "p2", RunID: "sgt-skip", Repo: "svc", Name: "lint", Kind: "code", Status: "passed"},
		{ID: "p3", RunID: "sgt-skip", Repo: "svc", Name: "test", Kind: "code", Status: "failed"},
	} {
		rec := p
		if err := st.RecordPhase(&rec); err != nil {
			t.Fatal(err)
		}
	}

	w := getRecorded(t, mux, "/api/run-details?id=sgt-skip")
	if w.Code != http.StatusOK {
		t.Fatalf("GET /api/run-details = %d, want 200; body=%s", w.Code, w.Body.String())
	}
	var details struct {
		ResumeSkips []string `json:"resume_skips"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &details); err != nil {
		t.Fatalf("decoding run details %s: %v", w.Body.String(), err)
	}

	got := append([]string{}, details.ResumeSkips...)
	sort.Strings(got)
	if strings.Join(got, ",") != "build,lint" {
		t.Errorf("resume_skips = %v, want the passed phases build and lint; a failed phase is re-run, not skipped", details.ResumeSkips)
	}
}

// ---- the drawer --------------------------------------------------------------

// renderRunDetail executes the run drawer's body renderer out of the embedded
// asset. The assertion is then about the JavaScript that is actually served
// rather than about a description of it.
func renderRunDetail(t *testing.T, run map[string]interface{}, skips []string) string {
	t.Helper()

	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("node is not installed; cannot execute the embedded UI render logic")
	}
	src := embeddedIndex(t)

	parts := []string{
		extractJSFunction(t, src, "escapeHTML"),
		"const escapeAttr = escapeHTML;",
		extractJSFunction(t, src, "relativeTime"),
		extractJSFunction(t, src, "runDetailHTML"),
	}

	runJSON, err := json.Marshal(run)
	if err != nil {
		t.Fatal(err)
	}
	skipsJSON, err := json.Marshal(skips)
	if err != nil {
		t.Fatal(err)
	}

	harness := fmt.Sprintf("%s\n\nprocess.stdout.write(runDetailHTML(%s, %s));",
		strings.Join(parts, "\n\n"), runJSON, skipsJSON)

	return runNode(t, node, "run-detail.mjs", harness)
}

// extractAsyncJSFunction lifts an `async function` declaration out of the
// embedded asset. extractJSFunction matches from the `function` keyword, which
// drops the `async` prefix and makes the body's `await` a syntax error, so the
// prefix is restored here — and asserted, so a declaration that stops being async
// fails rather than quietly changing what the harness executes.
func extractAsyncJSFunction(t *testing.T, src, name string) string {
	t.Helper()
	if !strings.Contains(src, "async function "+name+"(") {
		t.Fatalf("function %s is not declared async in index.html", name)
	}
	return "async " + extractJSFunction(t, src, name)
}

func runNode(t *testing.T, node, name, harness string) string {
	t.Helper()
	script := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(script, []byte(harness), 0o644); err != nil {
		t.Fatalf("write harness: %v", err)
	}
	out, err := exec.Command(node, script).Output()
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			t.Fatalf("node failed: %v\n%s", err, ee.Stderr)
		}
		t.Fatalf("node failed: %v", err)
	}
	return string(out)
}

// Scenario: a failed run offers resume.
func TestTheDrawerOffersResumeForARunTheServerWillAccept(t *testing.T) {
	html := renderRunDetail(t, map[string]interface{}{
		"id": "sgt-orphan", "status": "failed", "project": "o3", "resumable": true,
	}, []string{"build"})

	for _, want := range []string{
		"<button",                 // a control, not prose
		"resumeRun('sgt-orphan')", // wired to the endpoint's caller
		"focus-visible:ring",      // reachable by keyboard
	} {
		if !strings.Contains(html, want) {
			t.Errorf("the drawer for a resumable run should contain %q\n--- html ---\n%s", want, html)
		}
	}
}

// Scenarios: a passed run does not offer resume; a running run does not offer
// resume. A payload with no answer at all is treated as "not resumable": the
// interface must never invite an action on a value the server did not give.
func TestTheDrawerOffersNoResumeForARunTheServerWillRefuse(t *testing.T) {
	cases := []map[string]interface{}{
		{"id": "sgt-1", "status": "passed", "project": "o3", "resumable": false},
		{"id": "sgt-2", "status": "running", "project": "o3", "resumable": false},
		{"id": "sgt-3", "status": "failed", "project": "o3"},
	}
	for _, run := range cases {
		html := renderRunDetail(t, run, []string{"build"})
		if strings.Contains(html, "resumeRun(") {
			t.Errorf("a run served resumable=%v offers resume; the server would refuse it\n--- html ---\n%s",
				run["resumable"], html)
		}
		if !strings.Contains(html, run["status"].(string)) {
			t.Errorf("the drawer must still report the run's status %q\n%s", run["status"], html)
		}
	}
}

// Scenario: phases already passed are named before resuming.
func TestTheDrawerNamesTheSkippedPhasesBeforeResuming(t *testing.T) {
	run := map[string]interface{}{"id": "sgt-1", "status": "failed", "project": "o3", "resumable": true}

	html := renderRunDetail(t, run, []string{"build", "lint"})
	for _, want := range []string{"build", "lint"} {
		if !strings.Contains(html, want) {
			t.Errorf("the drawer must name the skipped phase %q before the operator commits\n%s", want, html)
		}
	}

	// Nothing passed means nothing is skipped. The drawer must not list a phase
	// name it was not given.
	empty := renderRunDetail(t, run, nil)
	if strings.Contains(empty, "<li") {
		t.Errorf("with no passed phase the drawer must list none\n%s", empty)
	}
}

// Both scenarios end to end, from the bytes the server actually serves.
//
// The two previous tests hand runDetailHTML a payload written by the test, so they
// cannot catch a field the server names differently from the field the renderer
// reads. This one takes the real GET /api/runs and GET /api/run-details responses
// and renders the drawer from them.
func TestTheDrawerRendersFromWhatTheServerActuallyServes(t *testing.T) {
	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("node is not installed; cannot execute the embedded UI render logic")
	}

	mux, st, _ := dispatchFixture(t)
	for id, status := range map[string]string{"sgt-failed": "failed", "sgt-passed": "passed"} {
		if err := st.CreateRun(&store.RunRecord{
			ID: id, Project: "o3", TaskID: id, Brief: "b", Status: status,
		}); err != nil {
			t.Fatal(err)
		}
	}
	if err := st.RecordPhase(&store.PhaseRecord{
		ID: "p1", RunID: "sgt-failed", Repo: "svc", Name: "build", Kind: "agent", Status: "passed",
	}); err != nil {
		t.Fatal(err)
	}

	runsBody := getRecorded(t, mux, "/api/runs").Body.String()
	detailsBody := getRecorded(t, mux, "/api/run-details?id=sgt-failed").Body.String()

	src := embeddedIndex(t)
	// selectRun is where run details arrive, so it is where the skip list must be
	// picked up. A rename on either side breaks the drawer silently otherwise.
	if !strings.Contains(extractAsyncJSFunction(t, src, "selectRun"), "resume_skips") {
		t.Error("selectRun does not read resume_skips from /api/run-details")
	}

	harness := fmt.Sprintf(`
%s

const escapeAttr = escapeHTML;
const runs = JSON.parse(%s);
const details = JSON.parse(%s);
const byID = new Map(runs.map(r => [r.id, r]));

process.stdout.write(JSON.stringify({
  failed: runDetailHTML(byID.get('sgt-failed'), details.resume_skips),
  passed: runDetailHTML(byID.get('sgt-passed'), details.resume_skips),
}));
`,
		strings.Join([]string{
			extractJSFunction(t, src, "escapeHTML"),
			extractJSFunction(t, src, "relativeTime"),
			extractJSFunction(t, src, "runDetailHTML"),
		}, "\n\n"),
		strconvQuote(runsBody), strconvQuote(detailsBody))

	var got struct {
		Failed string `json:"failed"`
		Passed string `json:"passed"`
	}
	out := runNode(t, node, "served.mjs", harness)
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("decoding harness output %s: %v", out, err)
	}

	if !strings.Contains(got.Failed, "resumeRun('sgt-failed')") {
		t.Errorf("the drawer for the served failed run offers no resume\n%s", got.Failed)
	}
	if !strings.Contains(got.Failed, "build") {
		t.Errorf("the drawer does not name the phase the resume will skip\n%s", got.Failed)
	}
	if strings.Contains(got.Passed, "resumeRun(") {
		t.Errorf("the drawer for the served passed run offers resume; the server would refuse it\n%s", got.Passed)
	}
}

// strconvQuote renders s as a JavaScript string literal.
func strconvQuote(s string) string {
	b, err := json.Marshal(s)
	if err != nil {
		return `""`
	}
	return string(b)
}

// resumeOutcome is what the confirmation path did.
type resumeOutcome struct {
	Confirms  []string `json:"confirms"`
	Fetches   []string `json:"fetches"`
	Bodies    []string `json:"bodies"`
	Rereads   int      `json:"rereads"`
	Refusal   string   `json:"refusal"`
	Refusals  int      `json:"refusals"`
	Connected int      `json:"connectionErrors"`
}

// runResumeConfirmation executes resumeRun from the embedded asset against a
// stubbed fetch, so the request it issues, the refusal it displays and the reads
// it does *not* do are all observable.
func runResumeConfirmation(t *testing.T, confirmed bool, ok bool, serverText string) resumeOutcome {
	t.Helper()

	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("node is not installed; cannot execute the embedded UI resume logic")
	}
	src := embeddedIndex(t)

	parts := []string{
		extractJSFunction(t, src, "showResumeRefusal"),
		extractAsyncJSFunction(t, src, "resumeRun"),
	}

	harness := fmt.Sprintf(`
%s

const els = {};
globalThis.document = {
  getElementById: (id) => els[id] || (els[id] = {
    textContent: '', innerHTML: '', classList: { add() {}, remove() {} },
  }),
};

let activeRunId = 'sgt-orphan';
let activeRunSkips = ['build', 'lint'];
const calls = { confirms: [], fetches: [], bodies: [], rereads: 0, refusals: 0, connectionErrors: 0 };

globalThis.confirm = (message) => { calls.confirms.push(message); return %t; };
globalThis.fetch = async (url, opts) => {
  calls.fetches.push(url);
  calls.bodies.push((opts && opts.body) || '');
  return { ok: %t, status: %t ? 200 : 409, text: async () => %q, json: async () => ({}) };
};
function fetchRuns() { calls.rereads++; }
function fetchFleet() { calls.rereads++; }
function setConnectionError(isError) { if (isError) calls.connectionErrors++; }

await resumeRun('sgt-orphan');

process.stdout.write(JSON.stringify({
  confirms: calls.confirms,
  fetches: calls.fetches,
  bodies: calls.bodies,
  rereads: calls.rereads,
  refusal: els['resume-refusal'] ? els['resume-refusal'].textContent : '',
  refusals: calls.refusals,
  connectionErrors: calls.connectionErrors,
}));
`, strings.Join(parts, "\n\n"), confirmed, ok, ok, serverText)

	out := runNode(t, node, "resume.mjs", harness)

	var got resumeOutcome
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("decoding the harness output %s: %v", out, err)
	}
	return got
}

// Scenario: resuming moves the run back to running without a new request.
//
// The transition is carried by the change stream, so a resume that worked only
// because the page re-read everything would reintroduce the polling the previous
// change removed.
func TestConfirmingResumeCallsTheEndpointAndReadsNothingBack(t *testing.T) {
	got := runResumeConfirmation(t, true, true, "")

	if len(got.Confirms) != 1 {
		t.Fatalf("confirmed %d times, want exactly 1", len(got.Confirms))
	}
	for _, name := range []string{"build", "lint"} {
		if !strings.Contains(got.Confirms[0], name) {
			t.Errorf("the confirmation does not name skipped phase %q: %q", name, got.Confirms[0])
		}
	}
	if len(got.Fetches) != 1 || got.Fetches[0] != "/api/run-resume" {
		t.Fatalf("requests = %v, want exactly one POST to /api/run-resume", got.Fetches)
	}
	if !strings.Contains(got.Bodies[0], "sgt-orphan") {
		t.Errorf("the request body %q does not name the run", got.Bodies[0])
	}
	if got.Rereads != 0 {
		t.Errorf("resume triggered %d re-reads; the change stream carries the transition to running", got.Rereads)
	}
	if got.Refusal != "" {
		t.Errorf("an accepted resume displayed the refusal %q", got.Refusal)
	}
}

// Declining the confirmation must issue no request at all.
func TestDecliningTheConfirmationResumesNothing(t *testing.T) {
	got := runResumeConfirmation(t, false, true, "")
	if len(got.Fetches) != 0 {
		t.Errorf("a declined confirmation issued %v", got.Fetches)
	}
}

// Scenario: a refused resume reports the server's reason.
func TestARefusedResumeShowsTheServersOwnReason(t *testing.T) {
	reason := "run sgt-orphan is passed and cannot be resumed; resumable statuses are failed, cancelled, timed_out"

	got := runResumeConfirmation(t, true, false, reason)

	if got.Refusal != reason {
		t.Errorf("displayed %q, want the server's own text %q", got.Refusal, reason)
	}
	if got.Rereads != 0 {
		t.Errorf("a refusal triggered %d re-reads, want 0", got.Rereads)
	}
}

// The server's refusal is authoritative, so the interface must hold no second
// copy of which statuses qualify. Two authorities for one rule drift, and the
// drift shows up as the dashboard offering an action the server rejects.
func TestTheDashboardDoesNotRestateTheResumableStatuses(t *testing.T) {
	src := embeddedIndex(t)

	detail := extractJSFunction(t, src, "runDetailHTML")
	js := detail + "\n" + extractJSFunction(t, src, "resumeRun")

	for _, status := range ResumableStatuses {
		for _, literal := range []string{"'" + status + "'", `"` + status + `"`} {
			if strings.Contains(js, literal) {
				t.Errorf("the resume logic names the status literal %s; the server's list is the only authority", literal)
			}
		}
	}
	if !strings.Contains(detail, "resumable") {
		t.Error("runDetailHTML does not read the served resumable boolean")
	}
}
