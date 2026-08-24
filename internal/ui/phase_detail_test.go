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

// renderPhaseDetail executes phaseDetailHTML from the embedded UI against a
// phase record, returning the HTML for its detail drawer. Mirrors the
// extract-and-run-under-node approach in stage_matrix_test.go: the only
// honest way to assert what an operator sees is to execute the real
// JavaScript, not a Go reimplementation of it.
func renderPhaseDetail(t *testing.T, phase store.PhaseRecord) string {
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
		extractJSFunction(t, src, "copyToClipboard"),
		extractJSFunction(t, src, "phaseDetailHTML"),
	}

	phaseJSON, err := json.Marshal(phase)
	if err != nil {
		t.Fatalf("marshal phase: %v", err)
	}

	harness := fmt.Sprintf(`
%s

process.stdout.write(phaseDetailHTML(%s));
`, strings.Join(parts, "\n\n"), phaseJSON)

	dir := t.TempDir()
	script := filepath.Join(dir, "phase-detail.mjs")
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

func phaseWithPayload(t *testing.T, payload map[string]interface{}) store.PhaseRecord {
	t.Helper()
	b, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	return store.PhaseRecord{Repo: "svc", Name: "build", Kind: "agent", Status: "passed", Payload: b}
}

// R4.6: model/provider are derived from real evidence of what executed a
// phase, not requested configuration — an operator must be able to see them
// in the same detail drawer that already shows which agent ran, not only
// via the raw API response.
func TestPhaseDetailShowsModelAndProvider(t *testing.T) {
	phase := phaseWithPayload(t, map[string]interface{}{
		"agent":    "goose",
		"model":    "claude-sonnet-4-6",
		"provider": "anthropic",
	})

	html := renderPhaseDetail(t, phase)

	if !strings.Contains(html, "Model") || !strings.Contains(html, "claude-sonnet-4-6") {
		t.Errorf("phase detail does not show the recorded model\n%s", html)
	}
	if !strings.Contains(html, "Provider") || !strings.Contains(html, "anthropic") {
		t.Errorf("phase detail does not show the recorded provider\n%s", html)
	}
}

// A phase whose model/provider could not be determined (an agent this
// project does not recognize) must not show a blank or guessed value —
// absence of evidence renders as absence of the row, not an invented one.
func TestPhaseDetailOmitsModelAndProviderWhenUnknown(t *testing.T) {
	phase := phaseWithPayload(t, map[string]interface{}{
		"agent":    "claude",
		"model":    "",
		"provider": "",
	})

	html := renderPhaseDetail(t, phase)

	if strings.Contains(html, "Model") {
		t.Errorf("phase detail shows a Model row with no recorded model\n%s", html)
	}
	if strings.Contains(html, "Provider") {
		t.Errorf("phase detail shows a Provider row with no recorded provider\n%s", html)
	}
}
