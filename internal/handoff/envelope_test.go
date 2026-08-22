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
