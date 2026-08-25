package handoff

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestRouterEnvelopePassing(t *testing.T) {
	tempBase := t.TempDir()
	router := NewRouter(tempBase)

	env := &Envelope{
		TaskID:    "task-999",
		Repo:      "backend",
		Stage:     "build",
		Summary:   "Generated OpenAPI Spec",
		Artifacts: []string{"openapi.json"},
		Payload:   json.RawMessage(`{"version": "1.0.0"}`),
	}

	if err := router.SaveEnvelope(env); err != nil {
		t.Fatalf("failed to save envelope: %v", err)
	}

	latest, err := router.ReadLatestEnvelope("backend")
	if err != nil {
		t.Fatalf("failed to read latest envelope: %v", err)
	}
	if latest.Summary != "Generated OpenAPI Spec" {
		t.Errorf("unexpected summary: %s", latest.Summary)
	}

	downstreamWorktree := t.TempDir()
	if err := router.InjectHandoffToWorktree("backend", downstreamWorktree); err != nil {
		t.Fatalf("failed to inject handoff: %v", err)
	}

	injectedFile := filepath.Join(downstreamWorktree, ".sergeant", "handoff", "backend", "envelope_latest.json")
	if _, err := os.Stat(injectedFile); os.IsNotExist(err) {
		t.Errorf("expected injected handoff file to exist at %s", injectedFile)
	}
}

// ReviewFindings mirrors BlockedReason's convention: an optional array nested
// inside the envelope's existing payload, not a new top-level Envelope field.
func TestReviewFindingsReadsFindingsFromPayload(t *testing.T) {
	payload := json.RawMessage(`{"findings":[{"axis":"spec","severity":"error","summary":"missing test coverage","disposition":"add a failing test first"}]}`)

	findings := ReviewFindings(payload)
	if len(findings) != 1 {
		t.Fatalf("findings = %+v, want 1 entry", findings)
	}
	f := findings[0]
	if f.Axis != "spec" || f.Severity != "error" || f.Summary != "missing test coverage" || f.Disposition != "add a failing test first" {
		t.Errorf("finding = %+v, want all four fields to round-trip", f)
	}
}

func TestReviewFindingsReadsMultipleFindings(t *testing.T) {
	payload := json.RawMessage(`{"findings":[{"severity":"error","summary":"one"},{"severity":"warning","summary":"two"}]}`)

	findings := ReviewFindings(payload)
	if len(findings) != 2 {
		t.Fatalf("findings = %+v, want 2 entries", findings)
	}
}

// A missing, empty, or malformed payload is "no findings", not a crash — the
// same forgiving contract BlockedReason already documents.
func TestReviewFindingsReturnsNilForMalformedOrEmptyPayload(t *testing.T) {
	cases := []json.RawMessage{
		nil,
		json.RawMessage(``),
		json.RawMessage(`{}`),
		json.RawMessage(`"not an object"`),
		json.RawMessage(`{"findings":"not an array"}`),
		json.RawMessage(`not json at all`),
	}
	for _, payload := range cases {
		if got := ReviewFindings(payload); got != nil {
			t.Errorf("ReviewFindings(%s) = %+v, want nil", payload, got)
		}
	}
}

func TestHasBlockingFindingDetectsErrorSeverity(t *testing.T) {
	findings := []ReviewFinding{{Severity: "info"}, {Severity: "error"}}
	if !HasBlockingFinding(findings) {
		t.Error("expected a severity \"error\" finding to be detected as blocking")
	}
}

func TestHasBlockingFindingFalseWithoutAnErrorSeverity(t *testing.T) {
	cases := [][]ReviewFinding{
		nil,
		{},
		{{Severity: "info"}, {Severity: "warning"}},
	}
	for _, findings := range cases {
		if HasBlockingFinding(findings) {
			t.Errorf("HasBlockingFinding(%+v) = true, want false", findings)
		}
	}
}
