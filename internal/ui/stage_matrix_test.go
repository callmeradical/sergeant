package ui

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
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

// renderLane executes the workflow-graph node renderers from the embedded UI
// against a definition and a set of phases, returning the HTML for one lane.
//
// laneHTML and nodeHTML are pure, so they can be exercised directly. The
// enclosing renderWorkflowGraph is async and fetches the definition over HTTP,
// which is the part this test deliberately does not need.
func renderLane(t *testing.T, repo string, def workflowDefJSON, phases []store.PhaseRecord) string {
	return renderLaneWidth(t, repo, def, phases, 1200)
}

func renderLaneWidth(t *testing.T, repo string, def workflowDefJSON, phases []store.PhaseRecord, width int) string {
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
		extractJSBlock(t, src, "const NODE_LOOK = {"),
		extractJSBlock(t, src, "const GEO = {"),
		extractJSFunction(t, src, "nodeCardHTML"),
		extractJSFunction(t, src, "columnWidth"),
		extractJSFunction(t, src, "cellHeight"),
		extractJSFunction(t, src, "phaseForNode"),
		extractJSFunction(t, src, "buildGraphLayout"),
		extractJSFunction(t, src, "positionLayout"),
		extractJSFunction(t, src, "groupBoxHTML"),
		extractJSFunction(t, src, "edgesSVG"),
		extractJSFunction(t, src, "laneHTML"),
	}

	defJSON, err := json.Marshal(def)
	if err != nil {
		t.Fatalf("marshal definition: %v", err)
	}
	phasesJSON, err := json.Marshal(phases)
	if err != nil {
		t.Fatalf("marshal phases: %v", err)
	}

	harness := fmt.Sprintf(`
%s

const phases = %s || [];
const byKey = new Map();
phases.forEach(p => byKey.set((p.kind || '') + '\u0000' + p.name, p));

process.stdout.write(laneHTML(%q, %s, byKey, %d));
`, strings.Join(parts, "\n\n"), phasesJSON, repo, defJSON, width)

	dir := t.TempDir()
	script := filepath.Join(dir, "lane.mjs")
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

type workflowDefJSON struct {
	Nodes []WorkflowNode `json:"nodes"`
	Edges []WorkflowEdge `json:"edges"`
}

func defFor(nodes ...WorkflowNode) workflowDefJSON {
	return workflowDefJSON{Nodes: nodes, Edges: []WorkflowEdge{}}
}

// A node backed by a phase must be an obvious control. The previous design put the
// click handler on a table cell, which gave the operator no indication it could be
// clicked at all.
func TestGraphNodeWithAPhaseIsAnObviousControl(t *testing.T) {
	def := defFor(WorkflowNode{ID: "stage:build", Label: "build", Kind: "stage", Group: "svc"})
	phases := []store.PhaseRecord{{Repo: "svc", Name: "build", Kind: "agent", Status: "passed", DurationMs: 4200}}

	html := renderLane(t, "svc", def, phases)

	for _, want := range []string{
		"<button",            // a control, not a cell
		"cursor-pointer",     // and it looks like one
		"onclick=",           // wired to the drawer
		"openPhaseDrawer(",   //
		"focus-visible:ring", // reachable by keyboard
		"aria-label=",        // and announced
		"4.2s",               // humanised duration, not raw ms
	} {
		if !strings.Contains(html, want) {
			t.Errorf("a node with a phase should contain %q\n--- html ---\n%s", want, html)
		}
	}
}

// A node in the definition that has not run must still be drawn, and must not
// pretend to be clickable. This is the behaviour that makes the view a workflow
// rather than a log: it shows what will happen, not only what did.
func TestGraphNodeWithoutAPhaseIsDrawnButNotClickable(t *testing.T) {
	def := defFor(
		WorkflowNode{ID: "stage:build", Label: "build", Kind: "stage", Group: "svc"},
		WorkflowNode{ID: "gate:lint", Label: "lint", Kind: "gate", Group: "svc"},
	)
	phases := []store.PhaseRecord{{Repo: "svc", Name: "build", Kind: "agent", Status: "passed", DurationMs: 1000}}

	html := renderLane(t, "svc", def, phases)

	if !strings.Contains(html, "lint") {
		t.Errorf("an unstarted node must still be drawn\n%s", html)
	}
	if !strings.Contains(html, "not started") {
		t.Errorf("an unstarted node must say so rather than showing a duration\n%s", html)
	}
	if strings.Count(html, "<button") != 1 {
		t.Errorf("exactly one node has a phase, so exactly one should be a button; got %d\n%s",
			strings.Count(html, "<button"), html)
	}
	if strings.Contains(html, "openPhaseDrawer('','lint'") {
		t.Errorf("an unstarted node must not be wired to the drawer\n%s", html)
	}
}

// A stage and a gate can legitimately share a name. Each node must resolve to the
// phase of its own kind, or the graph reports one phase's result under the other's
// heading.
func TestGraphResolvesCollidingNamesByKind(t *testing.T) {
	def := defFor(
		WorkflowNode{ID: "stage:build", Label: "build", Kind: "stage", Group: "svc"},
		WorkflowNode{ID: "gate:build", Label: "build", Kind: "gate", Group: "svc"},
	)
	phases := []store.PhaseRecord{
		{Repo: "svc", Name: "build", Kind: "agent", Status: "passed", DurationMs: 300000},
		{Repo: "svc", Name: "build", Kind: "code", Status: "failed", DurationMs: 1000},
	}

	html := renderLane(t, "svc", def, phases)

	if !strings.Contains(html, "5m") {
		t.Errorf("the stage node should show the agent phase duration (300000ms)\n%s", html)
	}
	if !strings.Contains(html, "1.0s") && !strings.Contains(html, "1s") {
		t.Errorf("the gate node should show the gate duration (1000ms)\n%s", html)
	}
	if !strings.Contains(html, "fa-circle-xmark") {
		t.Errorf("the failed gate must render as failed\n%s", html)
	}
	if !strings.Contains(html, "fa-circle-check") {
		t.Errorf("the passed stage must render as passed\n%s", html)
	}
}

// PRD R4.2: records correlate worktree and branch. A node must show where the work
// happened, and the drawer must carry the full path, or a passing gate is a claim
// about nothing in particular.
func TestGraphNodeShowsWhereTheWorkHappened(t *testing.T) {
	def := defFor(WorkflowNode{ID: "stage:build", Label: "build", Kind: "stage", Group: "svc"})
	phases := []store.PhaseRecord{{
		Repo: "svc", Name: "build", Kind: "agent", Status: "passed", DurationMs: 1000,
		Payload: []byte(`{"worktree":"/Users/x/.local/share/sergeant-v2/fleet/sgt-1/svc","branch":"sergeant/sgt-1"}`),
	}}

	html := renderLane(t, "svc", def, phases)

	// The card is a single 34px line to match the reference visual, so the location
	// travels in the tooltip and the aria-label rather than as a third row of text.
	// The drawer carries the full path with a copy button.
	if !strings.Contains(html, "fa-folder-tree") {
		t.Errorf("a phase with a recorded location must be marked as having one\n%s", html)
	}
	if !strings.Contains(html, "sergeant/sgt-1") {
		t.Errorf("the branch must be discoverable on the node (tooltip)\n%s", html)
	}
	if !strings.Contains(html, "/Users/x/.local/share/sergeant-v2/fleet/sgt-1/svc") {
		t.Errorf("the full worktree path must be discoverable on the node\n%s", html)
	}
}

// A phase with no recorded location must not invent one.
func TestGraphNodeOmitsLocationWhenUnrecorded(t *testing.T) {
	def := defFor(WorkflowNode{ID: "stage:build", Label: "build", Kind: "stage", Group: "svc"})
	phases := []store.PhaseRecord{{Repo: "svc", Name: "build", Kind: "agent", Status: "passed", DurationMs: 1000}}

	html := renderLane(t, "svc", def, phases)

	if strings.Contains(html, "fa-folder-tree") {
		t.Errorf("a phase with no recorded worktree must show no location\n%s", html)
	}
}

// The graph must wrap to a new row rather than scroll sideways: a pipeline you have
// to scroll to read is a pipeline you cannot see.
func TestGraphWrapsInsteadOfScrolling(t *testing.T) {
	var nodes []WorkflowNode
	for _, n := range []string{"one", "two", "three", "four", "five", "six"} {
		nodes = append(nodes, WorkflowNode{ID: "stage:" + n, Label: n, Kind: "stage", Group: "svc"})
	}
	def := defFor(nodes...)

	narrow := renderLaneWidth(t, "svc", def, nil, 700)
	wide := renderLaneWidth(t, "svc", def, nil, 2400)

	nh, nw := containerSize(t, narrow)
	wh, ww := containerSize(t, wide)

	if nw > 720 {
		t.Errorf("narrow layout should fit its container, got width %d", nw)
	}
	if nh <= wh {
		t.Errorf("wrapping should make the narrow layout taller: narrow=%d wide=%d", nh, wh)
	}
	if ww <= nw {
		t.Errorf("a wide container should lay out wider: narrow=%d wide=%d", nw, ww)
	}
	// A wrap boundary is drawn as a dashed connector through the gutter.
	if !strings.Contains(narrow, "stroke-dasharray") {
		t.Errorf("a wrapped graph should draw a wrap connector\n%s", narrow[:min(len(narrow), 400)])
	}
	if strings.Contains(wide, "stroke-dasharray") {
		t.Errorf("an unwrapped graph should have no wrap connector")
	}
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// containerSize reads the inline width/height the layout computed for the canvas.
func containerSize(t *testing.T, html string) (height, width int) {
	t.Helper()
	m := regexp.MustCompile(`width:(\d+)px;height:(\d+)px;`).FindStringSubmatch(html)
	if m == nil {
		t.Fatalf("no canvas size found in output")
	}
	w, _ := strconv.Atoi(m[1])
	h, _ := strconv.Atoi(m[2])
	return h, w
}
