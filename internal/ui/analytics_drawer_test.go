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

// renderAnalytics executes analyticsHTML from the embedded UI against a
// WorkAnalytics response, returning the HTML for the drawer body. Mirrors
// the extract-and-run-under-node approach in stage_matrix_test.go and
// phase_detail_test.go: the only honest way to assert what an operator sees
// is to execute the real JavaScript, not a Go reimplementation of it.
func renderAnalytics(t *testing.T, data store.WorkAnalytics) string {
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
		extractJSFunction(t, src, "analyticsBreakdownHTML"),
		extractJSFunction(t, src, "analyticsHTML"),
	}

	dataJSON, err := json.Marshal(data)
	if err != nil {
		t.Fatalf("marshal data: %v", err)
	}

	harness := fmt.Sprintf(`
%s

process.stdout.write(analyticsHTML(%s));
`, strings.Join(parts, "\n\n"), dataJSON)

	dir := t.TempDir()
	script := filepath.Join(dir, "analytics.mjs")
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

// Scenario: Zero bullets renders without error — the drawer must state that
// no bullets have been recorded rather than showing a division-by-zero
// result such as NaN%.
func TestAnalyticsHTMLZeroBulletsShowsNoNaN(t *testing.T) {
	html := renderAnalytics(t, store.WorkAnalytics{
		TotalRuns:     3,
		ByStatus:      map[string]int{"passed": 3},
		ByType:        map[string]int{"feat": 3},
		ByAgent:       map[string]int{"": 3},
		ByModel:       map[string]int{"": 3},
		ByProvider:    map[string]int{"": 3},
		BulletsTotal:  0,
		BulletsMerged: 0,
	})

	if strings.Contains(html, "NaN") {
		t.Errorf("zero bullets must not render NaN\n%s", html)
	}
	if !strings.Contains(html, "No bullets recorded yet") {
		t.Errorf("zero bullets must say none have been recorded yet\n%s", html)
	}
}

// Scenario: known provenance and pre-O2 empty-type buckets are both
// discoverable in the rendered breakdown, correctly labeled and counted.
func TestAnalyticsHTMLKnownProvenanceBreakdown(t *testing.T) {
	html := renderAnalytics(t, store.WorkAnalytics{
		TotalRuns:     4,
		ByStatus:      map[string]int{"passed": 3, "failed": 1},
		ByType:        map[string]int{"feat": 3, "": 1},
		ByAgent:       map[string]int{"goose": 3, "": 1},
		ByModel:       map[string]int{"claude-sonnet-4-6": 3, "": 1},
		ByProvider:    map[string]int{"anthropic": 3, "": 1},
		BulletsTotal:  2,
		BulletsMerged: 1,
	})

	for _, want := range []string{
		"4",            // total run count
		"goose", "75%", // known agent bucket and its percentage
		"claude-sonnet-4-6",              // known model bucket
		"anthropic",                      // known provider bucket
		"unknown",                        // the "" bucket, labeled, not blank
		"before work types were tracked", // the pre-O2 "" bucket, labeled
		"1 / 2", "50%",                   // merged vs total bullets and percentage
	} {
		if !strings.Contains(html, want) {
			t.Errorf("analytics drawer should contain %q\n--- html ---\n%s", want, html)
		}
	}
	if strings.Contains(html, "NaN") {
		t.Errorf("known-provenance case must not render NaN\n%s", html)
	}
}
