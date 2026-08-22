package store

import (
	"encoding/json"
	"path/filepath"
	"testing"
)

func TestStoreOperations(t *testing.T) {
	tempDir := t.TempDir()
	dbPath := filepath.Join(tempDir, "test.db")

	st, err := Open(dbPath)
	if err != nil {
		t.Fatalf("failed to open store: %v", err)
	}
	defer st.Close()

	run := &RunRecord{
		ID:      "run-123",
		Project: "test-proj",
		TaskID:  "task-123",
		Status:  "running",
	}
	if err := st.CreateRun(run); err != nil {
		t.Fatalf("failed to create run: %v", err)
	}

	phase := &PhaseRecord{
		ID:         "phase-1",
		RunID:      "run-123",
		Repo:       "backend",
		Name:       "test",
		Kind:       "code",
		Status:     "passed",
		DurationMs: 120,
	}
	if err := st.RecordPhase(phase); err != nil {
		t.Fatalf("failed to record phase: %v", err)
	}

	env := &EnvelopeRecord{
		ID:        "env-1",
		RunID:     "run-123",
		Repo:      "backend",
		Stage:     "build",
		Summary:   "Built payment API",
		Artifacts: []string{"openapi.json"},
		Data:      json.RawMessage(`{"endpoints": ["/pay"]}`),
	}
	if err := st.RecordEnvelope(env); err != nil {
		t.Fatalf("failed to record envelope: %v", err)
	}

	retrieved, err := st.GetLatestEnvelope("run-123", "backend")
	if err != nil {
		t.Fatalf("failed to get envelope: %v", err)
	}
	if retrieved.Summary != "Built payment API" {
		t.Errorf("expected summary 'Built payment API', got %s", retrieved.Summary)
	}
	if len(retrieved.Artifacts) != 1 || retrieved.Artifacts[0] != "openapi.json" {
		t.Errorf("unexpected artifacts: %v", retrieved.Artifacts)
	}

	if err := st.UpdateRunStatus("run-123", "passed"); err != nil {
		t.Fatalf("failed to update run status: %v", err)
	}

	runs, err := st.ListRecentRuns(5)
	if err != nil {
		t.Fatalf("failed to list runs: %v", err)
	}
	if len(runs) != 1 || runs[0].Status != "passed" {
		t.Errorf("unexpected run status: %v", runs)
	}
}
