package mcp

import (
	"encoding/json"
	"go/scanner"
	"go/token"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/callmeradical/sergeant/internal/store"
)

// Requirement: an agent can follow a run it dispatched.
//
// Decision D1 makes the agent-driven path equal in standing to the
// coordinator-driven one, so an agent that dispatches work must be able to
// observe it without scraping the dashboard or guessing a duration. Decision D7
// forbids reaching that observability through v1: no bin/sgt-* and no tmux.

func mcpFixture(t *testing.T) (*MCPServer, *store.Store) {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	return NewMCPServer(st), st
}

func callTool(t *testing.T, s *MCPServer, name string, args map[string]interface{}) map[string]interface{} {
	t.Helper()
	text, err := s.executeTool(name, args)
	if err != nil {
		t.Fatalf("%s returned an error rather than a result: %v", name, err)
	}
	var out map[string]interface{}
	if err := json.Unmarshal([]byte(text), &out); err != nil {
		t.Fatalf("%s returned %q, which is not JSON: %v", name, text, err)
	}
	return out
}

// Scenario: A run's status is addressable by run id.
func TestRunStatusIsAddressableByRunID(t *testing.T) {
	s, st := mcpFixture(t)

	run := &store.RunRecord{ID: "sgt-abc", Project: "o3", TaskID: "sgt-abc", Brief: "add webhooks", Status: "running"}
	if err := st.CreateRun(run); err != nil {
		t.Fatal(err)
	}
	if err := st.RecordPhase(&store.PhaseRecord{
		ID: "p1", RunID: "sgt-abc", Repo: "svc", Name: "build", Kind: "agent", Status: "passed", DurationMs: 1200,
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.RecordPhase(&store.PhaseRecord{
		ID: "p2", RunID: "sgt-abc", Repo: "svc", Name: "lint", Kind: "code", Status: "failed", Error: "one problem",
	}); err != nil {
		t.Fatal(err)
	}

	got := callTool(t, s, "sergeant_run_status", map[string]interface{}{"run_id": "sgt-abc"})

	if got["found"] != true {
		t.Fatalf("found = %v, want true; result=%+v", got["found"], got)
	}
	if got["status"] != "running" {
		t.Errorf("status = %v, want running", got["status"])
	}
	if got["slug"] != run.Slug {
		t.Errorf("slug = %v, want %q", got["slug"], run.Slug)
	}
	if got["slug"] == "" || got["slug"] == nil {
		t.Error("no slug reported; the run's speakable label is what an operator is told")
	}
	phases, ok := got["phases"].([]interface{})
	if !ok || len(phases) != 2 {
		t.Fatalf("phases = %v, want the 2 recorded phase results", got["phases"])
	}
	first, _ := phases[0].(map[string]interface{})
	if first["name"] != "build" || first["status"] != "passed" {
		t.Errorf("first phase result = %+v, want build/passed", first)
	}
	second, _ := phases[1].(map[string]interface{})
	if second["name"] != "lint" || second["status"] != "failed" {
		t.Errorf("second phase result = %+v, want lint/failed", second)
	}
	if second["error"] != "one problem" {
		t.Errorf("a failed phase reports error %v, want %q", second["error"], "one problem")
	}
	// The tool reads the same sequence the dashboard consumes, so an agent can
	// follow up by subscribing from it instead of guessing.
	seq, ok := got["sequence"].(float64)
	if !ok || seq <= 0 {
		t.Errorf("sequence = %v, want the store's current sequence", got["sequence"])
	}
}

// Scenario: An unknown run id is reported as unknown.
//
// An empty status is indistinguishable from a run that has not started, which
// would let a caller wait forever on a typo.
func TestAnUnknownRunIDIsReportedAsUnknown(t *testing.T) {
	s, _ := mcpFixture(t)

	got := callTool(t, s, "sergeant_run_status", map[string]interface{}{"run_id": "sgt-typo"})

	if got["found"] != false {
		t.Fatalf("found = %v, want false; result=%+v", got["found"], got)
	}
	if _, present := got["status"]; present {
		t.Errorf("an unknown run reported a status field (%v); not-found must not look like a run that has not started",
			got["status"])
	}
	errText, _ := got["error"].(string)
	if !strings.Contains(errText, "sgt-typo") {
		t.Errorf("error = %q; it must name the id that was not found", errText)
	}
	if got["run_id"] != "sgt-typo" {
		t.Errorf("run_id = %v, want the id that was asked for", got["run_id"])
	}
}

// Scenario: An unknown run id is reported as unknown — for the wait too. A wait
// on a typo must not block for its whole bound.
func TestWaitingOnAnUnknownRunIDIsReportedAsUnknown(t *testing.T) {
	s, _ := mcpFixture(t)

	start := time.Now()
	got := callTool(t, s, "sergeant_run_wait", map[string]interface{}{
		"run_id": "sgt-typo", "timeout_seconds": 30,
	})
	elapsed := time.Since(start)

	if got["found"] != false {
		t.Fatalf("found = %v, want false; result=%+v", got["found"], got)
	}
	if elapsed > 2*time.Second {
		t.Errorf("waiting on an unknown run took %v; it must report not-found immediately", elapsed)
	}
	if _, present := got["status"]; present {
		t.Errorf("an unknown run reported a status field (%v)", got["status"])
	}
}

// Scenario: Waiting returns when the run reaches a terminal state.
func TestWaitingReturnsWhenTheRunReachesATerminalState(t *testing.T) {
	s, st := mcpFixture(t)
	if err := st.CreateRun(&store.RunRecord{ID: "sgt-live", Project: "o3", TaskID: "sgt-live", Status: "running"}); err != nil {
		t.Fatal(err)
	}

	go func() {
		time.Sleep(120 * time.Millisecond)
		_ = st.UpdateRunStatus("sgt-live", "failed")
	}()

	start := time.Now()
	got := callTool(t, s, "sergeant_run_wait", map[string]interface{}{
		"run_id": "sgt-live", "timeout_seconds": 20,
	})
	elapsed := time.Since(start)

	if got["found"] != true {
		t.Fatalf("found = %v, want true; result=%+v", got["found"], got)
	}
	if got["terminal"] != true {
		t.Errorf("terminal = %v, want true; result=%+v", got["terminal"], got)
	}
	if got["timed_out"] != false {
		t.Errorf("timed_out = %v, want false", got["timed_out"])
	}
	if got["status"] != "failed" {
		t.Errorf("status = %v, want failed — the status the store holds", got["status"])
	}
	// It must return on the transition, not on its bound.
	if elapsed > 10*time.Second {
		t.Errorf("the wait took %v; it did not react to the transition", elapsed)
	}
}

// Scenario: Waiting on an already-terminal run returns immediately.
//
// A wait that blocks on a finished run would reintroduce the guessed duration
// this requirement removes.
func TestWaitingOnAnAlreadyTerminalRunReturnsWithoutDelay(t *testing.T) {
	s, st := mcpFixture(t)
	if err := st.CreateRun(&store.RunRecord{ID: "sgt-done", Project: "o3", TaskID: "sgt-done", Status: "running"}); err != nil {
		t.Fatal(err)
	}
	if err := st.UpdateRunStatus("sgt-done", "passed"); err != nil {
		t.Fatal(err)
	}

	start := time.Now()
	got := callTool(t, s, "sergeant_run_wait", map[string]interface{}{
		"run_id": "sgt-done", "timeout_seconds": 60,
	})
	elapsed := time.Since(start)

	if got["terminal"] != true || got["status"] != "passed" {
		t.Fatalf("result = %+v, want terminal passed", got)
	}
	if elapsed > time.Second {
		t.Errorf("waiting on a finished run took %v; it must return without delay", elapsed)
	}
	if got["timed_out"] != false {
		t.Errorf("timed_out = %v, want false", got["timed_out"])
	}
}

// Scenario: Waiting is bounded and says so when it gives up.
//
// A wait that returned "failed" on its own impatience would record a falsehood.
// The run's status is whatever the store says, not whatever the caller's patience
// implies.
func TestAnExceededWaitBoundReportsTheRunAsStillExecuting(t *testing.T) {
	s, st := mcpFixture(t)
	if err := st.CreateRun(&store.RunRecord{ID: "sgt-slow", Project: "o3", TaskID: "sgt-slow", Status: "running"}); err != nil {
		t.Fatal(err)
	}

	start := time.Now()
	got := callTool(t, s, "sergeant_run_wait", map[string]interface{}{
		"run_id": "sgt-slow", "timeout_seconds": 0.2,
	})
	elapsed := time.Since(start)

	if got["found"] != true {
		t.Fatalf("found = %v, want true; result=%+v", got["found"], got)
	}
	if got["timed_out"] != true {
		t.Errorf("timed_out = %v, want true", got["timed_out"])
	}
	if got["terminal"] != false {
		t.Errorf("terminal = %v, want false; the bound elapsed, the run did not finish", got["terminal"])
	}
	if got["status"] != "running" {
		t.Errorf("status = %v, want running — the status the store holds", got["status"])
	}
	for _, invented := range []string{"failed", "passed", "cancelled", "timed_out"} {
		if got["status"] == invented {
			t.Errorf("an exceeded bound reported the terminal status %q, which the store never wrote", invented)
		}
	}
	note, _ := got["note"].(string)
	if !strings.Contains(strings.ToLower(note), "still executing") {
		t.Errorf("note = %q; an exceeded bound must say the run is still executing", note)
	}
	if elapsed > 10*time.Second {
		t.Errorf("a 0.2s bound took %v to elapse", elapsed)
	}
}

// Both tools must be advertised, or no client can reach them however correct
// their implementation is.
func TestTheRunFollowingToolsAreAdvertised(t *testing.T) {
	advertised := map[string]Tool{}
	for _, tool := range Tools() {
		advertised[tool.Name] = tool
	}

	for _, name := range []string{"sergeant_run_status", "sergeant_run_wait"} {
		tool, ok := advertised[name]
		if !ok {
			t.Fatalf("%s is not advertised in tools/list; the advertised set is %v", name, keysOf(advertised))
		}
		schema, ok := tool.InputSchema.(map[string]interface{})
		if !ok {
			t.Fatalf("%s has no object input schema", name)
		}
		props, ok := schema["properties"].(map[string]interface{})
		if !ok {
			t.Fatalf("%s declares no properties", name)
		}
		if _, ok := props["run_id"]; !ok {
			t.Errorf("%s does not accept a run_id; the whole point is addressing one run", name)
		}
		required, _ := schema["required"].([]string)
		if !containsString(required, "run_id") {
			t.Errorf("%s does not require run_id; required = %v", name, required)
		}
	}

	if _, ok := advertised["sergeant_run_wait"].InputSchema.(map[string]interface{})["properties"].(map[string]interface{})["timeout_seconds"]; !ok {
		t.Error("sergeant_run_wait does not accept timeout_seconds; the bound must come from the caller")
	}

	// The five pre-existing tools must survive.
	for _, name := range []string{
		"sergeant_status", "sergeant_get_brief", "sergeant_run_gates",
		"sergeant_emit_envelope", "sergeant_seal_pr",
	} {
		if _, ok := advertised[name]; !ok {
			t.Errorf("%s is no longer advertised", name)
		}
	}
}

// Decision D7: v1 is not a dependency on this branch. Following a run reads the
// store; it does not shell out to the v1 toolbelt and it does not use tmux.
//
// The scan is over identifiers and string literals rather than over raw bytes.
// A comment that names what is forbidden is documentation, not a dependency, and
// a test that could not tell the two apart would punish explaining the rule.
func TestFollowingARunDoesNotReachIntoV1(t *testing.T) {
	forbidden := []string{"bin/sgt-", "sgt-dispatch", "sgt-watch", "sgt-respond", "tmux"}

	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".go") || strings.HasSuffix(e.Name(), "_test.go") {
			continue
		}
		body, err := os.ReadFile(e.Name())
		if err != nil {
			t.Fatal(err)
		}

		fset := token.NewFileSet()
		var sc scanner.Scanner
		// Mode zero: comments are skipped rather than returned.
		sc.Init(fset.AddFile(e.Name(), fset.Base(), len(body)), body, nil, 0)
		for {
			_, tok, lit := sc.Scan()
			if tok == token.EOF {
				break
			}
			if tok != token.STRING && tok != token.IDENT {
				continue
			}
			for _, bad := range forbidden {
				if strings.Contains(lit, bad) {
					t.Errorf("%s references %q in code; decision D7 forbids the MCP surface depending on v1",
						e.Name(), bad)
				}
			}
		}
	}
}

func keysOf(m map[string]Tool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

func containsString(list []string, want string) bool {
	for _, v := range list {
		if v == want {
			return true
		}
	}
	return false
}
