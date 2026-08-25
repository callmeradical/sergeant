package ui

// Characterization test for server-remaining-groups-decomposition, Task 2:
// pins handleDiscoverWorkflow's response shape against the CURRENT code,
// before it moves verbatim to workflow.go, so the move can be verified by
// re-running this test unmodified.

import (
	"encoding/json"
	"net/http"
	"sort"
	"strings"
	"testing"

	"github.com/callmeradical/sergeant/internal/config"
)

// Scenario: "Discovering a workflow returns the same shape before and after."
func TestDiscoverWorkflowReturnsAStageCoveringEveryConfiguredRepo(t *testing.T) {
	mux := workflowFixture(t, "graph.yaml", `
name: graph
repos:
  - name: svc
    path: /tmp/svc
  - name: web
    path: /tmp/web
`)

	body := `{"project":"graph","intent_archetype":"feature","quality_bar":"standard","delivery_mode":"pr"}`
	w := postJSON(t, mux, "/api/discover-workflow", body)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", w.Code, w.Body.String())
	}

	var resp struct {
		Project             string            `json:"project"`
		Archetype           string            `json:"archetype"`
		RecommendedPipeline []config.DAGStage `json:"recommended_pipeline"`
		DecisionRationale   string            `json:"decision_rationale"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decoding response %s: %v", w.Body.String(), err)
	}

	if resp.Project != "graph" {
		t.Errorf("project = %q, want graph", resp.Project)
	}
	if resp.Archetype != "feature" {
		t.Errorf("archetype = %q, want feature (echoed from the request)", resp.Archetype)
	}
	if len(resp.RecommendedPipeline) != 1 || resp.RecommendedPipeline[0].Name != "feature-tdd-execution" {
		t.Fatalf("recommended_pipeline = %+v, want exactly one feature-tdd-execution stage", resp.RecommendedPipeline)
	}

	gotRepos := append([]string{}, resp.RecommendedPipeline[0].Repos...)
	sort.Strings(gotRepos)
	if strings.Join(gotRepos, ",") != "svc,web" {
		t.Errorf("stage repos = %v, want svc and web", resp.RecommendedPipeline[0].Repos)
	}

	if !strings.Contains(resp.DecisionRationale, "2 repos") || !strings.Contains(resp.DecisionRationale, "1 stages") {
		t.Errorf("decision_rationale = %q, want it to report 2 repos and 1 stages", resp.DecisionRationale)
	}
}

// An unconfigured project is refused with 400 rather than answered with an
// empty or fabricated pipeline.
func TestDiscoverWorkflowRejectsAnUnknownProject(t *testing.T) {
	mux := workflowFixture(t, "graph.yaml", `
name: graph
repos:
  - name: svc
    path: /tmp/svc
`)

	w := postJSON(t, mux, "/api/discover-workflow", `{"project":"ghost","intent_archetype":"feature"}`)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400; body=%s", w.Code, w.Body.String())
	}
	if !strings.Contains(w.Body.String(), "ghost") {
		t.Errorf("error does not name the missing project: %s", w.Body.String())
	}
}
