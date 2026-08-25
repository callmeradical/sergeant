package mcp

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/callmeradical/sergeant/internal/store"
)

// writeBriefProject writes a minimal project YAML at an absolute path
// declaring one repo with a configured gate, so sergeant_get_brief's gate
// resolution (dag.SortedGateNames) has something to sort.
func writeBriefProject(t *testing.T, name, repo string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name+".yaml")
	yaml := "project: " + name + "\n" +
		"repos:\n" +
		"  " + repo + ":\n" +
		"    path: /tmp/does-not-need-to-exist-for-this-tool\n" +
		"    factory:\n" +
		"      gates:\n" +
		"        unit: echo unit\n" +
		"        lint: echo lint\n"
	if err := os.WriteFile(path, []byte(yaml), 0644); err != nil {
		t.Fatal(err)
	}
	return path
}

// sergeant_get_brief's InputSchema advertises intent_id and repo, not the
// project-config dump it used to promise but never delivered.
func TestGetBriefToolAdvertisesIntentIDAndRepo(t *testing.T) {
	for _, tool := range Tools() {
		if tool.Name != "sergeant_get_brief" {
			continue
		}
		schema, ok := tool.InputSchema.(map[string]interface{})
		if !ok {
			t.Fatalf("sergeant_get_brief InputSchema is not an object: %#v", tool.InputSchema)
		}
		props, _ := schema["properties"].(map[string]interface{})
		if _, ok := props["intent_id"]; !ok {
			t.Errorf("sergeant_get_brief InputSchema has no intent_id property: %#v", props)
		}
		if _, ok := props["repo"]; !ok {
			t.Errorf("sergeant_get_brief InputSchema has no repo property: %#v", props)
		}
		if _, ok := props["project"]; ok {
			t.Errorf("sergeant_get_brief InputSchema still advertises project; it should require intent_id/repo instead")
		}
		return
	}
	t.Fatal("sergeant_get_brief not found in Tools()")
}

// sergeant_get_brief renders the same brief RunStage would for the same
// intent, repo and gate names — the two call sites named in D1 must never
// describe the same work differently.
func TestGetBriefRendersTheSharedBrief(t *testing.T) {
	s, st := mcpFixture(t)

	projPath := writeBriefProject(t, "brief-proj", "svc")

	if err := st.CreateIntent(&store.IntentRecord{
		ID: "intent-mcp-1", Project: projPath, Statement: "add retry logic", Status: "in_progress",
	}); err != nil {
		t.Fatalf("creating intent: %v", err)
	}
	if err := st.CreateBullet(&store.BulletRecord{
		ID: "intent-mcp-1-b1", IntentID: "intent-mcp-1", Repo: "svc", Position: 1, Status: "pending",
	}); err != nil {
		t.Fatalf("creating bullet: %v", err)
	}

	text, err := s.executeTool("sergeant_get_brief", map[string]interface{}{
		"intent_id": "intent-mcp-1",
		"repo":      "svc",
	})
	if err != nil {
		t.Fatalf("sergeant_get_brief returned an error: %v", err)
	}

	want, err := st.RenderIntentBrief("intent-mcp-1", "svc", []string{"lint", "unit"})
	if err != nil {
		t.Fatalf("RenderIntentBrief: %v", err)
	}
	if text != want {
		t.Errorf("sergeant_get_brief output = %q, want it to equal the shared rendering %q", text, want)
	}
	for _, wantSubstr := range []string{"add retry logic", "svc", "pending"} {
		if !strings.Contains(text, wantSubstr) {
			t.Errorf("sergeant_get_brief output = %q, want it to contain %q", text, wantSubstr)
		}
	}
}

// sergeant_get_brief refuses a repo with no matching bullet on the intent.
func TestGetBriefRefusesRepoWithNoMatchingBullet(t *testing.T) {
	s, st := mcpFixture(t)

	projPath := writeBriefProject(t, "brief-proj-2", "svc")

	if err := st.CreateIntent(&store.IntentRecord{
		ID: "intent-mcp-2", Project: projPath, Statement: "x", Status: "in_progress",
	}); err != nil {
		t.Fatalf("creating intent: %v", err)
	}
	if err := st.CreateBullet(&store.BulletRecord{
		ID: "intent-mcp-2-b1", IntentID: "intent-mcp-2", Repo: "svc", Position: 1, Status: "pending",
	}); err != nil {
		t.Fatalf("creating bullet: %v", err)
	}

	_, err := s.executeTool("sergeant_get_brief", map[string]interface{}{
		"intent_id": "intent-mcp-2",
		"repo":      "web",
	})
	if err == nil {
		t.Fatal("expected an error for a repo with no matching bullet, got nil")
	}
}
