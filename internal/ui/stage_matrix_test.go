package ui

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/callmeradical/sergeant/internal/store"
)

// The stage matrix is rendered in JavaScript inside the embedded index.html, so
// the only honest way to assert what an operator sees is to execute that
// JavaScript. These helpers lift the render functions out of the embedded file
// and run them under node against a stub document — no browser, no server.

// extractJS returns the source of a top-level `function name(...) { ... }`
// declaration from src, brace-matched. It fails the test if the declaration is
// missing, so a rename shows up as a failure rather than a silent skip.
func extractJSFunction(t *testing.T, src, name string) string {
	t.Helper()
	head := "function " + name + "("
	start := strings.Index(src, head)
	if start < 0 {
		t.Fatalf("function %s not found in index.html", name)
	}
	open := strings.Index(src[start:], "{")
	if open < 0 {
		t.Fatalf("function %s has no body", name)
	}
	open += start
	depth := 0
	for i := open; i < len(src); i++ {
		switch src[i] {
		case '{':
			depth++
		case '}':
			depth--
			if depth == 0 {
				return src[start : i+1]
			}
		}
	}
	t.Fatalf("function %s body is unbalanced", name)
	return ""
}

// extractJSBlock returns a top-level `const name = { ... };` declaration.
func extractJSBlock(t *testing.T, src, decl string) string {
	t.Helper()
	start := strings.Index(src, decl)
	if start < 0 {
		t.Fatalf("declaration %q not found in index.html", decl)
	}
	end := strings.Index(src[start:], "};")
	if end < 0 {
		t.Fatalf("declaration %q is unterminated", decl)
	}
	return src[start : start+end+2]
}

type matrixRender struct {
	Head string `json:"head"`
	Body string `json:"body"`
}

// renderStageMatrix executes renderLiveStitchMatrix from the embedded UI against
// the given phases and returns the HTML it wrote into the table head and body.
func renderStageMatrix(t *testing.T, phases []store.PhaseRecord, envelopes []store.EnvelopeRecord) matrixRender {
	t.Helper()

	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("node is not installed; cannot execute the embedded UI render logic")
	}

	raw, err := staticFS.ReadFile("static/index.html")
	if err != nil {
		t.Fatalf("read embedded index.html: %v", err)
	}
	src := string(raw)

	parts := []string{
		extractJSFunction(t, src, "escapeHTML"),
		"const escapeAttr = escapeHTML;",
		extractJSFunction(t, src, "formatDuration"),
		extractJSBlock(t, src, "const PHASE_LOOK = {"),
		extractJSFunction(t, src, "phaseCellHTML"),
		extractJSFunction(t, src, "deliveryCellHTML"),
		extractJSFunction(t, src, "renderLiveStitchMatrix"),
	}

	phasesJSON, err := json.Marshal(phases)
	if err != nil {
		t.Fatalf("marshal phases: %v", err)
	}
	envelopesJSON, err := json.Marshal(envelopes)
	if err != nil {
		t.Fatalf("marshal envelopes: %v", err)
	}

	harness := fmt.Sprintf(`
const elements = new Map();
globalThis.document = {
  getElementById(id) {
    if (!elements.has(id)) elements.set(id, { innerHTML: '', innerText: '' });
    return elements.get(id);
  }
};

%s

renderLiveStitchMatrix({ id: 'run-under-test' }, %s, %s);

process.stdout.write(JSON.stringify({
  head: document.getElementById('stage-matrix-head').innerHTML,
  body: document.getElementById('stage-matrix-tbody').innerHTML
}));
`, strings.Join(parts, "\n\n"), phasesJSON, envelopesJSON)

	dir := t.TempDir()
	script := filepath.Join(dir, "render.mjs")
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

	var got matrixRender
	if err := json.Unmarshal(out, &got); err != nil {
		t.Fatalf("harness output is not JSON: %v\n%s", err, out)
	}
	return got
}

// A factory pipeline stage and a code gate may carry the same name. Both phases
// are real records, so both must appear. Keying the matrix by phase name alone
// made whichever phase was written last overwrite the other, and the dropped
// phase vanished from the dashboard.
func TestStageMatrixKeepsAgentAndGateOfTheSameName(t *testing.T) {
	phases := []store.PhaseRecord{
		{Repo: "svc", Name: "build", Kind: "agent", Status: "failed", Error: "AGENT_BUILD_MARKER", DurationMs: 1200},
		{Repo: "svc", Name: "build", Kind: "code", Status: "failed", Error: "GATE_BUILD_MARKER", DurationMs: 340},
		{Repo: "svc", Name: "unit-tests", Kind: "code", Status: "passed", DurationMs: 84},
	}

	got := renderStageMatrix(t, phases, nil)

	// 1. Both colliding phases keep a column, and the unique name is not qualified.
	for _, want := range []string{">build (agent)<", ">build (gate)<", ">unit-tests<"} {
		if !strings.Contains(got.Head, want) {
			t.Errorf("column header %q missing\n--- head ---\n%s", want, got.Head)
		}
	}
	if strings.Contains(got.Head, "unit-tests (") {
		t.Errorf("qualified a phase name that does not collide\n--- head ---\n%s", got.Head)
	}
	if n := strings.Count(got.Head, "<th "); n != 5 {
		t.Errorf("got %d header cells, want 5 (repository + 3 phases + delivery)\n%s", n, got.Head)
	}

	// 2. Columns keep first-seen order.
	agentCol := strings.Index(got.Head, ">build (agent)<")
	gateCol := strings.Index(got.Head, ">build (gate)<")
	testsCol := strings.Index(got.Head, ">unit-tests<")
	if !(agentCol < gateCol && gateCol < testsCol) {
		t.Errorf("columns are not in first-seen order (agent=%d gate=%d unit-tests=%d)\n%s",
			agentCol, gateCol, testsCol, got.Head)
	}

	// 3. Each column carries its own phase, in the same order as the headers.
	agentCell := strings.Index(got.Body, "AGENT_BUILD_MARKER")
	gateCell := strings.Index(got.Body, "GATE_BUILD_MARKER")
	if agentCell < 0 {
		t.Errorf("the agent phase named build was dropped from the row\n--- body ---\n%s", got.Body)
	}
	if gateCell < 0 {
		t.Errorf("the code gate named build was dropped from the row\n--- body ---\n%s", got.Body)
	}
	if agentCell >= 0 && gateCell >= 0 && agentCell > gateCell {
		t.Errorf("cells do not follow column order\n--- body ---\n%s", got.Body)
	}
	if n := strings.Count(got.Body, "<td "); n != 5 {
		t.Errorf("got %d body cells, want 5 (repository + 3 phases + delivery)\n%s", n, got.Body)
	}
	// The only empty cell is delivery, which has no envelope to report.
	if n := strings.Count(got.Body, "&mdash;"); n != 1 {
		t.Errorf("got %d empty cells, want 1 (delivery only)\n--- body ---\n%s", n, got.Body)
	}
	if n := strings.Count(got.Body, "<tr "); n != 1 {
		t.Errorf("got %d rows, want 1 repository row\n%s", n, got.Body)
	}
}

// Distinct phase names must still render exactly as before: one column each,
// labelled with the bare name, in first-seen order.
func TestStageMatrixLeavesDistinctPhaseNamesUnqualified(t *testing.T) {
	phases := []store.PhaseRecord{
		{Repo: "svc", Name: "plan", Kind: "agent", Status: "passed", DurationMs: 10},
		{Repo: "svc", Name: "build", Kind: "agent", Status: "passed", DurationMs: 20},
		{Repo: "svc", Name: "lint", Kind: "code", Status: "passed", DurationMs: 30},
		{Repo: "web", Name: "plan", Kind: "agent", Status: "failed", Error: "WEB_PLAN_MARKER"},
	}

	got := renderStageMatrix(t, phases, nil)

	for _, want := range []string{">plan<", ">build<", ">lint<"} {
		if !strings.Contains(got.Head, want) {
			t.Errorf("column header %q missing\n--- head ---\n%s", want, got.Head)
		}
	}
	if strings.Contains(got.Head, "(agent)") || strings.Contains(got.Head, "(gate)") {
		t.Errorf("qualified labels appeared without a name collision\n--- head ---\n%s", got.Head)
	}
	if n := strings.Count(got.Head, "<th "); n != 5 {
		t.Errorf("got %d header cells, want 5\n%s", n, got.Head)
	}
	if n := strings.Count(got.Body, "<tr "); n != 2 {
		t.Errorf("got %d rows, want 2 repositories\n%s", n, got.Body)
	}
	if !strings.Contains(got.Body, "WEB_PLAN_MARKER") {
		t.Errorf("the second repository's phase was dropped\n--- body ---\n%s", got.Body)
	}
}
